<#
.SYNOPSIS
    Planned manual failover, without data loss, for an Availability Group with CLUSTER_TYPE = NONE.

.DESCRIPTION
    With no cluster manager there is no automatic failover and no "ALTER AVAILABILITY GROUP ... FAILOVER".
    A planned move follows Microsoft's documented sequence for read-scale AGs, and step 1 makes it lossless:

      1. Readiness: the target must be a SYNCHRONOUS_COMMIT secondary. Asynchronous replicas are switched to
         synchronous for the move, and EVERY secondary must be SYNCHRONIZED at the primary's last hardened LSN.
         Otherwise an async replica can receive log the new primary never had, diverge, and be unable to follow
         it (SUSPEND_FROM_PARTNER). REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1 is set first, so no
         transaction can commit without reaching a synchronous secondary. Original commit modes are restored after.
      2. Take the AG offline on the current primary:  ALTER AVAILABILITY GROUP ... OFFLINE
      3. Promote the target:                          ALTER AVAILABILITY GROUP ... FORCE_FAILOVER_ALLOW_DATA_LOSS
         (the only promote command for CLUSTER_TYPE = NONE; step 1 guarantees nothing is lost)
      4. On the old primary AND every other secondary: ALTER AVAILABILITY GROUP ... SET (ROLE = SECONDARY)
         (a bystander secondary that misses this stays attached to the old configuration: SUSPEND_FROM_PARTNER)
      5. Resume data movement on every other replica, then wait until the AG is healthy again.

.EXAMPLE
    ./lab/Invoke-AgLabFailover.ps1 -Replica $lab.Replica -AgName $lab.AgName -Target 'localhost,14342' -SqlCredential $sa
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string[]]     $Replica,
    [Parameter(Mandatory)] [string]       $AgName,
    [Parameter(Mandatory)] [string]       $Target,          # connection string of the replica to promote
    [Parameter(Mandatory)] [pscredential] $SqlCredential,
    [int] $TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

function Sql {
    param([string] $Instance, [string] $Query)
    Invoke-DbaQuery -SqlInstance $Instance -SqlCredential $SqlCredential -Query $Query -QueryTimeout 120 -EnableException
}
function Wait-Until {
    param([scriptblock] $Condition, [string] $What)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $ok = $false
        try { $ok = [bool](& $Condition) } catch { $ok = $false }
        if ($ok) { return }
        if ((Get-Date) -gt $deadline) { throw "Timed out after $TimeoutSeconds s waiting for: $What" }
        Start-Sleep -Seconds 2
    }
}
function Get-Roles {
    foreach ($r in $Replica) {
        $row = Sql $r @"
SELECT @@SERVERNAME AS name, ars.role_desc
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_groups ag ON ag.group_id = ars.group_id
WHERE ars.is_local = 1 AND ag.name = N'$AgName';
"@
        [pscustomobject]@{ Instance = $r; Name = $row.name; Role = $row.role_desc }
    }
}

$roles   = @(Get-Roles)
$primary = $roles | Where-Object Role -eq 'PRIMARY'
$tgt     = $roles | Where-Object Instance -eq $Target
if (-not $primary) { throw "No primary found for $AgName." }
if (-not $tgt)     { throw "$Target is not a replica of $AgName." }
if ($tgt.Role -eq 'PRIMARY') { Write-Host "$($tgt.Name) is already the primary. Nothing to do."; return }

Write-Host "==> Failover $AgName : $($primary.Name) -> $($tgt.Name)" -ForegroundColor Cyan

# ---- 1. Readiness ------------------------------------------------------------------------------------------
$mode = (Sql $primary.Instance @"
SELECT ar.availability_mode_desc AS m
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
WHERE ag.name = N'$AgName' AND ar.replica_server_name = N'$($tgt.Name)';
"@).m
if ($mode -ne 'SYNCHRONOUS_COMMIT') {
    throw "Refusing: $($tgt.Name) is $mode. A lossless planned failover needs a SYNCHRONOUS_COMMIT target."
}

# Remember every replica's commit mode, then make all of them synchronous for the move
$modes = @(Sql $primary.Instance @"
SELECT ar.replica_server_name AS name, ar.availability_mode_desc AS mode
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
WHERE ag.name = N'$AgName';
"@)
foreach ($m in $modes | Where-Object mode -ne 'SYNCHRONOUS_COMMIT') {
    Sql $primary.Instance "ALTER AVAILABILITY GROUP [$AgName] MODIFY REPLICA ON N'$($m.name)' WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT);"
    Write-Host "    sync for the move: $($m.name) (was $($m.mode))"
}

Sql $primary.Instance "ALTER AVAILABILITY GROUP [$AgName] SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1);"

$readinessQuery = @"
SELECT ar.replica_server_name       AS replica,
       DB_NAME(p.database_id)       AS db,
       s.synchronization_state_desc AS state,
       s.is_suspended,
       p.last_hardened_lsn          AS primary_lsn,
       s.last_hardened_lsn          AS secondary_lsn
FROM sys.dm_hadr_database_replica_states p
JOIN sys.dm_hadr_database_replica_states s ON s.group_database_id = p.group_database_id AND s.is_local = 0
JOIN sys.availability_replicas ar          ON ar.replica_id = s.replica_id
JOIN sys.availability_groups ag            ON ag.group_id = p.group_id
WHERE ag.name = N'$AgName' AND p.is_local = 1
ORDER BY ar.replica_server_name;
"@

# A replica switched to synchronous only reports SYNCHRONIZED after it hardens NEW log, and an idle database
# generates none. A CHECKPOINT in each AG database writes a little log that flows to every secondary.
$agDbs = @((Sql $primary.Instance @"
SELECT adc.database_name AS name
FROM sys.availability_databases_cluster adc
JOIN sys.availability_groups ag ON ag.group_id = adc.group_id
WHERE ag.name = N'$AgName';
"@).name)

try {
    Wait-Until -What "every secondary SYNCHRONIZED at the primary's LSN" -Condition {
        foreach ($db in $agDbs) { Sql $primary.Instance "USE [$db]; CHECKPOINT;" | Out-Null }
        Start-Sleep -Seconds 1
        $rows = @(Sql $primary.Instance $readinessQuery)
        $rows.Count -gt 0 -and
            -not @($rows | Where-Object { $_.state -ne 'SYNCHRONIZED' -or $_.secondary_lsn -ne $_.primary_lsn }).Count
    }
}
catch {
    # Nothing has moved yet: show why, undo the preparation, and stop
    Write-Host "    Not ready. Secondary state at timeout:" -ForegroundColor Yellow
    Sql $primary.Instance $readinessQuery | Format-Table -AutoSize | Out-String | Write-Host
    Sql $primary.Instance "ALTER AVAILABILITY GROUP [$AgName] SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0);"
    foreach ($m in $modes | Where-Object mode -ne 'SYNCHRONOUS_COMMIT') {
        Sql $primary.Instance "ALTER AVAILABILITY GROUP [$AgName] MODIFY REPLICA ON N'$($m.name)' WITH (AVAILABILITY_MODE = $($m.mode));"
    }
    Write-Host "    Failover aborted before any change of roles; preparation undone." -ForegroundColor Yellow
    throw
}
Write-Host "    readiness: every secondary is synchronized at the primary's LSN"

# ---- 2. Offline on the old primary, 3. Promote the target, 4. Old primary becomes a secondary -----------
Sql $primary.Instance "ALTER AVAILABILITY GROUP [$AgName] OFFLINE;"
Write-Host "    offline  : $($primary.Name)"
Sql $tgt.Instance "ALTER AVAILABILITY GROUP [$AgName] FORCE_FAILOVER_ALLOW_DATA_LOSS;"
Write-Host "    promoted : $($tgt.Name)"
# The old primary AND every other secondary must accept the new configuration. The first attempt can fail
# with Msg 41104 while the transport is stale, so retry until each replica accepts it.
foreach ($r in $roles | Where-Object Instance -ne $tgt.Instance) {
    Wait-Until -What "$($r.Name) to accept the SECONDARY role" -Condition {
        Sql $r.Instance "ALTER AVAILABILITY GROUP [$AgName] SET (ROLE = SECONDARY);"
        $true
    }
    Write-Host "    secondary: $($r.Name)"
}

# ---- 5. Resume data movement everywhere else ---------------------------------------------------------------
$dbs = @((Sql $tgt.Instance @"
SELECT adc.database_name AS name
FROM sys.availability_databases_cluster adc
JOIN sys.availability_groups ag ON ag.group_id = adc.group_id
WHERE ag.name = N'$AgName';
"@).name)

foreach ($r in $roles | Where-Object Instance -ne $tgt.Instance) {
    foreach ($db in $dbs) {
        Wait-Until -What "resume $db on $($r.Name)" -Condition {
            Sql $r.Instance "ALTER DATABASE [$db] SET HADR RESUME;"
            $true
        }
    }
    Write-Host "    resumed  : $($r.Name)"
}

Sql $tgt.Instance "ALTER AVAILABILITY GROUP [$AgName] SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0);"

# Put every replica back to the commit mode it had before the move (run on the new primary)
foreach ($m in $modes | Where-Object mode -ne 'SYNCHRONOUS_COMMIT') {
    Sql $tgt.Instance "ALTER AVAILABILITY GROUP [$AgName] MODIFY REPLICA ON N'$($m.name)' WITH (AVAILABILITY_MODE = $($m.mode));"
    Write-Host "    restored : $($m.name) back to $($m.mode)"
}

$stateQuery = @"
SELECT ar.replica_server_name AS replica, ars.role_desc AS role, ars.connected_state_desc AS conn,
       DB_NAME(drs.database_id) AS db, drs.synchronization_state_desc AS sync, drs.is_suspended,
       drs.suspend_reason_desc AS suspend_reason
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ar.replica_id = ars.replica_id
JOIN sys.availability_groups ag   ON ag.group_id = ars.group_id
LEFT JOIN sys.dm_hadr_database_replica_states drs ON drs.replica_id = ars.replica_id
WHERE ag.name = N'$AgName'
ORDER BY ar.replica_server_name;
"@

# After a forced failover, data movement on the other replicas starts out SUSPENDED. A RESUME sent while a
# replica is still settling into its new role can succeed without effect, and a SUSPEND_FROM_PARTNER suspension
# is held on the new primary's side. So keep resuming from both sides until healthy, and keep every error.
$resumeErrors = @{}
try {
    Wait-Until -What "every replica CONNECTED and every database moving data" -Condition {
        $rows = @(Sql $tgt.Instance $stateQuery)
        foreach ($row in $rows | Where-Object { $_.is_suspended -eq $true -and $_.db }) {
            $replicaInstance = ($roles | Where-Object Name -eq $row.replica).Instance
            # Re-issuing the role re-establishes the mirroring session if the first one went stale
            if ($replicaInstance -ne $tgt.Instance) {
                try   { Sql $replicaInstance "ALTER AVAILABILITY GROUP [$AgName] SET (ROLE = SECONDARY);" }
                catch { $resumeErrors["$($row.replica) SET ROLE"] = ($_.Exception.Message -split "`r?`n")[0] }
            }
            foreach ($side in @($replicaInstance, $tgt.Instance) | Select-Object -Unique) {
                try   { Sql $side "ALTER DATABASE [$($row.db)] SET HADR RESUME;" }
                catch { $resumeErrors["$($row.replica)/$($row.db) via $side"] = ($_.Exception.Message -split "`r?`n")[0] }
            }
        }
        -not @($rows | Where-Object { $_.conn -ne 'CONNECTED' -or $_.sync -notin 'SYNCHRONIZED', 'SYNCHRONIZING' }).Count
    }
}
catch {
    Write-Host "    AG state at timeout:" -ForegroundColor Yellow
    Sql $tgt.Instance $stateQuery | Format-Table -AutoSize | Out-String | Write-Host
    if ($resumeErrors.Count) {
        Write-Host "    Last RESUME error per replica/database:" -ForegroundColor Yellow
        $resumeErrors.GetEnumerator() | ForEach-Object { Write-Host "      $($_.Key): $($_.Value)" }
    }
    throw
}

Sql $tgt.Instance @"
SELECT ar.replica_server_name AS replica, ars.role_desc AS role,
       ar.availability_mode_desc AS commit_mode, ars.synchronization_health_desc AS health
FROM sys.availability_replicas ar
JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
WHERE ag.name = N'$AgName'
ORDER BY ar.replica_server_name;
"@ | Format-Table | Out-String | Write-Host
