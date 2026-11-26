#Requires -Modules dbatools
<#
    AgHealth - collects Always On AG health into the control database, for alerts and the live dashboard.

    One run = one Snapshot of one AG:
      1. Probe every replica on its own: can we connect, what role does it say it has, what does it see locally.
      2. Read the full picture from the primary: every replica and every database on every replica,
         with send queue, redo queue, estimated data loss (RPO) and estimated recovery time (RTO).
      3. Write the snapshot in one transaction, so the dashboard never sees half a snapshot.
      4. Evaluate the alert rules against it (aghealth.usp_EvaluateAlerts): open, escalate, resolve.

    Rules
      - Read-only on the replicas. Runs under the detect account (VIEW SERVER STATE, VIEW ANY DEFINITION).
      - Topology is resolved on every run; the collector never assumes which replica is primary.
      - An unreachable replica is recorded (IsReachable = 0), not skipped: absence of data is itself a finding.
      - If no replica, or more than one, reports PRIMARY, the snapshot is marked Failed and what each
        reachable replica sees locally is still stored. Two primaries on CLUSTER_TYPE = NONE means split brain.
      - Suspension is taken from the secondary's own view: the primary cannot see SUSPEND_FROM_PARTNER.

    Public functions
      Invoke-AgHealthCollection - take one snapshot and store it

    Author: Louis Achungo | SQL IT Tech Solutions
#>

#region Queries ---------------------------------------------------------------

# Runs on every replica. The first result set always returns one row, even if the instance is not in the AG.
$script:LocalQuery = @"
SELECT @@SERVERNAME AS replica_name,
       (SELECT ars.role_desc
        FROM sys.availability_groups ag
        JOIN sys.dm_hadr_availability_replica_states ars
          ON ars.group_id = ag.group_id AND ars.is_local = 1
        WHERE ag.name = @ag) AS role_desc;

SELECT adc.database_name, drs.is_primary_replica,
       drs.synchronization_state_desc, drs.synchronization_health_desc,
       drs.is_suspended, drs.suspend_reason_desc,
       drs.log_send_queue_size, drs.log_send_rate, drs.redo_queue_size, drs.redo_rate,
       drs.last_hardened_lsn, drs.last_commit_time
FROM sys.availability_groups ag
JOIN sys.dm_hadr_database_replica_states drs
  ON drs.group_id = ag.group_id AND drs.is_local = 1
JOIN sys.availability_databases_cluster adc
  ON adc.group_id = ag.group_id AND adc.group_database_id = drs.group_database_id
WHERE ag.name = @ag;
"@

# Runs on the primary only: it is the one replica that sees every other replica and database.
$script:PrimaryQuery = @"
SELECT ar.replica_server_name, ars.role_desc, ar.availability_mode_desc, ar.failover_mode_desc,
       ars.connected_state_desc, ars.operational_state_desc, ars.synchronization_health_desc,
       ars.last_connect_error_number, ars.last_connect_error_description
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
WHERE ag.name = @ag;

SELECT ar.replica_server_name, adc.database_name, drs.is_primary_replica,
       drs.synchronization_state_desc, drs.synchronization_health_desc,
       drs.is_suspended, drs.suspend_reason_desc,
       drs.log_send_queue_size, drs.log_send_rate, drs.redo_queue_size, drs.redo_rate,
       drs.last_hardened_lsn, drs.last_commit_time,
       -- RPO: how far this replica's last commit is behind the primary's
       CASE WHEN drs.is_primary_replica = 1 THEN 0
            WHEN drs.last_commit_time IS NULL OR p.last_commit_time IS NULL THEN NULL
            WHEN p.last_commit_time <= drs.last_commit_time THEN 0
            ELSE DATEDIFF(SECOND, drs.last_commit_time, p.last_commit_time) END AS est_data_loss_sec,
       -- RTO: time to redo what is queued
       CASE WHEN drs.is_primary_replica = 1 OR ISNULL(drs.redo_queue_size, 0) = 0 THEN 0
            WHEN drs.redo_rate > 0 THEN drs.redo_queue_size / drs.redo_rate
            ELSE NULL END AS est_recovery_sec
FROM sys.availability_groups ag
JOIN sys.dm_hadr_database_replica_states drs ON drs.group_id = ag.group_id
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
JOIN sys.availability_databases_cluster adc
  ON adc.group_id = ag.group_id AND adc.group_database_id = drs.group_database_id
OUTER APPLY (SELECT pr.last_commit_time
             FROM sys.dm_hadr_database_replica_states pr
             WHERE pr.group_database_id = drs.group_database_id AND pr.is_primary_replica = 1) p
WHERE ag.name = @ag;
"@

# Runs on the controller: the whole snapshot lands in one transaction.
$script:WriteQuery = @"
SET XACT_ABORT ON;
BEGIN TRAN;

INSERT aghealth.ReplicaState (SnapshotId, ReplicaServerName, Role, AvailabilityMode, FailoverMode, ConnectedState,
                              OperationalState, SynchronizationHealth, IsReachable, LastConnectError, LastConnectErrorText)
SELECT @snap, j.ReplicaServerName, j.Role, j.AvailabilityMode, j.FailoverMode, j.ConnectedState,
       j.OperationalState, j.SynchronizationHealth, j.IsReachable, j.LastConnectError, j.LastConnectErrorText
FROM OPENJSON(@replicas) WITH (
    ReplicaServerName sysname, Role varchar(20), AvailabilityMode varchar(30), FailoverMode varchar(20),
    ConnectedState varchar(20), OperationalState varchar(30), SynchronizationHealth varchar(20),
    IsReachable bit, LastConnectError int, LastConnectErrorText nvarchar(1024)) j;

INSERT aghealth.DatabaseState (SnapshotId, ReplicaServerName, DatabaseName, IsPrimaryReplica, SynchronizationState,
                               SynchronizationHealth, IsSuspended, SuspendReason, LogSendQueueKb, LogSendRateKbSec,
                               RedoQueueKb, RedoRateKbSec, LastHardenedLsn, LastCommitTime,
                               EstimatedDataLossSec, EstimatedRecoverySec)
SELECT @snap, j.ReplicaServerName, j.DatabaseName, j.IsPrimaryReplica, j.SynchronizationState,
       j.SynchronizationHealth, j.IsSuspended, j.SuspendReason, j.LogSendQueueKb, j.LogSendRateKbSec,
       j.RedoQueueKb, j.RedoRateKbSec, j.LastHardenedLsn, j.LastCommitTime,
       j.EstimatedDataLossSec, j.EstimatedRecoverySec
FROM OPENJSON(@databases) WITH (
    ReplicaServerName sysname, DatabaseName sysname, IsPrimaryReplica bit, SynchronizationState varchar(30),
    SynchronizationHealth varchar(20), IsSuspended bit, SuspendReason varchar(40), LogSendQueueKb bigint,
    LogSendRateKbSec bigint, RedoQueueKb bigint, RedoRateKbSec bigint, LastHardenedLsn numeric(25,0),
    LastCommitTime datetime2(3), EstimatedDataLossSec int, EstimatedRecoverySec int) j;

UPDATE aghealth.Snapshot
SET PrimaryReplica = @pri, Status = @status, ErrorMessage = @err, DurationMs = @ms
WHERE SnapshotId = @snap;

COMMIT;
"@

#endregion

#region Private helpers -------------------------------------------------------

function Get-AgHealthValue {
    # A DataRow column as a plain value: DBNull and missing columns become $null
    param($Row, [string] $Column)
    if (-not $Row.Table.Columns.Contains($Column)) { return $null }
    $v = $Row[$Column]
    if ($v -is [DBNull]) { return $null }
    $v
}

function ConvertTo-AgHealthDatabase {
    # One database-replica row, shaped for the DatabaseState table (and for JSON)
    param($Row, [string] $ReplicaName)
    $commit = Get-AgHealthValue $Row 'last_commit_time'
    $lsn    = Get-AgHealthValue $Row 'last_hardened_lsn'
    [pscustomobject]@{
        ReplicaServerName     = $ReplicaName
        DatabaseName          = Get-AgHealthValue $Row 'database_name'
        IsPrimaryReplica      = [bool](Get-AgHealthValue $Row 'is_primary_replica')
        SynchronizationState  = Get-AgHealthValue $Row 'synchronization_state_desc'
        SynchronizationHealth = Get-AgHealthValue $Row 'synchronization_health_desc'
        IsSuspended           = [bool](Get-AgHealthValue $Row 'is_suspended')
        SuspendReason         = Get-AgHealthValue $Row 'suspend_reason_desc'
        LogSendQueueKb        = Get-AgHealthValue $Row 'log_send_queue_size'
        LogSendRateKbSec      = Get-AgHealthValue $Row 'log_send_rate'
        RedoQueueKb           = Get-AgHealthValue $Row 'redo_queue_size'
        RedoRateKbSec         = Get-AgHealthValue $Row 'redo_rate'
        # Strings, so JSON keeps full precision and one date format on PowerShell 5.1 and 7
        LastHardenedLsn       = if ($null -ne $lsn)    { $lsn.ToString() } else { $null }
        LastCommitTime        = if ($null -ne $commit) { $commit.ToString('yyyy-MM-ddTHH:mm:ss.fff') } else { $null }
        EstimatedDataLossSec  = Get-AgHealthValue $Row 'est_data_loss_sec'
        EstimatedRecoverySec  = Get-AgHealthValue $Row 'est_recovery_sec'
    }
}

function Get-AgHealthProbe {
    # Connects to one replica with a short timeout and reports what it sees locally. Never throws.
    param([string] $Instance, [string] $AgName, [pscredential] $SqlCredential, [int] $ConnectTimeout)
    try {
        # Connect-DbaInstance has no -EnableException; -ErrorAction Stop makes a failed connection throw
        $connect = @{ SqlInstance = $Instance; ConnectTimeout = $ConnectTimeout; ErrorAction = 'Stop' }
        if ($SqlCredential) { $connect.SqlCredential = $SqlCredential }
        $server = Connect-DbaInstance @connect
        if (-not $server) { throw "Could not connect to $Instance." }
        $ds = Invoke-DbaQuery -SqlInstance $server -Query $script:LocalQuery -SqlParameter @{ ag = $AgName } `
                              -As DataSet -EnableException
        $me   = $ds.Tables[0].Rows[0]
        $name = Get-AgHealthValue $me 'replica_name'
        [pscustomobject]@{
            Instance  = $Instance
            Server    = $server
            Reachable = $true
            Name      = $name
            Role      = Get-AgHealthValue $me 'role_desc'          # NULL = reachable but not in this AG
            Databases = @(foreach ($row in $ds.Tables[1].Rows) { ConvertTo-AgHealthDatabase $row $name })
            Error     = $null
        }
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg.Length -gt 1000) { $msg = $msg.Substring(0, 1000) }
        [pscustomobject]@{ Instance = $Instance; Server = $null; Reachable = $false; Name = $null
                           Role = $null; Databases = @(); Error = $msg }
    }
}

#endregion

#region Public functions ------------------------------------------------------

function Invoke-AgHealthCollection {
    <#
    .SYNOPSIS
        Takes one health snapshot of an Availability Group and stores it in the control database.
    .EXAMPLE
        Invoke-AgHealthCollection -Replica $lab.Replica -AgName aglab_ag -SqlCredential $det `
                                  -ControlInstance localhost,14340 -ControlCredential $ctlCred
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Replica,
        [Parameter(Mandatory)] [string] $AgName,
        [pscredential] $SqlCredential,
        [Parameter(Mandatory)] [string] $ControlInstance,
        [string] $ControlDatabase = 'AgSyncControl',
        [pscredential] $ControlCredential,
        [ValidateRange(1, 60)] [int] $ConnectTimeout = 5
    )

    $control = @{ SqlInstance = $ControlInstance; Database = $ControlDatabase }
    if ($ControlCredential) { $control.SqlCredential = $ControlCredential }
    $clock = [Diagnostics.Stopwatch]::StartNew()

    $snapshotId = (Invoke-DbaQuery @control -EnableException -Query @"
INSERT aghealth.Snapshot (AgName, CollectorHost) OUTPUT INSERTED.SnapshotId VALUES (@ag, @host);
"@ -SqlParameter @{ ag = $AgName; host = [Environment]::MachineName }).SnapshotId

    try {
        # 1. Probe every replica independently
        $probes = @(foreach ($r in $Replica) {
            Get-AgHealthProbe -Instance $r -AgName $AgName -SqlCredential $SqlCredential -ConnectTimeout $ConnectTimeout
        })
        $reached  = @($probes | Where-Object Reachable | Sort-Object Name -Unique)
        $failed   = @($probes | Where-Object { -not $_.Reachable })
        $primary  = @($reached | Where-Object Role -eq 'PRIMARY')
        foreach ($p in $reached | Where-Object { -not $_.Role }) {
            Write-Warning "$($p.Instance) ($($p.Name)) is not a replica of AG '$AgName' - ignored."
        }
        $reached  = @($reached | Where-Object Role)
        $failText = ($failed | ForEach-Object { "$($_.Instance): $($_.Error)" }) -join ' | '

        if ($primary.Count -eq 1) {
            # 2. The primary's view of every replica and database
            $pri = $primary[0]
            $ds = Invoke-DbaQuery -SqlInstance $pri.Server -Query $script:PrimaryQuery -SqlParameter @{ ag = $AgName } `
                                  -As DataSet -EnableException

            $replicas = @(foreach ($row in $ds.Tables[0].Rows) {
                $name  = Get-AgHealthValue $row 'replica_server_name'
                $probe = $reached | Where-Object Name -eq $name
                [pscustomobject]@{
                    ReplicaServerName     = $name
                    Role                  = Get-AgHealthValue $row 'role_desc'
                    AvailabilityMode      = Get-AgHealthValue $row 'availability_mode_desc'
                    FailoverMode          = Get-AgHealthValue $row 'failover_mode_desc'
                    ConnectedState        = Get-AgHealthValue $row 'connected_state_desc'
                    OperationalState      = Get-AgHealthValue $row 'operational_state_desc'
                    SynchronizationHealth = Get-AgHealthValue $row 'synchronization_health_desc'
                    IsReachable           = [bool]$probe
                    LastConnectError      = Get-AgHealthValue $row 'last_connect_error_number'
                    # The primary's own error, or ours if the collector could not connect either
                    LastConnectErrorText  = if (-not $probe -and $failText) { $failText }
                                            else { Get-AgHealthValue $row 'last_connect_error_description' }
                }
            })

            $databases = @(foreach ($row in $ds.Tables[1].Rows) {
                $db    = ConvertTo-AgHealthDatabase $row (Get-AgHealthValue $row 'replica_server_name')
                # Suspension from the secondary's own view (SUSPEND_FROM_PARTNER is only visible there)
                $local = ($reached | Where-Object Name -eq $db.ReplicaServerName).Databases |
                         Where-Object DatabaseName -eq $db.DatabaseName
                if ($local) { $db.IsSuspended = $local.IsSuspended; $db.SuspendReason = $local.SuspendReason }
                $db
            })

            $primaryName = $pri.Name
            $status      = 'Succeeded'
            $message     = if ($failed) { "Unreachable: $failText" } else { $null }
        }
        else {
            # No single primary: store what each reachable replica sees, and fail the snapshot
            $replicas = @(foreach ($p in $reached) {
                [pscustomobject]@{ ReplicaServerName = $p.Name; Role = $p.Role; AvailabilityMode = $null
                                   FailoverMode = $null; ConnectedState = $null; OperationalState = $null
                                   SynchronizationHealth = $null; IsReachable = $true
                                   LastConnectError = $null; LastConnectErrorText = $null }
            })
            # Unreachable replicas have no name we can trust, so they are recorded by connection string
            $replicas += @(foreach ($p in $failed) {
                [pscustomobject]@{ ReplicaServerName = $p.Instance; Role = $null; AvailabilityMode = $null
                                   FailoverMode = $null; ConnectedState = $null; OperationalState = $null
                                   SynchronizationHealth = $null; IsReachable = $false
                                   LastConnectError = $null; LastConnectErrorText = $p.Error }
            })
            $databases   = @($reached | ForEach-Object { $_.Databases })
            $primaryName = $null
            $status      = 'Failed'
            $message     = if ($primary.Count -gt 1) {
                               "Split brain: $($primary.Count) replicas report PRIMARY ($(($primary.Name) -join ', '))."
                           } else { "No reachable replica reports PRIMARY. $failText".Trim() }
        }

        # 3. Store the snapshot in one transaction
        $clock.Stop()
        $null = Invoke-DbaQuery @control -EnableException -Query $script:WriteQuery -SqlParameter @{
            snap      = $snapshotId
            replicas  = ConvertTo-Json -InputObject $replicas  -Depth 3 -Compress
            databases = ConvertTo-Json -InputObject $databases -Depth 3 -Compress
            pri       = if ($primaryName) { $primaryName } else { [DBNull]::Value }
            status    = $status
            err       = if ($message) { $message } else { [DBNull]::Value }
            ms        = [int]$clock.ElapsedMilliseconds
        }
    }
    catch {
        # The collection itself failed: mark the snapshot, still evaluate (CollectionFailed), rethrow
        $err = $_.Exception.Message
        Invoke-DbaQuery @control -Query @"
UPDATE aghealth.Snapshot SET Status = 'Failed', ErrorMessage = LEFT(@err, 4000), DurationMs = @ms WHERE SnapshotId = @snap;
"@ -SqlParameter @{ err = $err; ms = [int]$clock.ElapsedMilliseconds; snap = $snapshotId }
        Invoke-DbaQuery @control -Query 'EXEC aghealth.usp_EvaluateAlerts @SnapshotId = @snap;' `
                        -SqlParameter @{ snap = $snapshotId } | Out-Null
        throw
    }

    # 4. Turn the snapshot into alerts (opens, escalates, resolves).
    #    Outside the try above on purpose: the snapshot is stored and correct even if evaluation fails,
    #    so an evaluation error must not mark it Failed. It still throws, so a scheduled run shows red.
    try {
        $alerts = @(Invoke-DbaQuery @control -EnableException -Query 'EXEC aghealth.usp_EvaluateAlerts @SnapshotId = @snap;' `
                                    -SqlParameter @{ snap = $snapshotId })
    }
    catch {
        throw "Snapshot $snapshotId was stored ($status), but alert evaluation failed: $($_.Exception.Message)"
    }

    [pscustomobject]@{
        PSTypeName     = 'AgHealth.Snapshot'
        SnapshotId     = $snapshotId
        AgName         = $AgName
        Status         = $status
        PrimaryReplica = $primaryName
        DurationMs     = [int]$clock.ElapsedMilliseconds
        Message        = $message
        Replicas       = $replicas
        Databases      = $databases
        # Every alert this snapshot touched: Opened | Escalated | Downgraded | Resolved | Ongoing
        Alerts         = $alerts
    }
}

#endregion

Export-ModuleMember -Function Invoke-AgHealthCollection
