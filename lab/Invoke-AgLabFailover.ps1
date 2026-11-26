<#
.SYNOPSIS
    Planned manual failover, without data loss, for an Availability Group with CLUSTER_TYPE = NONE.

.DESCRIPTION
    With no cluster manager there is no automatic failover and no "ALTER AVAILABILITY GROUP ... FAILOVER".
    A planned move is done in four steps, and step 1 is what makes it lossless:

      1. Readiness: the target must be a SYNCHRONOUS_COMMIT secondary, and every database must be SYNCHRONIZED
         on it with the same last hardened LSN as the primary. REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1
         is set first, so no transaction can commit without reaching a synchronous secondary.
      2. Demote the current primary:  ALTER AVAILABILITY GROUP ... SET (ROLE = SECONDARY)
      3. Promote the target:          ALTER AVAILABILITY GROUP ... FORCE_FAILOVER_ALLOW_DATA_LOSS
         (the only promote command for CLUSTER_TYPE = NONE; step 1 guarantees nothing is lost)
      4. Resume data movement on every other replica, then wait until the AG is healthy again.

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

Sql $primary.Instance "ALTER AVAILABILITY GROUP [$AgName] SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1);"

Wait-Until -What "every database SYNCHRONIZED on $($tgt.Name) at the primary's LSN" -Condition {
    $rows = @(Sql $primary.Instance @"
SELECT DB_NAME(p.database_id)       AS db,
       p.last_hardened_lsn          AS primary_lsn,
       t.last_hardened_lsn          AS target_lsn,
       t.synchronization_state_desc AS target_state
FROM sys.dm_hadr_database_replica_states p
JOIN sys.dm_hadr_database_replica_states t ON t.group_database_id = p.group_database_id
JOIN sys.availability_replicas ar          ON ar.replica_id = t.replica_id
JOIN sys.availability_groups ag            ON ag.group_id = p.group_id
WHERE ag.name = N'$AgName' AND p.is_local = 1 AND ar.replica_server_name = N'$($tgt.Name)';
"@)
    $rows.Count -gt 0 -and
        -not @($rows | Where-Object { $_.target_state -ne 'SYNCHRONIZED' -or $_.target_lsn -ne $_.primary_lsn }).Count
}
Write-Host "    readiness: $($tgt.Name) is synchronized at the primary's LSN"

# ---- 2. Demote, 3. Promote ---------------------------------------------------------------------------------
Sql $primary.Instance "ALTER AVAILABILITY GROUP [$AgName] SET (ROLE = SECONDARY);"
Write-Host "    demoted  : $($primary.Name)"
Sql $tgt.Instance "ALTER AVAILABILITY GROUP [$AgName] FORCE_FAILOVER_ALLOW_DATA_LOSS;"
Write-Host "    promoted : $($tgt.Name)"

# ---- 4. Resume data movement everywhere else ---------------------------------------------------------------
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

Wait-Until -What "every replica CONNECTED and every database moving data" -Condition {
    $rows = @(Sql $tgt.Instance @"
SELECT ars.connected_state_desc AS conn, drs.synchronization_state_desc AS sync
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_groups ag ON ag.group_id = ars.group_id
LEFT JOIN sys.dm_hadr_database_replica_states drs ON drs.replica_id = ars.replica_id
WHERE ag.name = N'$AgName';
"@)
    -not @($rows | Where-Object { $_.conn -ne 'CONNECTED' -or $_.sync -notin 'SYNCHRONIZED', 'SYNCHRONIZING' }).Count
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
