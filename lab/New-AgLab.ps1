<#
.SYNOPSIS
    Builds the AgSync lab from nothing: a 3-replica Always On Availability Group plus a
    controller instance, all in Docker. Used locally and by CI.

.DESCRIPTION
    agsql1  primary              localhost,14341   synchronous
    agsql2  secondary            localhost,14342   synchronous
    agsql3  secondary ("DR")     localhost,14343   asynchronous
    agctl   controller (no AG)   localhost,14340   holds the AgSync control DB

    Steps: containers -> master keys + shared certificate -> HADR endpoints -> AG (automatic seeding)
           -> test database -> control DB -> AgSync service accounts (distributed by AgSync itself).

    Idempotent: every step checks before it creates, so the script is safe to re-run.
    -Reset destroys the lab first (all data in the lab containers is lost).

    Passwords must meet SQL Server complexity rules and must not contain quotes or the $ character.

.EXAMPLE
    $sa      = Get-Credential sa
    $app     = Get-Credential agsync_apply
    $det     = Get-Credential agsync_detect
    $ctlCred = Get-Credential agsync_control
    ./lab/New-AgLab.ps1 -SaCredential $sa -ApplyCredential $app -DetectCredential $det -ControlCredential $ctlCred -Reset
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [pscredential] $SaCredential,
    [Parameter(Mandatory)] [pscredential] $ApplyCredential,      # user name is always agsync_apply
    [Parameter(Mandatory)] [pscredential] $DetectCredential,     # user name is always agsync_detect
    [Parameter(Mandatory)] [pscredential] $ControlCredential,    # login the tool uses for the control DB
    [string] $AgName     = 'aglab_ag',
    [string] $AgDatabase = 'SyncLab',
    [switch] $Reset
)

$ErrorActionPreference = 'Stop'
$root     = Split-Path $PSScriptRoot -Parent
$compose  = Join-Path $PSScriptRoot 'docker-compose.yml'
$replicas = 14341..14343 | ForEach-Object { "localhost,$_" }
$names    = 'agsql1', 'agsql2', 'agsql3'
$ctl      = 'localhost,14340'
$saPw     = $SaCredential.GetNetworkCredential().Password
$keyPw    = $saPw    # lab only: master keys, certificate transfer and endpoint login reuse the sa password

function Write-Step { param([string] $Message) Write-Host "==> $Message" -ForegroundColor Cyan }

function Sql {
    param([string] $Instance, [string] $Query, [string] $Database = 'master', [int] $QueryTimeout = 120)
    Invoke-DbaQuery -SqlInstance $Instance -SqlCredential $SaCredential -Database $Database -Query $Query `
                    -QueryTimeout $QueryTimeout -EnableException
}

function Wait-Until {
    # Polls a condition instead of guessing with sleeps; fails with a clear message on timeout
    param([scriptblock] $Condition, [string] $What, [int] $TimeoutSeconds = 180, [int] $PollSeconds = 3)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $ok = $false
        try { $ok = [bool](& $Condition) } catch { $ok = $false }
        if ($ok) { return }
        if ((Get-Date) -gt $deadline) { throw "Timed out after $TimeoutSeconds s waiting for: $What" }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Invoke-WithRetry {
    # HA operations race on fast machines (e.g. a replica joins before the primary's endpoint can serve the
    # AG configuration: error 47106). Retry with a pause instead of failing the whole build.
    param([scriptblock] $Action, [string] $What, [int] $Attempts = 10, [int] $DelaySeconds = 10)
    for ($i = 1; $i -le $Attempts; $i++) {
        try { & $Action; return }
        catch {
            if ($i -eq $Attempts) { throw }
            $msg = ($_.Exception.Message -split "`r?`n")[0]
            Write-Host "    $What - attempt $i/$Attempts failed: $msg. Retrying in $DelaySeconds s." -ForegroundColor Yellow
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

Import-Module dbatools
Set-DbatoolsInsecureConnection -SessionOnly | Out-Null

# ------------------------------------------------------------------------------------------------
Write-Step 'Containers'
$env:SA_PASSWORD = $saPw
if ($Reset) {
    docker compose -f $compose -p aglab down -v
    if ($LASTEXITCODE) { throw 'docker compose down failed' }
}
docker compose -f $compose -p aglab up -d
if ($LASTEXITCODE) { throw 'docker compose up failed' }

Write-Step 'Waiting for SQL Server to accept connections'
foreach ($i in $replicas + $ctl) {
    $deadline = (Get-Date).AddMinutes(3)
    while ($true) {
        try   { Sql $i 'SELECT 1 AS ok;' | Out-Null; break }
        catch {
            if ((Get-Date) -gt $deadline) { throw "$i did not start within 3 minutes: $($_.Exception.Message)" }
            Start-Sleep -Seconds 3
        }
    }
    Write-Host "    $i ready"
}

# Accepting logins is not the same as Always On being ready: the HADR manager starts after logins are
# accepted, and on a small, busy machine the gap can be long. A JOIN sent into that gap hangs.
Write-Step 'Waiting for Always On (HADR manager) to start on every replica'
foreach ($r in $replicas) {
    Wait-Until -What "HADR manager on $r" -Condition {
        (Sql $r "SELECT CAST(SERVERPROPERTY('HadrManagerStatus') AS int) AS s;").s -eq 1
    }
    Write-Host "    $r HADR running"
}

# ------------------------------------------------------------------------------------------------
Write-Step 'Master keys, endpoint login and shared certificate'
foreach ($r in $replicas) {
    Sql $r @"
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$keyPw';
IF SUSER_ID('dbm_login') IS NULL CREATE LOGIN dbm_login WITH PASSWORD = '$keyPw';
IF USER_ID('dbm_user')   IS NULL CREATE USER dbm_user FOR LOGIN dbm_login;
"@
}

# Created once on agsql1, copied to the others as binary through T-SQL (no backup files)
Sql $replicas[0] @"
IF CERT_ID('dbm_certificate') IS NULL
    CREATE CERTIFICATE dbm_certificate WITH SUBJECT = 'aglab HADR endpoint', EXPIRY_DATE = '20361231';
"@
$cert = Sql $replicas[0] @"
SELECT CONVERT(varchar(max), CERTENCODED(CERT_ID('dbm_certificate')), 1)             AS pub,
       CONVERT(varchar(max), CERTPRIVATEKEY(CERT_ID('dbm_certificate'), '$keyPw'), 1) AS pvk;
"@
foreach ($r in $replicas[1..2]) {
    Sql $r @"
IF CERT_ID('dbm_certificate') IS NULL
    CREATE CERTIFICATE dbm_certificate AUTHORIZATION dbm_user
        FROM BINARY = $($cert.pub)
        WITH PRIVATE KEY (BINARY = $($cert.pvk), DECRYPTION BY PASSWORD = '$keyPw');
"@
}

# ------------------------------------------------------------------------------------------------
Write-Step 'HADR endpoints (port 5022, certificate auth, AES)'
foreach ($r in $replicas) {
    Sql $r @"
IF NOT EXISTS (SELECT 1 FROM sys.database_mirroring_endpoints)
    CREATE ENDPOINT [Hadr_endpoint]
        AS TCP (LISTENER_PORT = 5022)
        FOR DATABASE_MIRRORING (ROLE = ALL, AUTHENTICATION = CERTIFICATE dbm_certificate,
                                ENCRYPTION = REQUIRED ALGORITHM AES);
ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED;
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [dbm_login];

IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'AlwaysOn_health')
BEGIN
    ALTER EVENT SESSION AlwaysOn_health ON SERVER WITH (STARTUP_STATE = ON);
    IF NOT EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'AlwaysOn_health')
        ALTER EVENT SESSION AlwaysOn_health ON SERVER STATE = START;
END
"@
}

# ------------------------------------------------------------------------------------------------
Write-Step "Availability Group $AgName"
if (-not (Sql $replicas[0] "SELECT COUNT(*) AS c FROM sys.availability_groups WHERE name = N'$AgName';").c) {
    $replicaSpecs = foreach ($n in $names) {
        $mode = if ($n -eq 'agsql3') { 'ASYNCHRONOUS_COMMIT' } else { 'SYNCHRONOUS_COMMIT' }
        "N'$n' WITH (ENDPOINT_URL = N'tcp://${n}:5022', AVAILABILITY_MODE = $mode, FAILOVER_MODE = MANUAL, " +
        "SEEDING_MODE = AUTOMATIC, SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL))"
    }
    Sql $replicas[0] @"
CREATE AVAILABILITY GROUP [$AgName] WITH (CLUSTER_TYPE = NONE)
    FOR REPLICA ON $($replicaSpecs -join ",`n    ");
ALTER AVAILABILITY GROUP [$AgName] GRANT CREATE ANY DATABASE;
"@
}
# The primary must be serving the AG before any secondary asks it for the configuration
Wait-Until -What "$AgName online on the primary" -Condition {
    (Sql $replicas[0] @"
SELECT COUNT(*) AS c
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_groups ag ON ag.group_id = ars.group_id
WHERE ag.name = N'$AgName' AND ars.is_local = 1
  AND ars.role_desc = 'PRIMARY' AND ars.operational_state_desc = 'ONLINE';
"@).c -eq 1
}

foreach ($r in $replicas[1..2]) {
    if (-not (Sql $r "SELECT COUNT(*) AS c FROM sys.availability_groups WHERE name = N'$AgName';").c) {
        Invoke-WithRetry -What "Join $r to $AgName" -Attempts 5 -DelaySeconds 15 -Action {
            Sql $r "ALTER AVAILABILITY GROUP [$AgName] JOIN WITH (CLUSTER_TYPE = NONE);" -QueryTimeout 300
        }
    }
    # Only after a successful join: lets automatic seeding create the AG databases on this replica
    Sql $r "ALTER AVAILABILITY GROUP [$AgName] GRANT CREATE ANY DATABASE;"
    Write-Host "    $r joined"
}

# ------------------------------------------------------------------------------------------------
Write-Step "Database $AgDatabase (automatic seeding)"
Sql $replicas[0] "IF DB_ID(N'$AgDatabase') IS NULL CREATE DATABASE [$AgDatabase];"
Sql $replicas[0] @"
IF NOT EXISTS (SELECT 1 FROM sys.availability_databases_cluster WHERE database_name = N'$AgDatabase')
BEGIN
    ALTER DATABASE [$AgDatabase] SET RECOVERY FULL;
    BACKUP DATABASE [$AgDatabase] TO DISK = N'/var/opt/mssql/data/${AgDatabase}_init.bak' WITH INIT;
    ALTER AVAILABILITY GROUP [$AgName] ADD DATABASE [$AgDatabase];
END
"@

$deadline = (Get-Date).AddMinutes(3)
do {
    Start-Sleep -Seconds 3
    $states = Sql $replicas[0] @"
SELECT ar.replica_server_name, drs.synchronization_state_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
WHERE DB_NAME(drs.database_id) = N'$AgDatabase';
"@
    $ready = @($states | Where-Object synchronization_state_desc -in 'SYNCHRONIZED', 'SYNCHRONIZING').Count -eq $names.Count
} until ($ready -or (Get-Date) -gt $deadline)
if (-not $ready) { throw "$AgDatabase did not reach every replica within 3 minutes." }

# ------------------------------------------------------------------------------------------------
Write-Step 'Control database on the controller'
Invoke-DbaQuery -SqlInstance $ctl -SqlCredential $SaCredential -File (Join-Path $root 'sql/ControlDb.sql') -EnableException

# The tool's own control-DB login: read and write the agsync schema, nothing else
$cu = $ControlCredential.UserName
$cp = $ControlCredential.GetNetworkCredential().Password
Sql $ctl "IF SUSER_ID(N'$cu') IS NULL CREATE LOGIN [$cu] WITH PASSWORD = '$cp';"
Sql $ctl -Database AgSyncControl -Query @"
IF USER_ID(N'$cu') IS NULL CREATE USER [$cu] FOR LOGIN [$cu];
GRANT SELECT, INSERT, UPDATE ON SCHEMA::agsync TO [$cu];
"@

# ------------------------------------------------------------------------------------------------
Write-Step 'AgSync service accounts (created on the primary, distributed by AgSync itself)'
$ap = $ApplyCredential.GetNetworkCredential().Password
$dp = $DetectCredential.GetNetworkCredential().Password
Sql $replicas[0] @"
IF SUSER_ID('agsync_apply') IS NULL
BEGIN
    CREATE LOGIN agsync_apply WITH PASSWORD = '$ap';
    ALTER SERVER ROLE sysadmin ADD MEMBER agsync_apply;
END
IF SUSER_ID('agsync_detect') IS NULL
BEGIN
    CREATE LOGIN agsync_detect WITH PASSWORD = '$dp';
    GRANT VIEW SERVER STATE   TO agsync_detect;
    GRANT VIEW ANY DEFINITION TO agsync_detect;
END
"@

Import-Module (Join-Path $root 'AgSync.psm1') -Force
Invoke-AgSync -Replica $replicas -AgName $AgName -SqlCredential $SaCredential `
              -ControlInstance $ctl -ControlCredential $ControlCredential -ObjectType Login -Mode Apply |
    Format-Table ObjectName, TargetReplica, DriftType, Action | Out-String | Write-Host

# msdb is not in the AG, so the detect account's msdb permissions are granted on every replica
foreach ($r in $replicas) {
    Invoke-DbaQuery -SqlInstance $r -SqlCredential $SaCredential -Database msdb `
                    -File (Join-Path $root 'sql/AgSyncAccounts.sql') -EnableException
}

# ------------------------------------------------------------------------------------------------
Write-Step 'Lab ready'
Sql $replicas[0] @"
SELECT ar.replica_server_name AS replica, ars.role_desc AS role,
       ar.availability_mode_desc AS commit_mode, ars.synchronization_health_desc AS health
FROM sys.availability_replicas ar
JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
ORDER BY ar.replica_server_name;
"@ | Format-Table | Out-String | Write-Host

# Returned as a hashtable for splatting:
#   $lab = ./lab/New-AgLab.ps1 ...;  Get-AgSyncDrift @lab -SqlCredential $app -ControlCredential $ctlCred
@{ Replica = $replicas; AgName = $AgName; ControlInstance = $ctl }
