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

    Notifications
      - Channels: Slack (one message per alert event: an incident queue) and email (one digest per run, for the DBAs).
      - Events: Opened, Escalated (Warning -> Critical), Reminder (still open, on a schedule), Resolved.
        Downgrades are not announced. Reminder schedules are data (aghealth.ReminderPolicy, per-rule overrides).
      - Every attempt is logged per alert, channel and event, so a failed channel is retried on the next run
        and a channel that already succeeded is never sent the same event twice.
      - Secrets (webhook URL, SMTP password) never live in the repo or the database: on Windows they are stored
        with DPAPI under the current user's profile (Save-AgHealthSecret), per user or, for a background task
        that stores no password, per machine with the file restricted to the user.

    Object Guard (Invoke-AgGuardCollection, after each snapshot)
      - Inventories every AG database on the primary (objects and table row counts) and reads the AgGuard
        Extended Events session: dropped objects, schema changes by logins not approved for DDL, mass data loss.
      - Every finding carries its evidence: login, host, application, statement, rows, and the recovery point.

    Public functions
      Invoke-AgHealthCollection - take one snapshot and store it
      Invoke-AgGuardCollection  - Object Guard pass on the primary of that snapshot
      Export-AgDashboardData    - write the live dashboard's data file (dashboard/index.html reads it)
      Send-AgHealthNotification - announce new, escalated and resolved alerts on every channel
      New-AgHealthSlackChannel, New-AgHealthEmailChannel, New-AgHealthTestChannel - channel definitions
      Save-AgHealthSecret, Get-AgHealthSecret - per-user encrypted secrets (Windows)

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
       -- RPO: how far this replica's last commit is behind the primary's.
       -- A synchronous replica that is SYNCHRONIZED hardens every commit before the primary acknowledges it:
       -- nothing committed can be lost there. Its last_commit_time follows REDO, not hardening, so comparing
       -- commit times would report a redo delay as data loss.
       CASE WHEN drs.is_primary_replica = 1 THEN 0
            WHEN ar.availability_mode_desc = 'SYNCHRONOUS_COMMIT' AND drs.synchronization_state_desc = 'SYNCHRONIZED' THEN 0
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

# Object Guard, on the primary, once per AG database: what exists, and how many rows every table has
$script:GuardInventoryQuery = @"
SELECT DB_NAME() AS DatabaseName, s.name AS SchemaName, o.name AS ObjectName, o.type_desc AS ObjectType,
       o.object_id AS ObjectId, o.create_date AS CreateDate, o.modify_date AS ModifyDate,
       CASE WHEN o.type = 'U' THEN (SELECT SUM(p.row_count) FROM sys.dm_db_partition_stats p
                                    WHERE p.object_id = o.object_id AND p.index_id IN (0, 1)) END AS TableRows
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND o.type IN ('U', 'V', 'P', 'FN', 'IF', 'TF', 'TR', 'SN', 'SO');
"@

# Object Guard, on the primary: new events from the AgGuard Extended Events session (see ops/Install-AgGuard.ps1)
$script:GuardEventsQuery = @"
SET NOCOUNT ON;
DECLARE @path nvarchar(260) =
    (SELECT TOP (1) CAST(t.target_data AS xml).value('(EventFileTarget/File/@name)[1]', 'nvarchar(260)')
     FROM sys.dm_xe_sessions s
     JOIN sys.dm_xe_session_targets t ON t.event_session_address = s.address
     WHERE s.name = N'AgGuard' AND t.target_name = N'event_file');
SELECT CAST(CASE WHEN @path IS NULL THEN 0 ELSE 1 END AS bit) AS SessionRunning, @path AS CurrentFile;

IF @path IS NULL
    SELECT CAST(NULL AS datetime2(7)) AS EventTime, CAST(NULL AS varchar(40)) AS EventName WHERE 1 = 0;
ELSE
BEGIN
    -- Every file of the session (it rolls over), read from the folder of the current one (Windows or Linux)
    DECLARE @pattern nvarchar(260) = LEFT(@path, LEN(@path) - PATINDEX(N'%[\/]%', REVERSE(@path)) + 1) + N'AgGuard*.xel';
    -- Read first, filter after: a WHERE on timestamp_utc is pushed down into the file reader,
    -- which returns no rows at all on some builds. A temp table keeps the filter in our hands.
    SELECT f.timestamp_utc, f.event_data INTO #raw
    FROM sys.fn_xe_file_target_read_file(@pattern, NULL, NULL, NULL) f;

    SELECT @@SERVERNAME AS ReplicaServerName,
           f.timestamp_utc AS EventTime,
           x.d.value('(event/@name)[1]', 'varchar(40)') AS EventName,
           COALESCE(DB_NAME(x.d.value('(event/data[@name="database_id"]/value)[1]', 'int')),
                    x.d.value('(event/action[@name="database_name"]/value)[1]', 'nvarchar(128)')) AS DatabaseName,
           x.d.value('(event/data[@name="object_id"]/value)[1]', 'int') AS ObjectId,
           x.d.value('(event/data[@name="object_name"]/value)[1]', 'nvarchar(128)') AS ObjectName,
           x.d.value('(event/data[@name="object_type"]/text)[1]', 'nvarchar(60)') AS ObjectType,
           x.d.value('(event/data[@name="ddl_phase"]/text)[1]', 'varchar(20)') AS DdlPhase,
           x.d.value('(event/action[@name="server_principal_name"]/value)[1]', 'nvarchar(128)') AS LoginName,
           x.d.value('(event/action[@name="client_hostname"]/value)[1]', 'nvarchar(128)') AS HostName,
           x.d.value('(event/action[@name="client_app_name"]/value)[1]', 'nvarchar(256)') AS AppName,
           x.d.value('(event/action[@name="session_id"]/value)[1]', 'int') AS SessionId,
           COALESCE(x.d.value('(event/data[@name="transaction_id"]/value)[1]', 'bigint'),
                    x.d.value('(event/action[@name="transaction_id"]/value)[1]', 'bigint')) AS TransactionId,
           x.d.value('(event/data[@name="row_count"]/value)[1]', 'bigint') AS RowCnt,
           x.d.value('(event/data[@name="duration"]/value)[1]', 'bigint') AS DurationUs,
           COALESCE(x.d.value('(event/data[@name="statement"]/value)[1]', 'nvarchar(max)'),
                    x.d.value('(event/action[@name="sql_text"]/value)[1]', 'nvarchar(max)')) AS Statement
    FROM #raw f
    CROSS APPLY (SELECT CAST(f.event_data AS xml) AS d) x
    WHERE f.timestamp_utc > CONVERT(datetime2(7), @since)
    ORDER BY f.timestamp_utc;
END;
"@

# Recovery plan, on every replica: the backups of one database (msdb is per replica: backups can run on any of them)
$script:GuardBackupQuery = @"
SELECT @@SERVERNAME AS ServerName, b.backup_set_id AS BackupSetId, b.type AS BackupType, b.is_copy_only AS IsCopyOnly,
       DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), b.backup_start_date)  AS StartUtc,
       DATEADD(MINUTE, DATEDIFF(MINUTE, SYSDATETIME(), SYSUTCDATETIME()), b.backup_finish_date) AS FinishUtc,
       b.first_lsn AS FirstLsn, b.last_lsn AS LastLsn, b.backup_set_uuid AS SetUuid,
       b.differential_base_guid AS DiffBaseGuid, m.family_sequence_number AS Family, m.physical_device_name AS Device,
       m.device_type AS DeviceType
FROM msdb.dbo.backupset b
JOIN msdb.dbo.backupmediafamily m ON m.media_set_id = b.media_set_id
WHERE b.database_name = @db
  AND b.type IN ('D', 'I', 'L')
  AND m.device_type IN (2, 9)                     -- disk and URL; not the virtual devices of automatic seeding
  AND b.backup_finish_date >= DATEADD(DAY, -@days, SYSDATETIME());
"@

# Recovery plan, on the server holding the full backup: the files to move, and where restores go by default
$script:GuardRestoreTargetQuery = @"
SELECT f.logical_name AS LogicalName, f.file_type AS FileType, f.file_number AS FileNumber,
       CONVERT(nvarchar(260), SERVERPROPERTY('InstanceDefaultDataPath')) AS DataPath,
       CONVERT(nvarchar(260), SERVERPROPERTY('InstanceDefaultLogPath'))  AS LogPath
FROM msdb.dbo.backupfile f
WHERE f.backup_set_id = @set AND f.file_type IN ('D', 'L')
ORDER BY f.file_type, f.file_number;
"@

# Recovery plan, on the primary: the table's columns, key and identity (for copy back and the checksum)
$script:GuardTableShapeQuery = @"
SELECT c.name AS ColumnName, c.column_id AS ColumnId, c.is_identity AS IsIdentity, t.name AS TypeName,
       CONVERT(bit, CASE WHEN c.is_computed = 1 OR t.name IN ('timestamp', 'rowversion') THEN 1 ELSE 0 END) AS IsGenerated,
       CONVERT(bit, CASE WHEN t.name IN ('text', 'ntext', 'image', 'xml', 'geography', 'geometry', 'hierarchyid', 'sql_variant')
                           OR c.max_length = -1 THEN 1 ELSE 0 END) AS NoChecksum,
       ic.key_ordinal AS KeyOrdinal
FROM sys.columns c
JOIN sys.types t ON t.user_type_id = c.user_type_id
LEFT JOIN sys.indexes i ON i.object_id = c.object_id AND i.is_primary_key = 1
LEFT JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.column_id = c.column_id
WHERE c.object_id = OBJECT_ID(@obj)
ORDER BY c.column_id;
SELECT CONVERT(nvarchar(260), SERVERPROPERTY('InstanceDefaultBackupPath')) AS BackupPath,
       DATEDIFF(MINUTE, SYSUTCDATETIME(), SYSDATETIME()) AS UtcOffsetMinutes;
"@

# Dashboard export, on the controller: everything the live dashboard shows, for every AG, in one round trip
$script:DashboardQuery = @"
SET NOCOUNT ON;
DECLARE @since datetime2(3) = DATEADD(MINUTE, -@trend, SYSUTCDATETIME());
CREATE TABLE #latest (AgName sysname PRIMARY KEY, SnapshotId bigint);
INSERT #latest
SELECT AgName, MAX(SnapshotId) FROM aghealth.Snapshot
WHERE Status <> 'Running' AND CollectedAt >= DATEADD(DAY, -7, SYSUTCDATETIME())
GROUP BY AgName;

-- 0 every AG and its latest snapshot
SELECT s.AgName, s.SnapshotId, s.PrimaryReplica, s.CollectedAt, s.Status, s.DurationMs, s.ErrorMessage,
       d.DisplayName, d.Environment,
       CONVERT(bit, ISNULL(d.IsVisible, 1)) AS IsVisible, ISNULL(d.SortOrder, 100) AS SortOrder
FROM #latest l JOIN aghealth.Snapshot s ON s.SnapshotId = l.SnapshotId
LEFT JOIN aghealth.AgDisplay d ON d.AgName = s.AgName;
-- 1 replicas
SELECT l.AgName, r.ReplicaServerName, r.Role, r.AvailabilityMode, r.FailoverMode, r.ConnectedState,
       r.OperationalState, r.SynchronizationHealth, r.IsReachable, r.LastConnectErrorText
FROM #latest l JOIN aghealth.ReplicaState r ON r.SnapshotId = l.SnapshotId;
-- 2 databases
SELECT l.AgName, d.ReplicaServerName, d.DatabaseName, d.IsPrimaryReplica, d.SynchronizationState, d.SynchronizationHealth,
       d.IsSuspended, d.SuspendReason, d.LogSendQueueKb, d.LogSendRateKbSec, d.RedoQueueKb, d.RedoRateKbSec,
       d.EstimatedDataLossSec, d.EstimatedRecoverySec, d.LastCommitTime
FROM #latest l JOIN aghealth.DatabaseState d ON d.SnapshotId = l.SnapshotId;
-- 3 trends of the secondaries
SELECT s.AgName, s.CollectedAt AS t, d.ReplicaServerName, d.DatabaseName, d.LogSendQueueKb, d.RedoQueueKb,
       d.EstimatedDataLossSec, d.EstimatedRecoverySec
FROM aghealth.Snapshot s JOIN aghealth.DatabaseState d ON d.SnapshotId = s.SnapshotId
WHERE s.CollectedAt >= @since AND d.IsPrimaryReplica = 0
ORDER BY s.SnapshotId;
-- 4 snapshot strip
SELECT AgName, CollectedAt AS t, Status FROM aghealth.Snapshot WHERE CollectedAt >= @since ORDER BY SnapshotId;
-- 5 open alerts
SELECT a.AlertId, a.AgName, r.RuleName, a.Severity, a.ReplicaServerName, a.DatabaseName, a.ObjectName, a.FirstSeenAt,
       a.LastSeenAt, a.LastValue, a.Message, r.Runbook, r.Metric, r.Operator, r.ExpectedValue, r.WarnThreshold,
       r.CritThreshold, a.ReminderCount, a.NotifiedAt
FROM aghealth.Alert a JOIN aghealth.AlertRule r ON r.RuleId = a.RuleId
WHERE a.State = 'Open';
-- 6 their evidence
SELECT e.AlertId, e.SortOrder, e.Label, e.Value
FROM aghealth.AlertEvidence e JOIN aghealth.Alert a ON a.AlertId = e.AlertId
WHERE a.State = 'Open' ORDER BY e.AlertId, e.SortOrder;
-- 7 their scripts
SELECT s.AlertId, s.Step, s.Stage, s.Title, s.RunOn, s.Caution, s.Sql
FROM aghealth.AlertScript s JOIN aghealth.Alert a ON a.AlertId = s.AlertId
WHERE a.State = 'Open' ORDER BY s.AlertId, s.Step;
-- 8 resolved in the last 24 hours
SELECT TOP (25) a.AlertId, a.AgName, r.RuleName, a.Severity, a.ReplicaServerName, a.DatabaseName, a.ObjectName,
       a.FirstSeenAt, a.ResolvedAt, a.ResolvedBy, a.ResolutionNote
FROM aghealth.Alert a JOIN aghealth.AlertRule r ON r.RuleId = a.RuleId
WHERE a.State = 'Resolved' AND a.ResolvedAt >= DATEADD(DAY, -1, SYSUTCDATETIME())
ORDER BY a.ResolvedAt DESC;
-- 9 Object Guard timeline
IF OBJECT_ID('aghealth.ObjectEvent') IS NOT NULL
    SELECT TOP (60) o.ObjectEventId, o.AgName, o.EventType, o.DatabaseName, o.SchemaName, o.ObjectName, o.ObjectType,
           o.DetectedAt, o.OccurredAt, o.LoginName, o.HostName, o.AppName, o.RowsBefore, o.RowsAfter, o.IsApproved,
           o.AlertId, dd.Decision, dd.DecidedBy, dd.ConfirmedWith
    FROM aghealth.ObjectEvent o
    OUTER APPLY (SELECT TOP (1) d.Decision, d.DecidedBy, d.ConfirmedWith FROM aghealth.AlertDecision d
                 WHERE d.AlertId = o.AlertId ORDER BY d.DecisionId DESC) dd
    ORDER BY o.ObjectEventId DESC;
ELSE
    SELECT CAST(NULL AS bigint) AS ObjectEventId, CAST(NULL AS sysname) AS AgName WHERE 1 = 0;
-- 10 replica drift: the latest successful AG Sync run of each AG
IF OBJECT_ID('agsync.SyncRun') IS NOT NULL
    SELECT r.AgName, r.RunId, r.Mode, r.StartedAt, f.ObjectType, f.ObjectName, f.SourceReplica, f.TargetReplica,
           f.DriftType, f.Detail, f.Action
    FROM (SELECT AgName, MAX(RunId) AS RunId FROM agsync.SyncRun WHERE Status = 'Succeeded' GROUP BY AgName) l
    JOIN agsync.SyncRun r ON r.RunId = l.RunId
    LEFT JOIN agsync.DriftFinding f ON f.RunId = r.RunId;
ELSE
    SELECT CAST(NULL AS sysname) AS AgName WHERE 1 = 0;
-- 11 approved drift exceptions (secondary-only objects that are meant to be there)
IF OBJECT_ID('aghealth.DriftException') IS NOT NULL
    SELECT e.AgName, e.ExceptionId, e.ReplicaServerName, e.ObjectType, e.ObjectName, e.Justification, e.ApprovedBy,
           e.ApprovedAt, e.ExpiresAt, e.PrimaryAtApproval,
           CONVERT(bit, CASE WHEN ISNULL(e.PrimaryAtApproval, N'') <> ISNULL(l.PrimaryReplica, N'') THEN 1 ELSE 0 END) AS OnHold
    FROM aghealth.DriftException e
    OUTER APPLY (SELECT TOP (1) s.PrimaryReplica FROM aghealth.Snapshot s
                 WHERE s.AgName = e.AgName AND s.Status = 'Succeeded' ORDER BY s.SnapshotId DESC) l
    WHERE e.RevokedAt IS NULL AND e.ExpiresAt > SYSUTCDATETIME();
ELSE
    SELECT CAST(NULL AS sysname) AS AgName WHERE 1 = 0;
-- 12 how many objects Object Guard watches
IF OBJECT_ID('aghealth.ObjectInventory') IS NOT NULL
    SELECT AgName, COUNT(*) AS Objects, COUNT(DISTINCT DatabaseName) AS Databases,
           SUM(CASE WHEN ObjectType = 'USER_TABLE' THEN 1 ELSE 0 END) AS Tables
    FROM aghealth.ObjectInventory WHERE IsPresent = 1 GROUP BY AgName;
ELSE
    SELECT CAST(NULL AS sysname) AS AgName WHERE 1 = 0;
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

function Save-AgHealthAlertPlan {
    # Stores evidence lines and script steps for one alert (only if it has none yet)
    param([hashtable] $Control, [long] $AlertId, [object[]] $Evidence, [object[]] $Steps)
    $null = Invoke-DbaQuery @Control -EnableException -Query @"
SET XACT_ABORT ON;
BEGIN TRAN;
IF NOT EXISTS (SELECT 1 FROM aghealth.AlertScript WHERE AlertId = @a)
    INSERT aghealth.AlertScript (AlertId, Step, Stage, Title, RunOn, Caution, Sql)
    SELECT @a, j.Step, j.Stage, j.Title, j.RunOn, j.Caution, j.Sql
    FROM OPENJSON(@steps) WITH (Step int, Stage varchar(20), Title nvarchar(200), RunOn nvarchar(128),
                                Caution nvarchar(400), Sql nvarchar(max)) j;
INSERT aghealth.AlertEvidence (AlertId, SortOrder, Label, Value)
SELECT @a, j.SortOrder, j.Label, LEFT(j.Value, 2000)
FROM OPENJSON(@ev) WITH (SortOrder int, Label nvarchar(60), Value nvarchar(max)) j
WHERE j.Value IS NOT NULL AND j.Value <> N''
  AND NOT EXISTS (SELECT 1 FROM aghealth.AlertEvidence e WHERE e.AlertId = @a AND e.SortOrder = j.SortOrder);
COMMIT;
"@ -SqlParameter @{ a = $AlertId; steps = ConvertTo-Json -InputObject @($Steps) -Depth 3 -Compress
                    ev = ConvertTo-Json -InputObject @($Evidence) -Depth 3 -Compress }
}

function New-AgHealthAlertPlan {
    # Evidence collected the moment an AG health alert opens, and Diagnose / Fix / Verify scripts filled in with
    # this AG, replica and database. The fix is chosen from the evidence. Nothing is run: a person (or, later, an
    # agent within the approval policy) runs the steps.
    [CmdletBinding()]
    param($Alert, [hashtable] $Context, [hashtable] $Control)
    $ag = $Context.AgName; $P = $Context.Primary
    $R  = [string]$Alert.ReplicaServerName; $D = [string]$Alert.DatabaseName; $rule = [string]$Alert.RuleName
    $q   = { param([string] $n) '[' + $n.Replace(']', ']]') + ']' }
    $lit = { param([string] $v) "N'" + $v.Replace("'", "''") + "'" }
    $ev  = [Collections.Generic.List[object]]::new()
    $steps = [Collections.Generic.List[object]]::new()
    $addEv = { param([string] $Label, $Value) if ("$Value") { $ev.Add([pscustomobject]@{ SortOrder = $ev.Count + 1; Label = $Label; Value = [string]$Value }) } }
    $add = { param($Stage, $Title, $RunOn, $Caution, [string[]] $Sql)
             $steps.Add([pscustomobject]@{ Step = $steps.Count + 1; Stage = $Stage; Title = $Title; RunOn = $RunOn
                                           Caution = $Caution; Sql = ($Sql -join "`n") }) }
    $live = { param([string] $Name, [string] $Query, [string] $Database = 'master')
              $srv = $Context.Servers[$Name]
              # No output (not $null) when it cannot be read, so @(& $live ...) is empty rather than one null row
              if (-not $srv) { return }
              try { Invoke-DbaQuery -SqlInstance $srv -Database $Database -Query $Query -EnableException } catch { } }
    $fmtKb  = { param($v) Format-AgHealthValue 'LogSendQueueKb' $v }
    $fmtSec = { param($v) Format-AgHealthValue 'EstimatedDataLossSec' $v }

    $db    = $Context.Databases | Where-Object { $_.ReplicaServerName -eq $R -and $_.DatabaseName -eq $D } | Select-Object -First 1
    $rep   = $Context.Replicas  | Where-Object { $_.ReplicaServerName -eq $R } | Select-Object -First 1
    $qD = & $q $D; $lD = & $lit $D; $lAg = & $lit $ag

    # Reusable queries, already pointed at this AG and database
    $stateSql = @(
        '-- Every replica of this database, as the primary sees it',
        'SELECT ar.replica_server_name, drs.synchronization_state_desc, drs.synchronization_health_desc,',
        '       drs.is_suspended, drs.suspend_reason_desc,',
        '       drs.log_send_queue_size AS send_queue_kb, drs.log_send_rate AS send_kb_per_s,',
        '       drs.redo_queue_size AS redo_queue_kb, drs.redo_rate AS redo_kb_per_s, drs.last_commit_time',
        'FROM sys.dm_hadr_database_replica_states AS drs',
        'JOIN sys.availability_replicas AS ar ON ar.replica_id = drs.replica_id',
        "WHERE drs.database_id = DB_ID($lD);")
    $localSql = @(
        "-- What $R itself reports for $D (the suspend reason is only reliable here)",
        'SELECT DB_NAME(drs.database_id) AS database_name, drs.synchronization_state_desc, drs.is_suspended,',
        '       drs.suspend_reason_desc, drs.redo_queue_size AS redo_queue_kb, drs.redo_rate AS redo_kb_per_s',
        'FROM sys.dm_hadr_database_replica_states AS drs',
        "WHERE drs.is_local = 1 AND drs.database_id = DB_ID($lD);")
    $replicaSql = @(
        '-- Every replica of the AG: connection state and the last connection error',
        'SELECT ar.replica_server_name, ar.availability_mode_desc, ars.role_desc, ars.connected_state_desc,',
        '       ars.synchronization_health_desc, ars.last_connect_error_number, ars.last_connect_error_description,',
        '       ars.last_connect_error_timestamp',
        'FROM sys.availability_groups AS ag',
        'JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id',
        'LEFT JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id',
        "WHERE ag.name = $lAg;")
    $logSql = @(
        "-- How full the log of $D is on the primary, and what stops it from truncating",
        "USE $qD;",
        'SELECT d.log_reuse_wait_desc, CONVERT(decimal(5,1), u.used_log_space_in_percent) AS log_used_pct,',
        '       u.total_log_size_in_bytes / 1048576 AS log_size_mb',
        'FROM sys.dm_db_log_space_usage AS u CROSS JOIN sys.databases AS d WHERE d.database_id = DB_ID();')
    $tranSql = @(
        "-- The open transactions writing the most log in $D on the primary (the usual cause of a growing send queue)",
        'SELECT TOP (5) s.session_id, s.login_name, s.host_name, s.program_name,',
        '       dt.database_transaction_log_bytes_used / 1048576 AS log_mb, at.transaction_begin_time',
        'FROM sys.dm_tran_database_transactions AS dt',
        'JOIN sys.dm_tran_session_transactions AS st ON st.transaction_id = dt.transaction_id',
        'JOIN sys.dm_tran_active_transactions AS at ON at.transaction_id = dt.transaction_id',
        'JOIN sys.dm_exec_sessions AS s ON s.session_id = st.session_id',
        "WHERE dt.database_id = DB_ID($lD)",
        'ORDER BY dt.database_transaction_log_bytes_used DESC;')
    $endpointSql = @(
        "-- The HADR endpoint on ${R}: started? which port? and when does its certificate expire?",
        'SELECT e.name, e.state_desc, t.port, e.role_desc, e.connection_auth_desc, c.name AS certificate, c.expiry_date',
        'FROM sys.database_mirroring_endpoints AS e',
        'LEFT JOIN sys.tcp_endpoints AS t ON t.endpoint_id = e.endpoint_id',
        'LEFT JOIN sys.certificates AS c ON c.certificate_id = e.certificate_id;')
    $redoSql = @(
        "-- Is redo on $R blocked by a query on this readable secondary? Who is blocking it?",
        'SELECT r.session_id AS redo_session, r.command, r.wait_type, r.wait_time / 1000 AS wait_s,',
        '       r.blocking_session_id, s.login_name, s.host_name, s.program_name, t.text AS blocker_sql',
        'FROM sys.dm_exec_requests AS r',
        'LEFT JOIN sys.dm_exec_sessions AS s ON s.session_id = r.blocking_session_id',
        'LEFT JOIN sys.dm_exec_connections AS c ON c.session_id = r.blocking_session_id',
        'OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) AS t',
        "WHERE r.command IN ('DB STARTUP', 'PARALLEL REDO TASK', 'PARALLEL REDO HELP TASK') AND r.blocking_session_id > 0;")
    # Every Fix starts with guards: the right server, the state it is meant to change, and who authorized it
    $guard = { param([string] $Server, [string[]] $StillTrue, [string] $NothingToDo)
        @("-- Guards: stop on the wrong server; do nothing if the problem has already cleared",
          "IF @@SERVERNAME <> $(& $lit $Server) THROW 50100, 'Wrong server: run this on $Server.', 1;") +
        $(if ($StillTrue) { @("IF NOT EXISTS ($($StillTrue -join ' '))",
                              "BEGIN PRINT N'$($NothingToDo.Replace("'", "''"))'; RETURN; END;") } else { @() }) +
        @('-- Authorized by: <your name>, <incident or change reference>') }
    $suspendedCheck = @("SELECT 1 FROM sys.dm_hadr_database_replica_states WHERE is_local = 1 AND is_suspended = 1 AND database_id = DB_ID($lD)")
    # Verify: three readings, 10 seconds apart. Healthy = moving every time and the send queue not growing.
    $sustainedSql = @(
        "-- Three readings 10 seconds apart: healthy means $R is SYNCHRONIZING or SYNCHRONIZED every time,",
        '-- not suspended, and its send queue is not growing. One good reading is not enough.',
        'DROP TABLE IF EXISTS #v; CREATE TABLE #v (reading int, at_utc datetime2(0), replica sysname, state nvarchar(60),',
        '       suspended bit, send_queue_kb bigint, redo_queue_kb bigint);',
        'DECLARE @i int = 1;',
        'WHILE @i <= 3',
        'BEGIN',
        '    INSERT #v SELECT @i, SYSUTCDATETIME(), ar.replica_server_name, drs.synchronization_state_desc, drs.is_suspended,',
        '           drs.log_send_queue_size, drs.redo_queue_size',
        '    FROM sys.dm_hadr_database_replica_states AS drs JOIN sys.availability_replicas AS ar ON ar.replica_id = drs.replica_id',
        "    WHERE drs.database_id = DB_ID($lD);",
        "    IF @i < 3 WAITFOR DELAY '00:00:10';",
        '    SET @i += 1;',
        'END;',
        'SELECT replica, reading, at_utc, state, suspended, send_queue_kb, redo_queue_kb FROM #v ORDER BY replica, reading;')
    $notAvailable = { param([string] $What, [string] $Server) "Not available: could not read $What from $Server." }
    $others = { ($Context.Databases | Where-Object { $_.DatabaseName -eq $D -and $_.ReplicaServerName -ne $R -and -not $_.IsPrimaryReplica } |
                 ForEach-Object { '{0} {1}' -f $_.ReplicaServerName, ($(if ($_.IsSuspended) { 'suspended' } else { ([string]$_.SynchronizationState).ToLower() })) }) -join ', ' }

    # Log reuse wait, said as what it means. NOTHING is not a restriction, so it is never called one.
    $logWhy = { param([string] $Wait)
        switch -Regex ($Wait) {
            '^NOTHING$'              { 'no log reuse restriction reported at this reading'; break }
            '^AVAILABILITY_REPLICA$' { 'log reuse is waiting on availability replica progress: the log can grow while a replica is behind and transactions keep writing'; break }
            '^LOG_BACKUP$'           { 'a transaction log backup is required for log reuse'; break }
            '^ACTIVE_TRANSACTION$'   { 'an active transaction is preventing log reuse'; break }
            '^$'                     { 'log reuse information unavailable'; break }
            default                  { "log reuse is waiting on $Wait" } } }
    $logLine = { param($l, [string] $Extra)
        '{0}% of {1} MB used; {2}{3}.' -f $l.log_used_pct, $l.log_size_mb, (& $logWhy ([string]$l.log_reuse_wait_desc)), $Extra }

    # Observed movement: what changed between the last two snapshots of this replica and database,
    # measured by the collector, rather than the rate SQL Server last reported
    $hist = @()
    try {
        $hist = @(Invoke-DbaQuery @Control -EnableException -SqlParameter @{ ag = $ag; r = $R; d = $D } -Query @"
SELECT TOP (2) s.CollectedAt, d.LogSendQueueKb, d.RedoQueueKb, d.LastHardenedLsn
FROM aghealth.DatabaseState AS d JOIN aghealth.Snapshot AS s ON s.SnapshotId = d.SnapshotId
WHERE s.AgName = @ag AND d.ReplicaServerName = @r AND d.DatabaseName = @d
ORDER BY d.SnapshotId DESC;
"@)
    } catch { }
    $num = { param($v) if ($null -eq $v -or $v -is [DBNull] -or "$v" -eq '') { $null } else { [double]$v } }
    $lsnStalled = $null
    $observed = if ($hist.Count -lt 2) { 'Not available: fewer than two snapshots of this database on this replica so far.' } else {
        $secs = [int]([datetime]$hist[0].CollectedAt - [datetime]$hist[1].CollectedAt).TotalSeconds
        $lsnStalled = ("$($hist[0].LastHardenedLsn)" -ne '' -and "$($hist[0].LastHardenedLsn)" -eq "$($hist[1].LastHardenedLsn)")
        $delta = { param([string] $Name, $Now, $Before)
            $n = & $num $Now; $b = & $num $Before
            if ($null -eq $n -or $null -eq $b) { "$Name queue not reported" }
            elseif ($n -gt $b) { "$Name queue grew by $(& $fmtKb ($n - $b))" }
            elseif ($n -lt $b) { "$Name queue shrank by $(& $fmtKb ($b - $n))" }
            else { "$Name queue unchanged at $(& $fmtKb $n)" } }
        $lsnText = if ("$($hist[0].LastHardenedLsn)" -eq '') { 'hardened LSN not reported' }
                   elseif ($lsnStalled) { 'hardened LSN did not advance' } else { 'hardened LSN advanced' }
        'Over the last {0} s (two snapshots): {1}; {2}; {3}.' -f $secs, $lsnText,
            (& $delta 'send' $hist[0].LogSendQueueKb $hist[1].LogSendQueueKb), (& $delta 'redo' $hist[0].RedoQueueKb $hist[1].RedoQueueKb)
    }
    $rates = { param($d) 'send {0}/s, redo {1}/s (the rates SQL Server last reported; they can reflect earlier activity, not this moment)' -f
                   (& $fmtKb $d.LogSendRateKbSec), (& $fmtKb $d.RedoRateKbSec) }

    # RPO, said honestly: measured lag, zero for now, growing exposure, possibly stale, or unknown
    $rpo = { param($d)
        if (-not $d) { return 'Unknown: this replica and database were not in the snapshot.' }
        $e = & $num $d.EstimatedDataLossSec
        $at = if ("$($d.LastCommitTime)") { '{0:HH:mm:ss} UTC' -f [datetime]$d.LastCommitTime } else { 'an unknown time' }
        $moving = -not $d.IsSuspended -and ([string]$d.SynchronizationState) -in 'SYNCHRONIZING', 'SYNCHRONIZED'
        if ($null -eq $e) { 'Unknown: the last commit times of the primary and this replica could not be compared.' }
        elseif (-not $moving -and $e -gt 0) { "$(& $fmtSec $e) and growing: $R last received a commit at $at, and the primary has committed since." }
        elseif (-not $moving) { "0 s for now, not a guarantee: no commit on the primary since $R stopped receiving at $at. Exposure starts with the next commit and grows until data movement resumes." }
        elseif ($lsnStalled -and $e -gt 0) { "$(& $fmtSec $e), possibly stale: the hardened LSN did not advance between the last two snapshots." }
        else { "$(& $fmtSec $e) measured: last commit times compared at this snapshot." } }

    switch ($rule) {
        'DatabaseSuspended' {
            $reason = if ($db) { [string]$db.SuspendReason } else { '' }
            $meaning = switch -Regex ($reason) {
                '^SUSPEND_FROM_USER$'    { 'Suspended by an ALTER DATABASE ... SET HADR SUSPEND command, from a person, a job or a script. Safe to resume once you know why it was run.'; break }
                '^SUSPEND_FROM_PARTNER$' { 'Suspended because of the partner replica. Resume it from the primary.'; break }
                '^SUSPEND_FROM_(REDO|APPLY|UNDO|RESTART|CAPTURE|REVALIDATION|XRF_UPDATE)$' {
                    "$R suspended itself after an error ($(($reason -replace 'SUSPEND_FROM_', '').ToLower())). A RESUME fails again until the cause is fixed (disk full, a file path that does not exist here, corruption): read its error log first."; break }
                default { 'Reason not reported. Read it on the replica itself (step 1).' }
            }
            & $addEv 'Suspend reason' $(if ($reason) { $reason } else { 'not reported' })
            & $addEv 'What it means' $meaning
            $log = @(& $live $P (($logSql | Select-Object -Skip 2) -join "`n") $D)
            if ($log.Count) {
                $extra = if ([string]$log[0].log_reuse_wait_desc -eq 'NOTHING') {
                    ". While $R stays suspended, the primary keeps the log it has not sent there, so reuse can start waiting on AVAILABILITY_REPLICA" } else { '' }
                & $addEv 'Primary log' (& $logLine $log[0] $extra)
            } else { & $addEv 'Primary log' (& $notAvailable 'the log space' $P) }
            & $addEv 'Data at risk (RPO)' (& $rpo $db)
            & $addEv 'Observed movement' $observed
            & $addEv 'Other replicas' (& $others)
            & $add 'Diagnose' "Read the suspend reason and the error log on $R" $R $null (@($localSql) + @('',
                  '-- The error log around the suspension. SQL Server 2022 and later: VIEW ANY ERROR LOG;',
                  '-- earlier versions: membership of securityadmin or sysadmin.',
                  "EXEC sys.xp_readerrorlog 0, 1, $lD;"))
            & $add 'Diagnose' 'How full the primary log is, and why it cannot truncate' $P $null $logSql
            if ($reason -eq 'SUSPEND_FROM_PARTNER') {
                & $add 'Fix' "Resume data movement for $D" $P $null (@(& $guard $P) + @("ALTER DATABASE $qD SET HADR RESUME;"))
            } else {
                $caution = if ($reason -match '^SUSPEND_FROM_(REDO|APPLY|UNDO|RESTART|CAPTURE|REVALIDATION|XRF_UPDATE)$') {
                    'Fix the cause in the error log first: a RESUME before that suspends again.' } else { $null }
                & $add 'Fix' "Resume data movement for $D on $R" $R $caution (@(& $guard $R $suspendedCheck "$D is not suspended on ${R}: nothing to do.") +
                    @("ALTER DATABASE $qD SET HADR RESUME;"))
            }
            & $add 'Verify' "$R keeps moving: three readings, 10 seconds apart" $P $null $sustainedSql
        }
        { $_ -in 'SyncSecondaryNotSynced', 'AsyncSecondaryNotMoving' } {
            & $addEv 'State now' $(if ($db) { "$(([string]$db.SynchronizationState).ToLower())$(if ($db.IsSuspended) { ', suspended (' + $db.SuspendReason + ')' })" })
            & $addEv 'Connection' $(if ($rep) { "$([string]$rep.ConnectedState)$(if ($rep.LastConnectErrorText) { ': ' + $rep.LastConnectErrorText })" })
            if ($db) {
                & $addEv 'Queues' ('send {0}, redo {1}' -f (& $fmtKb $db.LogSendQueueKb), (& $fmtKb $db.RedoQueueKb))
                & $addEv 'Last reported rates' (& $rates $db)
            } else { & $addEv 'Queues' "Not available: $R and $D were not in the snapshot." }
            & $addEv 'Observed movement' $observed
            & $addEv 'Data at risk (RPO)' (& $rpo $db)
            & $addEv 'What it means' $(if ($rule -eq 'SyncSecondaryNotSynced') { "A failover to $R now would lose data, or be refused." } else { "$R, the DR copy, is falling behind." })
            & $add 'Diagnose' 'Every replica of the database, and every connection' $P $null (@($stateSql) + @('') + @($replicaSql))
            & $add 'Diagnose' "What $R itself reports" $R $null $localSql
            if ($db -and $db.IsSuspended) {
                & $add 'Fix' "Resume data movement for $D on $R" $R $null (@(& $guard $R $suspendedCheck "$D is not suspended on ${R}: nothing to do.") +
                    @("ALTER DATABASE $qD SET HADR RESUME;"))
            } elseif ($rep -and $rep.ConnectedState -eq 'DISCONNECTED') {
                & $add 'Fix' "Reconnect: start the HADR endpoint on $R" $R 'Only if the endpoint query shows it STOPPED; otherwise check the certificate, the port and the network.' (
                    @($endpointSql) + @('') + @(& $guard $R @("SELECT 1 FROM sys.database_mirroring_endpoints WHERE state_desc <> 'STARTED'") "The HADR endpoint on $R is already STARTED: the cause is elsewhere.") +
                    @('ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED;   -- use the endpoint name from the query above'))
            }
            & $add 'Verify' "$R keeps moving: three readings, 10 seconds apart" $P $null $sustainedSql
        }
        'ReplicaDisconnected' {
            & $addEv 'Connection' $(if ($rep) { [string]$rep.ConnectedState })
            & $addEv 'Last connect error' $(if ($rep -and $rep.LastConnectErrorText) { "$($rep.LastConnectError): $($rep.LastConnectErrorText)" })
            $epRows = @(& $live $R (($endpointSql | Select-Object -Skip 1) -join "`n"))
            $ep = if ($epRows.Count) { $epRows[0] } else { $null }
            $epName = if ($ep) { [string]$ep.name } else { 'Hadr_endpoint' }
            if ($ep) {
                & $addEv 'Endpoint' ('{0} is {1} on port {2}' -f $ep.name, $ep.state_desc, $ep.port)
                if ($ep.expiry_date -and -not ($ep.expiry_date -is [DBNull])) {
                    $days = [int]([datetime]$ep.expiry_date - [datetime]::UtcNow).TotalDays
                    & $addEv 'Certificate' ('{0} expires {1:yyyy-MM-dd} ({2})' -f $ep.certificate, [datetime]$ep.expiry_date, $(if ($days -lt 0) { 'EXPIRED' } else { "in $days days" }))
                }
            } else { & $addEv 'Endpoint' "Could not read it on $R (unreachable from the collector)." }
            & $add 'Diagnose' 'Connection state and the last connection error of every replica' $P $null $replicaSql
            & $add 'Diagnose' "The HADR endpoint and its certificate on $R" $R $null $endpointSql
            & $add 'Fix' "Start the HADR endpoint on $R" $R $(if ($ep -and $ep.state_desc -eq 'STARTED') { 'The endpoint is already STARTED: the cause is elsewhere (certificate, port 5022, firewall, DNS).' }) (
                @(& $guard $R @("SELECT 1 FROM sys.database_mirroring_endpoints WHERE name = $(& $lit $epName) AND state_desc <> 'STARTED'") "The endpoint $epName on $R is already STARTED: nothing to do.") +
                @("ALTER ENDPOINT $(& $q $epName) STATE = STARTED;"))
            & $add 'Verify' "$R is CONNECTED again" $P $null $replicaSql
        }
        'ReplicaUnreachable' {
            & $addEv 'Collector error' $(if ($rep) { [string]$rep.LastConnectErrorText })
            & $addEv 'What it means' "The monitor cannot open a connection to ${R}: the instance is down, or the network or port is blocked."
            & $add 'Diagnose' "Can this machine reach $R's port?" 'the monitoring host (PowerShell)' $null @(
                "Test-NetConnection -ComputerName <$R host> -Port <SQL port>",
                '# Lab (Docker): is the container running?', 'docker ps --filter "name=agsql"')
            & $add 'Fix' "Start SQL Server on $R" "$R host (PowerShell)" 'Find out why it stopped first (its error log, Windows event log, or docker logs).' @(
                '# Windows service:', 'Start-Service -Name MSSQLSERVER        # or MSSQL$<instance>',
                '# Lab (Docker):', "docker start $R")
            & $add 'Verify' "$R answers again" $R $null @('SELECT @@SERVERNAME AS server_name, SYSUTCDATETIME() AS now_utc;')
        }
        'ReplicaNotHealthy' {
            & $addEv 'Databases on it' (($Context.Databases | Where-Object ReplicaServerName -eq $R |
                ForEach-Object { '{0} {1}' -f $_.DatabaseName, $(if ($_.IsSuspended) { 'suspended' } else { ([string]$_.SynchronizationState).ToLower() }) }) -join ', ')
            & $addEv 'What it means' "Health rolls up from $R's databases and its connection: the database alerts for $R say which one and why."
            & $add 'Diagnose' 'Connection state of every replica' $P $null $replicaSql
            & $add 'Diagnose' "What $R reports for each database" $R $null @(
                'SELECT DB_NAME(database_id) AS database_name, synchronization_state_desc, synchronization_health_desc, is_suspended, suspend_reason_desc',
                'FROM sys.dm_hadr_database_replica_states WHERE is_local = 1;')
        }
        { $_ -in 'LogSendQueueHigh', 'EstimatedDataLossHigh' } {
            if ($db) {
                $drain = if ($db.LogSendRateKbSec -gt 0) { 'about ' + (& $fmtSec ([double]$db.LogSendQueueKb / [double]$db.LogSendRateKbSec)) + ' to drain at that rate' } else { 'last reported rate 0' }
                & $addEv 'Send queue' ('{0}; last reported send rate {1}/s: {2}' -f (& $fmtKb $db.LogSendQueueKb), (& $fmtKb $db.LogSendRateKbSec), $drain)
            }
            & $addEv 'Observed movement' $observed
            & $addEv 'Data at risk (RPO)' (& $rpo $db)
            $tran = @(& $live $P (($tranSql | Select-Object -Skip 1) -join "`n"))
            if (-not $tran.Count) { & $addEv 'Largest open transaction' 'None open right now, or not readable from the primary.' }
            if ($tran.Count) { & $addEv 'Largest open transaction' ('session {0}, {1} from {2} ({3}): {4} MB of log since {5:HH:mm:ss}' -f
                         $tran[0].session_id, $tran[0].login_name, $tran[0].host_name, $tran[0].program_name, $tran[0].log_mb, $tran[0].transaction_begin_time) }
            $log = @(& $live $P (($logSql | Select-Object -Skip 2) -join "`n") $D)
            if ($log.Count) { & $addEv 'Primary log' (& $logLine $log[0] '') }
            else { & $addEv 'Primary log' (& $notAvailable 'the log space' $P) }
            & $add 'Diagnose' 'Queues and rates of every replica' $P $null $stateSql
            & $add 'Diagnose' 'Which transactions are generating the log' $P $null $tranSql
            & $add 'Diagnose' 'Primary log space' $P $null $logSql
            & $add 'Verify' "The send queue to $R is shrinking" $P $null $stateSql
        }
        { $_ -in 'RedoQueueHigh', 'EstimatedRecoveryHigh' } {
            if ($db) {
                $catch = if ($db.RedoRateKbSec -gt 0) { 'about ' + (& $fmtSec ([double]$db.RedoQueueKb / [double]$db.RedoRateKbSec)) + ' to catch up at that rate' } else { 'last reported rate 0' }
                & $addEv 'Redo queue' ('{0}; last reported redo rate {1}/s: {2}' -f (& $fmtKb $db.RedoQueueKb), (& $fmtKb $db.RedoRateKbSec), $catch)
                & $addEv 'Observed movement' $observed
                & $addEv 'Failover time (RTO)' (& $fmtSec $db.EstimatedRecoverySec)
            }
            $blk = @(& $live $R (($redoSql | Select-Object -Skip 1) -join "`n"))
            if ($blk.Count) {
                $b = $blk[0]
                & $addEv 'Redo blocked by' ('session {0}: {1} from {2} ({3}), waiting {4} s on {5}' -f $b.blocking_session_id, $b.login_name, $b.host_name, $b.program_name, $b.wait_s, $b.wait_type)
                & $addEv 'Blocking statement' ([string]$b.blocker_sql)
            } elseif ($Context.Servers[$R]) { & $addEv 'Redo blocked by' 'nothing right now: look at I/O and CPU on the secondary' }
            else { & $addEv 'Redo blocked by' (& $notAvailable 'the redo sessions' $R) }
            & $add 'Diagnose' "Is redo on $R blocked, and by whom?" $R $null $redoSql
            if ($blk.Count) {
                $spid = [int]$blk[0].blocking_session_id
                & $add 'Danger' "End the session that blocks redo on $R" $R 'Ends a user query on the readable secondary. Tell its owner; never automated.' (
                    @(& $guard $R @("SELECT 1 FROM sys.dm_exec_requests WHERE blocking_session_id = $spid AND command IN ('DB STARTUP', 'PARALLEL REDO TASK', 'PARALLEL REDO HELP TASK')") "Session $spid no longer blocks redo on ${R}: nothing to do.") +
                    @("KILL $spid;   -- $($blk[0].login_name) from $($blk[0].host_name)"))
            }
            & $add 'Verify' "Redo on $R is catching up" $P $null $stateSql
        }
        default { return 0 }
    }
    & $addEv 'Collected' ('{0:yyyy-MM-dd HH:mm:ss} UTC, when the alert opened' -f [datetime]::UtcNow)
    Save-AgHealthAlertPlan -Control $Control -AlertId ([long]$Alert.AlertId) -Evidence $ev.ToArray() -Steps $steps.ToArray()
    $steps.Count
}

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

    $servers = @{}
    foreach ($p in @($reached)) { if ($p.Name -and $p.Server) { $servers[$p.Name] = $p.Server } }

    # 5. Evidence and Diagnose / Fix / Verify scripts for every open AG health alert that has none yet.
    #    Built while the connections are open; a failure here never fails the snapshot.
    if ($status -eq 'Succeeded') {
        try {
            $needPlan = @(Invoke-DbaQuery @control -EnableException -Query @"
SELECT a.AlertId, r.RuleName, a.ReplicaServerName, a.DatabaseName
FROM aghealth.Alert a JOIN aghealth.AlertRule r ON r.RuleId = a.RuleId
WHERE a.State = 'Open' AND a.AgName = @ag AND a.ObjectName = N''
  AND r.RuleName IN ('DatabaseSuspended', 'SyncSecondaryNotSynced', 'AsyncSecondaryNotMoving', 'ReplicaDisconnected',
                     'ReplicaUnreachable', 'ReplicaNotHealthy', 'LogSendQueueHigh', 'EstimatedDataLossHigh',
                     'RedoQueueHigh', 'EstimatedRecoveryHigh')
  AND NOT EXISTS (SELECT 1 FROM aghealth.AlertScript s WHERE s.AlertId = a.AlertId);
"@ -SqlParameter @{ ag = $AgName })
            $context = @{ AgName = $AgName; Primary = $primaryName; Servers = $servers; Replicas = $replicas; Databases = $databases }
            foreach ($a in $needPlan) {
                try { $null = New-AgHealthAlertPlan -Alert $a -Context $context -Control $control }
                catch { Write-Warning "Scripts for alert $($a.AlertId) ($($a.RuleName)) not built: $($_.Exception.Message)" }
            }
        }
        catch { Write-Warning "Alert scripts not built: $($_.Exception.Message)" }
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
        # Open connections, reused by Invoke-AgGuardCollection (primary for the inventory, every replica for backups)
        PrimaryServer  = if ($status -eq 'Succeeded') { $pri.Server } else { $null }
        ReplicaServers = $servers
        # Every alert this snapshot touched: Opened | Escalated | Downgraded | Resolved | Ongoing
        Alerts         = $alerts
    }
}

function New-AgGuardRecoveryPlan {
    # Builds and stores the recovery plan of one open ObjectDropped or MassDataLoss alert:
    # the backups it needs (msdb on every reachable replica) and the scripts, step by step.
    # It runs no restore and changes nothing on the replicas: a person runs the scripts, in order.
    [CmdletBinding()]
    param($Alert, $Snapshot, [hashtable] $Control, [int] $HistoryDays = 14)

    $db      = [string]$Alert.DatabaseName
    $object  = [string]$Alert.ObjectName                               # schema.name
    $parts   = $object.Split('.', 2)
    $q       = { param([string] $n) '[' + $n.Replace(']', ']]') + ']' }
    $qdb     = & $q $db
    $qobj    = '{0}.{1}' -f (& $q $parts[0]), (& $q $parts[1])
    $isDrop  = $Alert.RuleName -eq 'ObjectDropped'
    $primary = [string]$Alert.Primary
    $rpEstimated = ($Alert.RecoveryPointUtc -is [DBNull]) -or ($null -eq $Alert.RecoveryPointUtc)
    $rpUtc   = if ($rpEstimated) { ([datetime]$Alert.DetectedAt).AddSeconds(-70) } else { [datetime]$Alert.RecoveryPointUtc }
    $join    = { param([string] $dir, [string] $file)
                 if (-not $dir) { return $file }
                 $sep = if ($dir.Contains('\')) { '\' } else { '/' }
                 if ($dir.EndsWith('/') -or $dir.EndsWith('\')) { "$dir$file" } else { "$dir$sep$file" } }
    $lit     = { param([string] $v) "N'" + $v.Replace("'", "''") + "'" }

    # Backups of this database, from every replica (one object per backup set, all its files)
    $rows = foreach ($name in @($Snapshot.ReplicaServers.Keys)) {
        try {
            Invoke-DbaQuery -SqlInstance $Snapshot.ReplicaServers[$name] -Database msdb -Query $script:GuardBackupQuery `
                            -SqlParameter @{ db = $db; days = $HistoryDays } -EnableException
        }
        catch { Write-Warning "Backup history on $name is not readable (run ops/Install-AgGuard.ps1): $($_.Exception.Message)" }
    }
    $sets = @($rows | Group-Object { "$($_.ServerName)|$($_.BackupSetId)" } | ForEach-Object {
        $f = $_.Group[0]
        [pscustomobject]@{
            Server = [string]$f.ServerName; SetId = [int]$f.BackupSetId; Type = [string]$f.BackupType
            FinishUtc = [datetime]$f.FinishUtc; FirstLsn = [decimal]$f.FirstLsn; LastLsn = [decimal]$f.LastLsn
            SetUuid = [string]$f.SetUuid; DiffBase = [string]$f.DiffBaseGuid; IsUrl = ([int]$f.DeviceType -eq 9)
            Files = @($_.Group | Sort-Object Family | ForEach-Object { [string]$_.Device }) }
    })

    # The chain: last full before the recovery point, its latest differential, then unbroken log backups
    $problem = $null; $needLogNow = $false
    $chain = [Collections.Generic.List[object]]::new()
    $full  = $sets | Where-Object { $_.Type -eq 'D' -and $_.FinishUtc -le $rpUtc } | Sort-Object FinishUtc -Descending | Select-Object -First 1
    if (-not $full) {
        $problem = "No full backup of $db finished before the recovery point ({0:yyyy-MM-dd HH:mm:ss} UTC) in the last $HistoryDays days on any reachable replica." -f $rpUtc
    }
    else {
        $chain.Add($full)
        $diff = $sets | Where-Object { $_.Type -eq 'I' -and $_.DiffBase -eq $full.SetUuid -and $_.FinishUtc -le $rpUtc } |
                Sort-Object FinishUtc -Descending | Select-Object -First 1
        if ($diff) { $chain.Add($diff) }
        $logs = @($sets | Where-Object Type -eq 'L' | Sort-Object FirstLsn)
        $from = $chain[$chain.Count - 1].LastLsn
        $next = $logs | Where-Object { $_.FirstLsn -le $from -and $_.LastLsn -gt $from } | Select-Object -First 1
        while ($next) {
            $chain.Add($next)
            if ($next.FinishUtc -ge $rpUtc) { break }
            $prev = $next
            $next = $logs | Where-Object { $_.FirstLsn -eq $prev.LastLsn } | Select-Object -First 1
        }
        $end = $chain[$chain.Count - 1]
        if ($end.Type -ne 'L' -or $end.FinishUtc -lt $rpUtc) {
            # Later log backups that do not connect mean a gap: a new log backup would not connect either
            if (@($logs | Where-Object { $_.FirstLsn -gt $end.LastLsn }).Count) {
                $problem = "The log backup chain of $db has a gap after {0:yyyy-MM-dd HH:mm} UTC (a log backup is missing from msdb on every reachable replica)." -f $end.FinishUtc
            }
            else { $needLogNow = $true }
        }
    }

    # Where things are, and the shape of the table
    $restoreOn = if ($Alert.RecoveryInstance -and -not ($Alert.RecoveryInstance -is [DBNull])) { [string]$Alert.RecoveryInstance }
                 elseif ($full) { $full.Server } else { $primary }
    $shape  = Invoke-DbaQuery -SqlInstance $Snapshot.PrimaryServer -Database $db -Query $script:GuardTableShapeQuery `
                              -SqlParameter @{ obj = $qobj } -As DataSet -EnableException
    $cols   = @($shape.Tables[0].Rows)
    $backupPath = [string]$shape.Tables[1].Rows[0].BackupPath
    $offset = [int]$shape.Tables[1].Rows[0].UtcOffsetMinutes            # log records carry the primary's local time
    $stopAt = $rpUtc.AddMinutes($offset).ToString('yyyy-MM-ddTHH:mm:ss')
    $standby  = '{0}_Recover_{1:yyyyMMdd_HHmm}' -f $db, $rpUtc
    $qstandby = & $q $standby
    $sameInstance = $restoreOn -eq $primary

    $steps = [Collections.Generic.List[object]]::new()
    # The business decision: recorded on the controller, before anything is copied back
    $decide = {
        $proc = '{0}.aghealth.usp_RecordDecision' -f (& $q ([string]$Control.Database))
        $id   = [long]$Alert.AlertId
        & $add 'Decide' 'Record the business decision: intended, or recover' ([string]$Control.SqlInstance) `
            'Ask the business owner. The alert closes on Intended; on Recover the copy back may go ahead.' @(
            "-- It WAS intended (a purge, an archive job): the alert closes now. Skip the copy back; drop the standby if you made one.",
            "EXEC $proc @AlertId = $id, @Decision = 'Intended',",
            "     @DecidedBy = N'<your name>', @ConfirmedWith = N'<business owner>', @Note = N'<why>';",
            '',
            '-- It was NOT intended and the data must come back: record the approval, then go on with the copy back.',
            "EXEC $proc @AlertId = $id, @Decision = 'Recover',",
            "     @DecidedBy = N'<your name>', @ConfirmedWith = N'<business owner>', @Note = N'<ticket or reference>';")
    }
    $add = { param($Stage, $Title, $RunOn, $Caution, [string[]] $Sql)
             $steps.Add([pscustomobject]@{ Step = $steps.Count + 1; Stage = $Stage; Title = $Title; RunOn = $RunOn
                                           Caution = $Caution; Sql = ($Sql -join "`n") }) }

    if ($problem) {
        & $add 'Stage' 'No restore is possible from the backups on record' $restoreOn $problem @(
            "-- $problem",
            "-- Check the backup jobs of $db on every replica, and msdb.dbo.backupset where backups run.")
    }
    else {
        $logFile = $null
        if ($needLogNow) {
            $logFile = & $join $backupPath ('{0}_log_{1:yyyyMMdd_HHmmss}.trn' -f $db, [datetime]::UtcNow)
            & $add 'Prepare' 'Back up the log, so the restore can stop just before the change' $primary $null @(
                '-- A normal log backup: the database stays online and the AG keeps running.',
                "-- The last backup on record ends before the recovery point; this one reaches past it.",
                "BACKUP LOG $qdb TO DISK = $(& $lit $logFile) WITH CHECKSUM, STATS = 10;")
        }

        # Stage: full (+ diff) + logs into the standby database, stopping one second before the change
        $files = @(Invoke-DbaQuery -SqlInstance $Snapshot.ReplicaServers[$full.Server] -Database msdb `
                                   -Query $script:GuardRestoreTargetQuery -SqlParameter @{ set = $full.SetId } -EnableException)
        $dataN = 0
        $moves = foreach ($f in $files) {
            if ($f.FileType -eq 'L') { $target = & $join $f.LogPath  ('{0}_{1}.ldf' -f $standby, $f.LogicalName) }
            else { $dataN++; $ext = if ($dataN -eq 1) { 'mdf' } else { 'ndf' }
                   $target = & $join $f.DataPath ('{0}_{1}.{2}' -f $standby, $f.LogicalName, $ext) }
            "     MOVE $(& $lit ([string]$f.LogicalName)) TO $(& $lit $target),"
        }
        $source = { param($set)
                    $kind = if ($set.IsUrl) { 'URL' } else { 'DISK' }
                    ($set.Files | ForEach-Object { "$kind = $(& $lit $_)" }) -join ', ' }
        $where = { param($set) if ($set.Server -ne $restoreOn) { "   -- this file is on $($set.Server): copy it where $restoreOn can read it" } else { '' } }
        $sql = [Collections.Generic.List[string]]::new()
        $sql.Add("-- Restores to a standby database: $standby. Production is not touched.")
        $sql.Add("-- Stops at $stopAt (server time of $primary) = {0:yyyy-MM-dd HH:mm:ss} UTC, one second before the change.$(if ($rpEstimated) { ' ESTIMATED: the exact time was not captured.' })" -f $rpUtc)
        $sql.Add("RESTORE DATABASE $qstandby FROM $(& $source $full)$(& $where $full)")
        $sql.Add('WITH')
        foreach ($m in $moves) { $sql.Add($m) }
        $sql.Add('     NORECOVERY, STATS = 10;')
        foreach ($set in $chain | Select-Object -Skip 1) {
            if ($set.Type -eq 'I') { $sql.Add("RESTORE DATABASE $qstandby FROM $(& $source $set) WITH NORECOVERY, STATS = 10;$(& $where $set)") }
            else { $sql.Add("RESTORE LOG $qstandby FROM $(& $source $set) WITH NORECOVERY, STOPAT = $(& $lit $stopAt);$(& $where $set)") }
        }
        if ($logFile) { $sql.Add("RESTORE LOG $qstandby FROM DISK = $(& $lit $logFile) WITH NORECOVERY, STOPAT = $(& $lit $stopAt);   -- the log backup from step 1") }
        $sql.Add("RESTORE DATABASE $qstandby WITH RECOVERY;")
        $stageNote = if ($sameInstance) { 'This instance also runs production: the restore adds disk and I/O load here. A separate restore server is better when you have one.' }
                     else { "Run on $restoreOn, not on production. It needs to read the backup files listed." }
        & $add 'Stage' "Restore to the standby database $standby" $restoreOn $stageNote $sql.ToArray()

        # Compare (read-only), the business decision, copy back (only on Recover), verify
        $target = '{0}.{1}' -f $qdb, $qobj
        $copy   = '{0}.{1}' -f $qstandby, $qobj
        $insCols = @($cols | Where-Object { -not $_.IsGenerated } | ForEach-Object { & $q ([string]$_.ColumnName) })
        $keyCols = @($cols | Where-Object { -not ($_.KeyOrdinal -is [DBNull]) -and $null -ne $_.KeyOrdinal } |
                     Sort-Object KeyOrdinal | ForEach-Object { & $q ([string]$_.ColumnName) })
        $hasIdentity = [bool](@($cols | Where-Object { $_.IsIdentity }).Count)

        if ($isDrop) {
            & $add 'Compare' 'Check what the standby holds (read-only)' $restoreOn $null @(
                "SELECT COUNT_BIG(*) AS StandbyRows FROM $copy;$(if ($Alert.RowsBefore -isnot [DBNull] -and $null -ne $Alert.RowsBefore) { "   -- production had $('{0:N0}' -f [long]$Alert.RowsBefore) rows at the last run before the drop" })",
                "SELECT TOP (10) * FROM $copy;")
            & $decide
            & $add 'CopyBack' "Bring $object back into production" $primary 'Only after step 4 recorded Recover. This writes to production.' @(
                '-- Brings the table back with its data. Indexes, constraints, triggers and permissions are not copied:',
                '-- script them from the standby copy (SSMS: Generate Scripts) or from source control, and apply them after.',
                $(if ($sameInstance) { "SELECT * INTO $target FROM $copy;" }
                  else { "-- The standby is on ${restoreOn}: copy the table through a linked server, or export it and import it here." }))
            & $add 'Verify' 'Prove production matches the standby, row for row (read-only)' $primary $null @(
                '-- Every column of every row, compared both ways. Expect 0 and 0, and equal row counts.',
                "SELECT (SELECT COUNT_BIG(*) FROM $copy) AS StandbyRows, (SELECT COUNT_BIG(*) FROM $target) AS ProductionRows,",
                "       (SELECT COUNT_BIG(*) FROM (SELECT * FROM $copy EXCEPT SELECT * FROM $target) d) AS OnlyInStandby,",
                "       (SELECT COUNT_BIG(*) FROM (SELECT * FROM $target EXCEPT SELECT * FROM $copy) d) AS OnlyInProduction;")
        }
        else {
            # Row fingerprints: SHA-256 over every column, NULLs marked, columns separated (key-level proof, not a checksum)
            $skip = @('geography', 'geometry', 'hierarchyid')
            $hashCols = @($cols | Where-Object { -not $_.IsGenerated -and [string]$_.TypeName -notin $skip })
            $skipped  = @($cols | Where-Object { -not $_.IsGenerated -and [string]$_.TypeName -in $skip } | ForEach-Object { [string]$_.ColumnName })
            $exprs = foreach ($c in $hashCols) {
                $n = & $q ([string]$c.ColumnName)
                $conv = switch -Regex ([string]$c.TypeName) {
                    '^(float|real)$'                                          { "CONVERT(nvarchar(max), $n, 3)"; break }
                    '^(binary|varbinary|timestamp|rowversion)$'               { "CONVERT(nvarchar(max), $n, 1)"; break }
                    '^image$'                                                 { "CONVERT(nvarchar(max), CONVERT(varbinary(max), $n), 1)"; break }
                    '^(datetime|smalldatetime|datetime2|datetimeoffset|date|time)$' { "CONVERT(nvarchar(max), $n, 126)"; break }
                    '^(money|smallmoney)$'                                    { "CONVERT(nvarchar(max), $n, 2)"; break }
                    default                                                   { "CONVERT(nvarchar(max), $n)" }
                }
                "ISNULL($conv, N'<NULL>')"
            }
            $rowHash = "HASHBYTES('SHA2_256', CONCAT($($exprs -join ', NCHAR(31), '), N''))"
            $hasKey  = [bool]$keyCols.Count
            $keyList = $keyCols -join ', '
            $on      = if ($hasKey) { ($keyCols | ForEach-Object { "p.$_ = s.$_" }) -join ' AND ' } else { 'p.RowHash = s.RowHash' }
            $orderS  = if ($hasKey) { ($keyCols | ForEach-Object { "s.$_" }) -join ', ' } else { 's.RowHash' }
            $orderP  = if ($hasKey) { ($keyCols | ForEach-Object { "p.$_" }) -join ', ' } else { 'p.RowHash' }
            $cols2   = if ($hasKey) { "$keyList, " } else { '' }
            $digest  = { param($alias, $order) "CONVERT(char(64), HASHBYTES('SHA2_256', STRING_AGG(CONVERT(varchar(max), CONVERT(char(64), $alias.RowHash, 2)), '') WITHIN GROUP (ORDER BY $order)), 2)" }
            $proof = { param([string] $expect)
                $lines = @(
                    '-- Read-only: row fingerprints go to temp tables; nothing is written to either database.',
                    '-- Row: SHA-256 of every column. Table: SHA-256 of the row fingerprints, in key order.',
                    "-- $expect")
                if ($skipped.Count) { $lines += "-- Not in the fingerprint (spatial or hierarchy types): $($skipped -join ', ')" }
                if (-not $hasKey)   { $lines += "-- $object has no primary key: rows are matched on their fingerprint." }
                $lines += @(
                    "DROP TABLE IF EXISTS #standby; DROP TABLE IF EXISTS #prod;",
                    "SELECT $cols2$rowHash AS RowHash INTO #standby FROM $copy;",
                    "SELECT $cols2$rowHash AS RowHash INTO #prod FROM $target;",
                    'SELECT (SELECT COUNT_BIG(*) FROM #standby) AS StandbyRows,',
                    '       (SELECT COUNT_BIG(*) FROM #prod)    AS ProductionRows,',
                    "       (SELECT COUNT_BIG(*) FROM #standby s WHERE NOT EXISTS (SELECT 1 FROM #prod p WHERE $on)) AS MissingInProduction,",
                    "       (SELECT COUNT_BIG(*) FROM #prod p WHERE NOT EXISTS (SELECT 1 FROM #standby s WHERE $on)) AS NewInProduction,",
                    $(if ($hasKey) { "       (SELECT COUNT_BIG(*) FROM #standby s JOIN #prod p ON $on WHERE p.RowHash <> s.RowHash) AS ChangedInProduction;" }
                      else { '       CAST(NULL AS bigint) AS ChangedInProduction;' }),
                    "SELECT N'Standby' AS Copy, $(& $digest 's' $orderS) AS TableSha256 FROM #standby s",
                    'UNION ALL',
                    "SELECT N'Production, same keys', $(& $digest 'p' $orderP) FROM #prod p WHERE EXISTS (SELECT 1 FROM #standby s WHERE $on);")
                $lines }

            if ($sameInstance) {
                & $add 'Compare' 'Compare the standby with production, key by key (read-only)' $restoreOn $null `
                    (& $proof 'Now: MissingInProduction = the rows lost. ChangedInProduction = rows edited since. The two digests differ.')
            }
            else {
                & $add 'Compare' 'Fingerprint the standby (read-only)' $restoreOn $null @(
                    "-- The standby is on ${restoreOn}, production on ${primary}: run the fingerprint on both and compare.",
                    "SELECT COUNT_BIG(*) AS Rows, $(& $digest 's' $orderS) AS TableSha256",
                    "FROM (SELECT $cols2$rowHash AS RowHash FROM $copy) s;")
            }
            & $decide

            $list = $insCols -join ', '
            $body = if ($hasKey) {
                @("INSERT $target ($list)",
                  "SELECT $(($insCols | ForEach-Object { "s.$_" }) -join ', ')",
                  "FROM $copy AS s",
                  "WHERE NOT EXISTS (SELECT 1 FROM $target AS p WHERE $on);")
            } else {
                @("INSERT $target ($list)", "SELECT $list FROM $copy", 'EXCEPT', "SELECT $list FROM $target;")
            }
            $copyBack = @('-- Puts back only the rows production no longer has, with their original keys. One transaction.',
                          '-- Rows that still exist in production are never overwritten.',
                          '-- Large tables: run it in batches of key ranges, to keep the log and the AG send queue small.',
                          'SET XACT_ABORT ON;', 'BEGIN TRAN;')
            if ($hasIdentity) { $copyBack += "SET IDENTITY_INSERT $target ON;" }
            $copyBack += $body
            if ($hasIdentity) { $copyBack += "SET IDENTITY_INSERT $target OFF;" }
            $copyBack += 'COMMIT;'
            if (-not $sameInstance) { $copyBack = @("-- The standby is on ${restoreOn}: run this through a linked server, or export the missing rows and import them here.") + $copyBack }
            & $add 'CopyBack' "Copy the missing rows back into $object" $primary 'Only after step 4 recorded Recover. This writes to production.' $copyBack

            if ($sameInstance) {
                & $add 'Verify' 'Prove the recovered rows match the standby (read-only)' $primary $null `
                    (& $proof 'Expect: MissingInProduction 0, ChangedInProduction 0, and the two TableSha256 values identical.')
            }
            else {
                & $add 'Verify' 'Fingerprint production (read-only)' $primary $null @(
                    '-- Must equal the TableSha256 of the standby from the Compare step.',
                    "SELECT COUNT_BIG(*) AS Rows, $(& $digest 'p' $orderP) AS TableSha256",
                    "FROM (SELECT $cols2$rowHash AS RowHash FROM $target) p;")
            }
        }
        & $add 'CleanUp' 'Drop the standby database' $restoreOn 'Only once the business has signed off on the result.' @("DROP DATABASE $qstandby;")
    }
    if ($problem) { & $decide }

    # What the evidence says about the backups and the plan
    $logCount = @($chain | Where-Object Type -eq 'L').Count
    $backupText = if ($problem) { $problem } else {
        $diffText = if ($chain | Where-Object Type -eq 'I') { ' + 1 differential' } else { '' }
        $logText  = if ($needLogNow) { "$logCount log backup(s) on record + one more to take now (step 1)" } else { "$logCount log backup(s)" }
        'Full {0} on {1} ({2:yyyy-MM-dd HH:mm} UTC){3}, {4}' -f (Split-Path $full.Files[0] -Leaf), $full.Server, $full.FinishUtc, $diffText, $logText
    }
    $planText = if ($problem) { 'No restore possible: see Backups' } else {
        '{0} steps: restore to standby database {1} on {2}, stop at {3:HH:mm:ss} UTC{4}' -f $steps.Count, $standby, $restoreOn, $rpUtc, $(if ($rpEstimated) { ' (estimated)' })
    }

    $null = Invoke-DbaQuery @Control -EnableException -Query @"
SET XACT_ABORT ON;
BEGIN TRAN;
IF NOT EXISTS (SELECT 1 FROM aghealth.AlertScript WHERE AlertId = @a)
    INSERT aghealth.AlertScript (AlertId, Step, Stage, Title, RunOn, Caution, Sql)
    SELECT @a, j.Step, j.Stage, j.Title, j.RunOn, j.Caution, j.Sql
    FROM OPENJSON(@steps) WITH (Step int, Stage varchar(20), Title nvarchar(200), RunOn nvarchar(128),
                                Caution nvarchar(400), Sql nvarchar(max)) j;
INSERT aghealth.AlertEvidence (AlertId, SortOrder, Label, Value)
SELECT @a, v.SortOrder, v.Label, v.Value
FROM (VALUES (11, N'Backups', @backups), (12, N'Recovery plan', @plan)) v(SortOrder, Label, Value)
WHERE NOT EXISTS (SELECT 1 FROM aghealth.AlertEvidence e WHERE e.AlertId = @a AND e.SortOrder = v.SortOrder);
COMMIT;
"@ -SqlParameter @{ a = [long]$Alert.AlertId; steps = ConvertTo-Json -InputObject @($steps) -Depth 3 -Compress
                    backups = $backupText; plan = $planText }
    $steps.Count
}

function Invoke-AgGuardCollection {
    <#
    .SYNOPSIS
        Object Guard pass for one AG, after a health snapshot: dropped objects, unapproved DDL, mass data loss.
    .DESCRIPTION
        On the primary of the snapshot: inventories every AG database (objects and table row counts) and reads
        the new events of the AgGuard Extended Events session (who, from where, with which statement).
        aghealth.usp_GuardEvaluate compares that with the previous run, records findings, opens and resolves
        alerts and attaches the evidence. Read-only on the replicas. A database that cannot be read is skipped,
        never treated as empty. Returns what was found and every alert change.
    .EXAMPLE
        $s = Invoke-AgHealthCollection @collect
        Invoke-AgGuardCollection -Snapshot $s -ControlInstance localhost,14340 -ControlCredential $ctlCred
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Snapshot,            # from Invoke-AgHealthCollection
        [Parameter(Mandatory)] [string] $ControlInstance,
        [string] $ControlDatabase = 'AgSyncControl',
        [pscredential] $ControlCredential
    )
    if ($Snapshot.Status -ne 'Succeeded' -or -not $Snapshot.PrimaryServer) {
        throw "Object Guard needs a successful snapshot with a primary (snapshot $($Snapshot.SnapshotId) is $($Snapshot.Status))."
    }
    $control = @{ SqlInstance = $ControlInstance; Database = $ControlDatabase }
    if ($ControlCredential) { $control.SqlCredential = $ControlCredential }
    $server  = $Snapshot.PrimaryServer
    $primary = $Snapshot.PrimaryReplica
    $stamp   = { param($d) if ($null -eq $d -or $d -is [DBNull]) { $null } else { ([datetime]$d).ToString('yyyy-MM-ddTHH:mm:ss.fffffff') } }
    $warnings = [Collections.Generic.List[string]]::new()

    # 1. Inventory of every AG database, as seen on the primary
    $dbNames   = @($Snapshot.Databases | Where-Object { $_.IsPrimaryReplica } | ForEach-Object DatabaseName | Sort-Object -Unique)
    $readDbs   = [Collections.Generic.List[string]]::new()
    $inventory = [Collections.Generic.List[object]]::new()
    foreach ($db in $dbNames) {
        try {
            $rows = Invoke-DbaQuery -SqlInstance $server -Database $db -Query $script:GuardInventoryQuery -EnableException
            foreach ($r in $rows) {
                $inventory.Add([pscustomobject]@{
                    DatabaseName = $r.DatabaseName; SchemaName = $r.SchemaName; ObjectName = $r.ObjectName
                    ObjectType   = $r.ObjectType;   ObjectId   = [int]$r.ObjectId
                    CreateDate   = & $stamp $r.CreateDate; ModifyDate = & $stamp $r.ModifyDate
                    TableRows    = if ($r.TableRows -is [DBNull]) { $null } else { [long]$r.TableRows } })
            }
            $readDbs.Add($db)
        }
        catch { $warnings.Add("Could not inventory $db on ${primary}: $($_.Exception.Message)") }
    }

    # 2. New events from the AgGuard session on the primary, since this replica's bookmark
    $since = (Invoke-DbaQuery @control -EnableException -Query @"
SELECT CONVERT(varchar(33), COALESCE(
         (SELECT LastEventTime FROM aghealth.GuardBookmark WHERE AgName = @ag AND ReplicaServerName = @r),
         DATEADD(MINUTE, -ISNULL(TRY_CAST((SELECT Value FROM aghealth.GuardSetting WHERE Name = 'EvidenceWindowMinutes') AS int), 15),
                 SYSUTCDATETIME())), 126) AS Since;
"@ -SqlParameter @{ ag = $Snapshot.AgName; r = $primary }).Since
    $captures = @(); $sessionRunning = $false
    try {
        $ds = Invoke-DbaQuery -SqlInstance $server -Database master -Query $script:GuardEventsQuery `
                              -SqlParameter @{ since = $since } -As DataSet -EnableException
        $sessionRunning = [bool]$ds.Tables[0].Rows[0].SessionRunning
        if (-not $sessionRunning) { $warnings.Add("The AgGuard event session is not running on $primary (run ops/Install-AgGuard.ps1): who-did-it evidence is missing.") }
        if ($ds.Tables.Count -gt 1) {
            $captures = @(foreach ($e in $ds.Tables[1].Rows) {
                [pscustomobject]@{
                    ReplicaServerName = $e.ReplicaServerName; EventTime = & $stamp $e.EventTime; EventName = $e.EventName
                    DatabaseName = Get-AgHealthValue $e 'DatabaseName'; ObjectId = Get-AgHealthValue $e 'ObjectId'
                    ObjectName   = Get-AgHealthValue $e 'ObjectName';   ObjectType = Get-AgHealthValue $e 'ObjectType'
                    DdlPhase     = Get-AgHealthValue $e 'DdlPhase';     LoginName  = Get-AgHealthValue $e 'LoginName'
                    HostName     = Get-AgHealthValue $e 'HostName';     AppName    = Get-AgHealthValue $e 'AppName'
                    SessionId    = Get-AgHealthValue $e 'SessionId';    TransactionId = Get-AgHealthValue $e 'TransactionId'
                    RowCnt       = Get-AgHealthValue $e 'RowCnt';       DurationUs = Get-AgHealthValue $e 'DurationUs'
                    Statement    = Get-AgHealthValue $e 'Statement' }
            })
        }
    }
    catch { $warnings.Add("Could not read the AgGuard events on ${primary}: $($_.Exception.Message)") }

    # 3. Compare, record, alert (one transaction on the controller)
    $result = Invoke-DbaQuery @control -EnableException -As DataSet -Query @"
EXEC aghealth.usp_GuardEvaluate @AgName = @ag, @SnapshotId = @snap, @Replica = @r,
     @Databases = @dbs, @Inventory = @inv, @Captures = @cap;
"@ -SqlParameter @{
        ag   = $Snapshot.AgName; snap = $Snapshot.SnapshotId; r = $primary
        dbs  = ConvertTo-Json -InputObject @($readDbs)   -Compress
        inv  = ConvertTo-Json -InputObject @($inventory) -Depth 3 -Compress
        cap  = ConvertTo-Json -InputObject @($captures)  -Depth 3 -Compress
    }

    # 4. A recovery plan for every open drop or mass-loss alert that has none yet (scripts only, nothing runs)
    $plans = 0
    $needPlan = @(Invoke-DbaQuery @control -EnableException -Query @"
SELECT a.AlertId, r.RuleName, a.DatabaseName, a.ObjectName, oe.ReplicaServerName AS [Primary],
       oe.RecoveryPointUtc, oe.DetectedAt, oe.RowsBefore,
       NULLIF((SELECT Value FROM aghealth.GuardSetting WHERE Name = 'RecoveryInstance'), N'') AS RecoveryInstance
FROM aghealth.Alert a
JOIN aghealth.AlertRule r ON r.RuleId = a.RuleId
CROSS APPLY (SELECT TOP (1) o.ReplicaServerName, o.RecoveryPointUtc, o.DetectedAt, o.RowsBefore
             FROM aghealth.ObjectEvent o WHERE o.AlertId = a.AlertId ORDER BY o.ObjectEventId) oe
WHERE a.State = 'Open' AND a.AgName = @ag AND r.RuleName IN ('ObjectDropped', 'MassDataLoss')
  AND NOT EXISTS (SELECT 1 FROM aghealth.AlertScript s WHERE s.AlertId = a.AlertId);
"@ -SqlParameter @{ ag = $Snapshot.AgName })
    foreach ($a in $needPlan) {
        try { $null = New-AgGuardRecoveryPlan -Alert $a -Snapshot $Snapshot -Control $control -WarningVariable +planWarn -WarningAction SilentlyContinue; $plans++ }
        catch { $warnings.Add("Recovery plan for alert $($a.AlertId) not built: $($_.Exception.Message)") }
    }
    foreach ($w in @($planWarn)) { if ($w) { $warnings.Add([string]$w) } }

    foreach ($w in $warnings) { Write-Warning $w }
    [pscustomobject]@{
        PSTypeName     = 'AgHealth.Guard'
        SnapshotId     = $Snapshot.SnapshotId
        AgName         = $Snapshot.AgName
        Primary        = $primary
        Databases      = @($readDbs)
        Objects        = $inventory.Count
        Captured       = $captures.Count
        SessionRunning = $sessionRunning
        Findings       = @($result.Tables[0].Rows)       # Dropped | Created | Altered | Restored | DataLoss
        Alerts         = @($result.Tables[1].Rows)       # Opened | Escalated | Resolved | Ongoing
        RecoveryPlans  = $plans                          # plans built in this run
        Warnings       = @($warnings)
    }
}

function ConvertTo-AgDashboardRow {
    # DataRows as plain objects for JSON: DBNull -> null, dates -> ISO 8601 UTC, decimals -> numbers
    param($Table)
    if (-not $Table) { return @() }
    $names = @($Table.Columns | ForEach-Object ColumnName)
    @(foreach ($row in $Table.Rows) {
        $o = [ordered]@{}
        foreach ($n in $names) {
            $v = $row[$n]
            $o[$n] = if ($v -is [DBNull]) { $null }
                     elseif ($v -is [datetime]) { $v.ToString('yyyy-MM-ddTHH:mm:ss.fff') + 'Z' }
                     elseif ($v -is [decimal]) { [double]$v }
                     elseif ($v -is [guid]) { $v.ToString() }
                     else { $v }
        }
        [pscustomobject]$o
    })
}

function Export-AgDashboardData {
    <#
    .SYNOPSIS
        Writes the live dashboard's data file for every AG in the control database.
    .DESCRIPTION
        The dashboard (dashboard/index.html) is one page that reads data.js from its own folder and refreshes
        it every 15 seconds: no web server, no open port, nothing to install. The page is copied next to the
        data the first time, and again whenever the repo has a newer one.
        The file holds state only, never secrets: topology, queues, RPO/RTO and their trends, open alerts with
        evidence and recovery plans, recent resolutions, Object Guard events and replica drift.
    .EXAMPLE
        Export-AgDashboardData -ControlInstance localhost,14340 -ControlCredential $ctl -Brand $brand
        Start-Process "$env:LOCALAPPDATA\AlwaysOnCommandCenter\dashboard\index.html"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ControlInstance,
        [string] $ControlDatabase = 'AgSyncControl',
        [pscredential] $ControlCredential,
        [string] $OutputDirectory = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AlwaysOnCommandCenter\dashboard'),
        [object] $Brand = (Get-AgHealthDefaultBrand),
        [ValidateRange(10, 1440)] [int] $TrendMinutes = 60
    )
    $control = @{ SqlInstance = $ControlInstance; Database = $ControlDatabase }
    if ($ControlCredential) { $control.SqlCredential = $ControlCredential }
    if (-not $Brand) { $Brand = Get-AgHealthDefaultBrand }
    $ds = Invoke-DbaQuery @control -EnableException -As DataSet -Query $script:DashboardQuery -SqlParameter @{ trend = $TrendMinutes }
    # One slot per result set, by position. Assigned one by one, so an empty result set stays an empty
    # slot instead of disappearing (which would shift every later section into the wrong place).
    $t = [object[]]::new([Math]::Max(13, $ds.Tables.Count))
    for ($i = 0; $i -lt $t.Count; $i++) {
        $t[$i] = if ($i -lt $ds.Tables.Count) { @(ConvertTo-AgDashboardRow $ds.Tables[$i]) } else { @() }
    }
    $pick = { param([int] $i, [string] $ag) @($t[$i] | Where-Object { $_.AgName -eq $ag }) }

    $evidence = @{}; foreach ($e in $t[6]) { $k = [string]$e.AlertId; if (-not $evidence[$k]) { $evidence[$k] = [Collections.Generic.List[object]]::new() }; $evidence[$k].Add($e) }
    $scripts  = @{}; foreach ($e in $t[7]) { $k = [string]$e.AlertId; if (-not $scripts[$k])  { $scripts[$k]  = [Collections.Generic.List[object]]::new() }; $scripts[$k].Add($e) }

    $ags = foreach ($a in $t[0] | Sort-Object SortOrder, AgName) {
        $name   = $a.AgName
        $alerts = @(& $pick 5 $name | ForEach-Object {
            $k = [string]$_.AlertId
            $_ | Add-Member -NotePropertyName Title -NotePropertyValue (Get-AgHealthTitle $_.RuleName) -PassThru |
                 Add-Member -NotePropertyName Evidence -NotePropertyValue @($(if ($evidence[$k]) { $evidence[$k].ToArray() })) -PassThru |
                 Add-Member -NotePropertyName Plan -NotePropertyValue @($(if ($scripts[$k]) { $scripts[$k].ToArray() })) -PassThru
        })
        $drift = @(& $pick 10 $name)
        [pscustomobject]@{
            name        = $name
            displayName = if ($a.DisplayName) { $a.DisplayName } else { $name }
            environment = $a.Environment
            visible     = [bool]$a.IsVisible
            snapshot    = $a
            replicas    = @(& $pick 1 $name)
            databases   = @(& $pick 2 $name)
            trend       = @(& $pick 3 $name)
            strip       = @(& $pick 4 $name)
            alerts      = $alerts
            resolved    = @(& $pick 8 $name | ForEach-Object { $_ | Add-Member -NotePropertyName Title -NotePropertyValue (Get-AgHealthTitle $_.RuleName) -PassThru })
            guard       = [pscustomobject]@{ events = @(& $pick 9 $name); watched = @(& $pick 12 $name) | Select-Object -First 1 }
            drift       = [pscustomobject]@{
                run      = $drift | Select-Object -First 1 RunId, Mode, StartedAt
                findings = @($drift | Where-Object { $_.ObjectName } | Select-Object ObjectType, ObjectName, SourceReplica, TargetReplica, DriftType, Detail, Action)
                exceptions = @(& $pick 11 $name)
            }
        }
    }

    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $logo = $null
    if ($Brand.LogoPath -and (Test-Path $Brand.LogoPath)) {
        $logo = 'logo' + [IO.Path]::GetExtension($Brand.LogoPath)
        Copy-Item -Path $Brand.LogoPath -Destination (Join-Path $OutputDirectory $logo) -Force
    }
    $doc = [ordered]@{
        version     = 1
        generatedAt = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fff') + 'Z'
        source      = $Brand.SourceName
        brand       = [ordered]@{ name = $Brand.Name; product = $Brand.Product; tagline = $Brand.Tagline
                                  url = $Brand.Url; contact = $Brand.Contact; accent = $Brand.AccentColor; logo = $logo }
        trendMinutes = $TrendMinutes
        ags         = @($ags)
    }
    $json = ConvertTo-Json -InputObject $doc -Depth 12 -Compress
    # Written to a temp file, then swapped in, so the page never reads half a file
    $final = Join-Path $OutputDirectory 'data.js'
    $temp  = Join-Path $OutputDirectory 'data.js.tmp'
    [IO.File]::WriteAllText($temp, "window.AOCC_DATA = $json;", [Text.UTF8Encoding]::new($false))
    Move-Item -Path $temp -Destination $final -Force

    # The page itself, from the repo, when it is newer than the copy next to the data
    $page = Join-Path $PSScriptRoot '../dashboard/index.html'
    $dest = Join-Path $OutputDirectory 'index.html'
    if ((Test-Path $page) -and (-not (Test-Path $dest) -or (Get-Item $page).LastWriteTimeUtc -gt (Get-Item $dest).LastWriteTimeUtc)) {
        Copy-Item -Path $page -Destination $dest -Force
    }
    [pscustomobject]@{ PSTypeName = 'AgHealth.Dashboard'; Path = $dest; Data = $final; Ags = @($ags).Count
                       Bytes = (Get-Item $final).Length }
}

#endregion

#region Notifications ---------------------------------------------------------

function Get-AgHealthEventStyle {
    # Label, colour and Slack emoji for one event
    param($AlertEvent)
    $dot = [char]0x00B7
    switch ($true) {
        ($AlertEvent.Event -eq 'Resolved')        { return @{ Label = 'RESOLVED'; Color = '#039855'; Tint = '#ecfdf3'; Emoji = ':large_green_circle:' } }
        ($AlertEvent.Event -eq 'Reminder' -and $AlertEvent.Severity -eq 'Critical') {
                                                    return @{ Label = "REMINDER $dot CRITICAL"; Color = '#d92d20'; Tint = '#fef3f2'; Emoji = ':bell:' } }
        ($AlertEvent.Event -eq 'Reminder')        { return @{ Label = "REMINDER $dot WARNING";  Color = '#dc6803'; Tint = '#fffaeb'; Emoji = ':bell:' } }
        ($AlertEvent.Event -eq 'Escalated')       { return @{ Label = 'ESCALATED TO CRITICAL'; Color = '#d92d20'; Tint = '#fef3f2'; Emoji = ':red_circle:' } }
        ($AlertEvent.Severity -eq 'Critical')     { return @{ Label = 'CRITICAL'; Color = '#d92d20'; Tint = '#fef3f2'; Emoji = ':red_circle:' } }
        default                                   { return @{ Label = 'WARNING';  Color = '#dc6803'; Tint = '#fffaeb'; Emoji = ':large_orange_circle:' } }
    }
}

function Get-AgHealthText {
    # DBNull-safe string
    param($Value)
    if ($null -eq $Value -or $Value -is [DBNull]) { '' } else { [string]$Value }
}

function Get-AgHealthTitle {
    # 'AsyncSecondaryNotMoving' -> 'Async secondary not moving'; acronyms stay: 'UnapprovedDDL' -> 'Unapproved DDL'
    param([string] $RuleName)
    $words = $RuleName -creplace '(?<=[a-z])(?=[A-Z])', ' ' -split ' '
    (@($words[0]) + @($words | Select-Object -Skip 1 | ForEach-Object { if ($_ -cmatch '^[A-Z]{2,}$') { $_ } else { $_.ToLower() } })) -join ' '
}

function Format-AgHealthDuration {
    param([timespan] $Span)
    if ($Span.TotalSeconds -lt 0)  { $Span = [timespan]::Zero }
    if ($Span.TotalMinutes -lt 1)  { return '{0} s' -f [int]$Span.TotalSeconds }
    if ($Span.TotalHours   -lt 1)  { return '{0} min' -f [int][Math]::Floor($Span.TotalMinutes) }
    if ($Span.TotalDays    -lt 1)  { return '{0} h {1} min' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes }
    '{0} d {1} h' -f [int][Math]::Floor($Span.TotalDays), $Span.Hours
}

function Format-AgHealthValue {
    # A raw metric value as a person would say it: KB -> MB/GB, seconds -> duration, flags -> words
    param([string] $Metric, $Value)
    $v = Get-AgHealthText $Value
    if ($v -eq '') { return '-' }
    switch -Regex ($Metric) {
        '^IsSuspended$' { return $(if ($v -in '1', 'True') { 'Suspended' } else { 'Moving' }) }
        '^IsReachable$' { return $(if ($v -in '1', 'True') { 'Reachable' } else { 'Unreachable' }) }
        'Kb(Sec)?$' {
            $kb = [double]$v; $rate = $(if ($Metric -like '*Sec') { '/s' } else { '' })
            if ($kb -ge 1048576) { return ('{0:0.#} GB' -f ($kb / 1048576)) + $rate }
            if ($kb -ge 1024)    { return ('{0:0.#} MB' -f ($kb / 1024)) + $rate }
            return ('{0:0} KB' -f $kb) + $rate
        }
        'Pct$'  { return '{0:0.#}%' -f [double]$v }
        'Sec$'  { return Format-AgHealthDuration ([timespan]::FromSeconds([double]$v)) }
        'Ms$'   { return '{0:0} ms' -f [double]$v }
        default { return ($v -replace '_', ' ') }
    }
}

function Get-AgHealthExpected {
    # What "healthy" means for this rule, in words
    param($AlertEvent)
    if ((Get-AgHealthText $AlertEvent.Operator) -eq '<>') {
        return Format-AgHealthValue $AlertEvent.Metric $AlertEvent.ExpectedValue
    }
    'Under {0} (critical over {1})' -f (Format-AgHealthValue $AlertEvent.Metric $AlertEvent.WarnThreshold),
                                       (Format-AgHealthValue $AlertEvent.Metric $AlertEvent.CritThreshold)
}

function Get-AgHealthEventView {
    # Everything a message shows about one event, already formatted. Slack and email render the same view.
    param($AlertEvent, [datetime] $NowUtc = [datetime]::UtcNow)
    $style    = Get-AgHealthEventStyle $AlertEvent
    $first    = [datetime]$AlertEvent.FirstSeenAt
    $resolved = $AlertEvent.Event -eq 'Resolved'
    $ended    = if ($resolved -and -not ($AlertEvent.ResolvedAt -is [DBNull])) { [datetime]$AlertEvent.ResolvedAt } else { $NowUtc }
    [pscustomobject]@{
        Style    = $style
        Title    = Get-AgHealthTitle $AlertEvent.RuleName
        Rule     = Get-AgHealthText $AlertEvent.RuleName
        Event    = Get-AgHealthText $AlertEvent.Event
        Path     = @($AlertEvent.AgName, $AlertEvent.ReplicaServerName, $AlertEvent.DatabaseName, $AlertEvent.ObjectName |
                     ForEach-Object { Get-AgHealthText $_ } | Where-Object { $_ })
        Now      = Format-AgHealthValue $AlertEvent.Metric $AlertEvent.LastValue
        Expected = Get-AgHealthExpected $AlertEvent
        # Opened/escalated: how long it has been going on. Resolved: how long it lasted, and how bad it got.
        Timing   = if ($resolved) { 'Was {0} for {1}' -f (Get-AgHealthText $AlertEvent.Severity).ToLower(), (Format-AgHealthDuration ($ended - $first)) }
                   else           { '{0:HH:mm} UTC ({1} ago)' -f $first, (Format-AgHealthDuration ($NowUtc - $first)) }
        # What the Event field says: 'Opened', 'Escalated', 'Resolved' or 'Reminder 2 of 8'
        EventText = if ($AlertEvent.Event -eq 'Reminder') {
                        $n = Get-AgHealthText $AlertEvent.ReminderNumber; $m = Get-AgHealthText $AlertEvent.MaxReminders
                        if ($n -and $m) { "Reminder $n of $m" } else { 'Reminder' }
                    } else { Get-AgHealthText $AlertEvent.Event }
        IsReminder = $AlertEvent.Event -eq 'Reminder'
        Runbook  = if ($resolved) { '' } else { Get-AgHealthText $AlertEvent.Runbook }
        # Facts collected when the alert opened (who, when, from where, rows, recovery point)
        Evidence = if ($resolved -or -not $AlertEvent.PSObject.Properties['Evidence']) { @() } else { @($AlertEvent.Evidence) }
        # How it was resolved: measured, or decided by a person (and who in the business confirmed it)
        Resolution = if ($resolved -and $AlertEvent.PSObject.Properties['ResolutionNote']) {
                         $note = Get-AgHealthText $AlertEvent.ResolutionNote
                         $by   = Get-AgHealthText $AlertEvent.ResolvedBy
                         if ($note) { $note } elseif ($by -and $by -ne 'measured') { "Closed by $by" } else { '' }
                     } else { '' }
        # Scripts attached to the alert (recovery plan): shown, never run
        Plan     = if ($resolved -or -not $AlertEvent.PSObject.Properties['Plan']) { @() } else { @($AlertEvent.Plan) }
        AlertId  = $AlertEvent.AlertId
        Rank     = if ($resolved) { 3 } elseif ($AlertEvent.Severity -eq 'Critical') { 1 } else { 2 }
    }
}

function ConvertTo-AgHealthSlackMessage {
    # One Slack message per event: a card with a severity colour bar
    param($AlertEvent, $Brand = (Get-AgHealthDefaultBrand))
    if (-not $Brand) { $Brand = Get-AgHealthDefaultBrand }
    $v   = Get-AgHealthEventView $AlertEvent
    $dot = [char]0x00B7
    $where = ($v.Path | ForEach-Object { '`' + $_ + '`' }) -join ' / '
    $blocks = [Collections.Generic.List[object]]::new()
    $blocks.Add(@{ type = 'section'; text = @{ type = 'mrkdwn'
                   text = "$($v.Style.Emoji)  *$($v.Style.Label)*  $dot  *$($v.Title)*`n$where" } })
    $blocks.Add(@{ type = 'section'; fields = @(
                   @{ type = 'mrkdwn'; text = "*Now*`n$($v.Now)" }
                   @{ type = 'mrkdwn'; text = "*Expected*`n$($v.Expected)" }
                   @{ type = 'mrkdwn'; text = "*$(if ($v.Event -eq 'Resolved') { 'Duration' } else { 'Started' })*`n$($v.Timing)" }
                   @{ type = 'mrkdwn'; text = "*Event*`n$($v.EventText)" }) })
    if ($v.Resolution) {
        $blocks.Add(@{ type = 'section'; text = @{ type = 'mrkdwn'; text = "*Resolution*`n$($v.Resolution)" } })
    }
    if ($v.Evidence.Count) {
        $lines = foreach ($e in $v.Evidence) {
            $val = [string]$e.Value
            if ($e.Label -eq 'Statement') {
                if ($val.Length -gt 400) { $val = $val.Substring(0, 400) + ' ...' }
                $fence = '```'
                $safe  = $val.Replace($fence, "'''")
                '*{0}*{1}{2}{3}{2}' -f $e.Label, "`n", $fence, $safe
            }
            else { "*$($e.Label):* $val" }
        }
        $text = "*Evidence*`n" + ($lines -join "`n")
        if ($text.Length -gt 2900) { $text = $text.Substring(0, 2900) + ' ...' }
        $blocks.Add(@{ type = 'section'; text = @{ type = 'mrkdwn'; text = $text } })
    }
    if ($v.Runbook) {
        $blocks.Add(@{ type = 'section'; text = @{ type = 'mrkdwn'; text = "*What to check*`n$($v.Runbook)" } })
    }
    if ($v.Plan.Count) {
        $lines = foreach ($st in $v.Plan) {
            $warn = if ($st.Caution -and $st.Stage -in 'CopyBack', 'Decide', 'Fix', 'Danger') { "  :warning: _$($st.Caution)_" } else { '' }
            "$($st.Step). *$($st.Stage)*  $($st.Title)  $dot  ``$($st.RunOn)``$warn"
        }
        $head = if (@($v.Plan | Where-Object { $_.Stage -in 'Stage', 'CopyBack' }).Count) { 'Recovery plan' } else { 'Diagnose and fix' }
        $text = "*$head*  (scripts ready, nothing has been run)`n" + ($lines -join "`n") +
                "`n_Full scripts are in the email digest and on the dashboard._"
        if ($text.Length -gt 2900) { $text = $text.Substring(0, 2900) + ' ...' }
        $blocks.Add(@{ type = 'section'; text = @{ type = 'mrkdwn'; text = $text } })
    }
    $blocks.Add(@{ type = 'context'; elements = @(@{ type = 'mrkdwn'
                   text = ((@($Brand.Name, $Brand.Product) | Where-Object { $_ }) -join "  $dot  ") +
                          "  $dot  Alert #$($v.AlertId)  $dot  rule ``$($v.Rule)``" }) })
    @{
        text        = "$($v.Style.Label): $($v.Title) on $($v.Path -join ' / ')$(if ($v.IsReminder) { " ($($v.EventText.ToLower()))" })"     # notification preview
        attachments = @(@{ color = $v.Style.Color; blocks = $blocks.ToArray() })
    } | ConvertTo-Json -Depth 10 -Compress
}

function ConvertTo-AgHealthEmail {
    # One branded HTML digest per run. Inline styles and tables only: what Gmail and Outlook render reliably.
    # Fluid width: it fills the reading pane on a desktop and narrows on a phone.
    param([object[]] $Events, $Brand = (Get-AgHealthDefaultBrand), [datetime] $NowUtc = [datetime]::UtcNow)
    if (-not $Brand) { $Brand = Get-AgHealthDefaultBrand }       # channels made before branding existed
    $enc   = { param($x) [Net.WebUtility]::HtmlEncode([string]$x) }
    $dot   = '&nbsp;&middot;&nbsp;'
    $views = @($Events | ForEach-Object { Get-AgHealthEventView $_ $NowUtc } | Sort-Object Rank, Title)
    $ags   = (@($Events | ForEach-Object { Get-AgHealthText $_.AgName }) | Sort-Object -Unique) -join ', '

    $crit = @($views | Where-Object Rank -eq 1).Count
    $warn = @($views | Where-Object Rank -eq 2).Count
    $res  = @($views | Where-Object Rank -eq 3).Count
    $parts = @()
    if ($crit) { $parts += "$crit Critical" }
    if ($warn) { $parts += "$warn Warning$(if ($warn -gt 1) { 's' })" }
    if ($res)  { $parts += "$res Resolved" }
    $summary = $parts -join ', '
    # Only reminders in this run: say so up front, so it reads as "still broken", not as a new incident
    if (-not @($views | Where-Object { -not $_.IsReminder }).Count) { $summary = "Still open: $summary" }
    $subject = "[AG $ags] $summary"

    $pill = {
        param($n, $label, $color, $tint)
        "<td style='padding:0 6px 0 0'><span style='display:inline-block;padding:4px 10px;border-radius:999px;background:$tint;color:$color;font-size:12px;font-weight:600'>$n $label</span></td>"
    }
    $pills = @()
    if ($crit) { $pills += & $pill $crit 'Critical' '#d92d20' '#fef3f2' }
    if ($warn) { $pills += & $pill $warn $(if ($warn -gt 1) { 'Warnings' } else { 'Warning' }) '#dc6803' '#fffaeb' }
    if ($res)  { $pills += & $pill $res 'Resolved' '#039855' '#ecfdf3' }

    $cards = foreach ($v in $views) {
        $evidence = if ($v.Evidence.Count) {
            $rows = foreach ($e in $v.Evidence) {
                $val = if ($e.Label -eq 'Statement') {
                    "<div style='font-family:Consolas,Menlo,monospace;font-size:12px;background:#f2f4f7;border-radius:4px;padding:6px 8px;white-space:pre-wrap;word-break:break-word'>$(& $enc $e.Value)</div>"
                } else { & $enc $e.Value }
                "<tr><td width='130' valign='top' style='padding:5px 12px 0 0;color:#667085;font-size:12px'>$(& $enc $e.Label)</td><td valign='top' style='padding:5px 0 0 0;color:#101828'>$val</td></tr>"
            }
@"
<tr><td colspan='3' style='padding:12px 0 0 0'><div style='border-top:1px solid #eaecf0;padding-top:8px'>
<b style='color:#101828;font-size:13px'>Evidence</b>
<table width='100%' cellpadding='0' cellspacing='0' style='font-size:13px'>$($rows -join '')</table></div></td></tr>
"@ } else { '' }
        $resolution = if ($v.Resolution) {
            "<tr><td colspan='3' style='padding:12px 0 0 0'><div style='background:#ecfdf3;border-radius:6px;padding:8px 12px;font-size:13px;color:#05603a'><b>Resolution</b>&nbsp; $(& $enc $v.Resolution)</div></td></tr>"
        } else { '' }
        $isRecovery = [bool](@($v.Plan | Where-Object { $_.Stage -in 'Stage', 'CopyBack' }).Count)
        $plan = if ($v.Plan.Count) {
            $stageColor = @{ Prepare = '#475467'; Stage = '#1570ef'; Compare = '#039855'; Decide = '#dc6803'; CopyBack = '#d92d20'
                             Diagnose = '#039855'; Fix = '#dc6803'; Danger = '#d92d20'
                             Verify = '#039855'; CleanUp = '#475467'; Close = '#475467' }
            $items = foreach ($st in $v.Plan) {
                $c = if ($stageColor.ContainsKey($st.Stage)) { $stageColor[$st.Stage] } else { '#475467' }
                $caution = if ($st.Caution) {
                    "<div style='margin-top:4px;font-size:12px;color:#b54708;background:#fffaeb;border-radius:4px;padding:4px 8px'>$(& $enc $st.Caution)</div>" } else { '' }
@"
<div style='margin-top:12px'>
  <span style='display:inline-block;padding:1px 7px;border-radius:4px;background:$c;color:#ffffff;font-size:11px;font-weight:700;letter-spacing:.3px'>$($st.Step) &middot; $(& $enc $st.Stage.ToUpper())</span>
  <b style='color:#101828;font-size:13px'>&nbsp;$(& $enc $st.Title)</b>
  <span style='color:#667085;font-size:12px'>&nbsp;&middot; run on <span style='font-family:Consolas,Menlo,monospace'>$(& $enc $st.RunOn)</span></span>
  $caution
  <pre style='margin:6px 0 0 0;font-family:Consolas,Menlo,monospace;font-size:12px;line-height:1.45;background:#0b1220;color:#e4e7ec;border-radius:6px;padding:10px 12px;white-space:pre-wrap;word-break:break-word'>$(& $enc $st.Sql)</pre>
</div>
"@
            }
@"
<tr><td colspan='3' style='padding:14px 0 0 0'><div style='border-top:1px solid #eaecf0;padding-top:10px'>
<b style='color:#101828;font-size:13px'>$(if ($isRecovery) { 'Recovery plan' } else { 'Diagnose and fix' })</b>
<span style='color:#667085;font-size:12px'>&nbsp;$(if ($isRecovery) { 'Scripts are ready; nothing has been run. Production is never restored over: the restore goes to a standby database.' } else { 'Scripts are ready, filled in for this AG, replica and database; nothing has been run. Diagnose steps only read.' })</span>
$($items -join '')
</div></td></tr>
"@ } else { '' }
        $runbook = if ($v.Runbook) {
@"
<tr><td colspan='3' style='padding:12px 0 0 0'><div style='background:#f9fafb;border-radius:6px;padding:10px 12px;font-size:13px;color:#344054'>
<b style='color:#101828'>$(if ($v.Plan.Count) { 'In short' } else { 'What to check' })</b><br>$(& $enc $v.Runbook)</div></td></tr>
"@ } else { '' }
@"
<tr><td style='padding:0 28px 14px 28px'>
<table width='100%' cellpadding='0' cellspacing='0' style='border:1px solid #eaecf0;border-left:4px solid $($v.Style.Color);border-radius:8px'>
<tr><td style='padding:16px 18px'>
  <span style='display:inline-block;padding:2px 8px;border-radius:4px;background:$($v.Style.Color);color:#ffffff;font-size:11px;font-weight:700;letter-spacing:.4px'>$(& $enc $v.Style.Label)</span>
  <div style='font-size:16px;font-weight:600;color:#101828;margin-top:8px'>$(& $enc $v.Title)</div>
  <div style='font-family:Consolas,Menlo,monospace;font-size:12px;color:#667085;margin-top:2px'>$(& $enc ($v.Path -join ' / '))$(if ($v.IsReminder) { " &middot; $(& $enc $v.EventText)" })</div>
  <table width='100%' cellpadding='0' cellspacing='0' style='margin-top:12px;font-size:13px'>
  <tr>
    <td width='33%' valign='top'><div style='color:#667085;font-size:11px;text-transform:uppercase;letter-spacing:.5px'>Now</div><div style='color:#101828;font-weight:600'>$(& $enc $v.Now)</div></td>
    <td width='34%' valign='top'><div style='color:#667085;font-size:11px;text-transform:uppercase;letter-spacing:.5px'>Expected</div><div style='color:#101828'>$(& $enc $v.Expected)</div></td>
    <td width='33%' valign='top'><div style='color:#667085;font-size:11px;text-transform:uppercase;letter-spacing:.5px'>$(if ($v.Rank -eq 3) { 'Duration' } else { 'Started' })</div><div style='color:#101828'>$(& $enc $v.Timing)</div></td>
  </tr>
  $resolution
  $evidence
  $runbook
  $plan
  </table>
</td></tr></table>
</td></tr>
"@
    }

    # Header: logo and company on the left, the AG and time on the right
    $logo = if ($Brand.LogoPath) { "<td valign='middle' style='padding-right:12px'><img src='cid:brandlogo' height='40' alt='' style='display:block;height:40px;border:0'></td>" } else { '' }
    $company = if ($Brand.Name) { "<div style='color:#ffffff;font-size:17px;font-weight:700;letter-spacing:.2px'>$(& $enc $Brand.Name)</div>" } else { '' }
    $product = "<div style='color:$($Brand.AccentColor);font-size:11px;font-weight:700;letter-spacing:1.5px;margin-top:2px'>$(& $enc $Brand.Product.ToUpper())</div>"

    # Footer: who sent it, how to reach them, and what generated it
    $line1 = (@(
        $(if ($Brand.Name)    { "<b style='color:#344054'>$(& $enc $Brand.Name)</b>" })
        $(if ($Brand.Tagline) { "&ldquo;$(& $enc $Brand.Tagline)&rdquo;" })) | Where-Object { $_ }) -join $dot
    $line2 = (@(
        $(if ($Brand.Url)     { "<a href='$(& $enc $Brand.Url)' style='color:#475467;text-decoration:none'>$(& $enc ($Brand.Url -replace '^https?://', ''))</a>" })
        $(if ($Brand.Contact) { "<a href='mailto:$(& $enc $Brand.Contact)' style='color:#475467;text-decoration:none'>$(& $enc $Brand.Contact)</a>" })) | Where-Object { $_ }) -join $dot
    $footer = (@($line1, $line2) | Where-Object { $_ } | ForEach-Object { "<div style='margin-bottom:4px'>$_</div>" }) -join ''

    $body = @"
<!DOCTYPE html><html><body style='margin:0;padding:0;background:#f2f4f7'>
<div style='display:none;max-height:0;overflow:hidden'>$(& $enc "$summary on $ags")</div>
<table width='100%' cellpadding='0' cellspacing='0' style='background:#f2f4f7'><tr><td align='center' style='padding:16px'>
<table width='100%' cellpadding='0' cellspacing='0' style='width:100%;background:#ffffff;border-radius:12px;overflow:hidden;font-family:Segoe UI,Helvetica,Arial,sans-serif'>
<tr><td style='background:#0b1220;padding:20px 28px'>
  <table width='100%' cellpadding='0' cellspacing='0'><tr>
    <td valign='middle'><table cellpadding='0' cellspacing='0'><tr>$logo<td valign='middle'>$company$product</td></tr></table></td>
    <td align='right' valign='middle' style='color:#98a2b3;font-size:12px;line-height:1.5'>
      <div style='color:#ffffff;font-family:Consolas,Menlo,monospace;font-size:13px'>$(& $enc $ags)</div>
      $(& $enc ('{0:ddd d MMM yyyy, HH:mm} UTC' -f $NowUtc))
    </td>
  </tr></table>
</td></tr>
<tr><td style='padding:22px 28px 6px 28px'>
  <div style='font-size:19px;font-weight:600;color:#101828'>$(& $enc $summary)</div>
  <div style='font-size:13px;color:#667085;margin-top:2px'>Availability Group health and Object Guard alerts for $(& $enc $ags)</div>
</td></tr>
<tr><td style='padding:12px 28px 16px 28px'><table cellpadding='0' cellspacing='0'><tr>$($pills -join '')</tr></table></td></tr>
$($cards -join "`n")
<tr><td style='padding:8px 28px 0 28px'><div style='border-top:1px solid #eaecf0'></div></td></tr>
<tr><td style='padding:14px 28px 24px 28px;color:#667085;font-size:12px;line-height:1.5'>
  $footer
  <div style='color:#98a2b3;font-size:11px;margin-top:8px'>Generated by $(& $enc $Brand.Product) on $(& $enc $(if ($Brand.SourceName) { $Brand.SourceName } else { [Environment]::MachineName })).
  An alert opens only after its rule breaches on consecutive snapshots, and resolves only when the replica is measured healthy again.</div>
</td></tr>
</table></td></tr></table></body></html>
"@
    @{ Subject = $subject; Body = $body }
}

function New-AgHealthBrand {
    <#
    .SYNOPSIS
        Company branding for notifications: who the alerts come from, and how they look.
    .EXAMPLE
        $brand = New-AgHealthBrand -Name 'SQL-IT-Tech Solutions' -Tagline 'Enterprise SQL Architecture. Simplified.' `
                                   -Url https://sql-it-techsolutions.com -Contact info@sql-it-techsolutions.com `
                                   -SourceName SQL-IT-TECHSOLUTIONS `
                                   -LogoPath C:\Labs\AgSync\brand\logo.png
    #>
    param([string] $Name,                                  # company name, shown above the product name
          [string] $Product = 'Always On Command Center',
          [string] $Tagline,
          [string] $Url,
          [string] $Contact,                               # support or on-call address shown in the footer
          [string] $LogoPath,                              # PNG or JPG, embedded in the email (not linked)
          [string] $SourceName,                            # shown as "Generated by ... on <SourceName>"; default: this computer's name
          [ValidatePattern('^#[0-9a-fA-F]{6}$')] [string] $AccentColor = '#7dd3fc')
    if ($LogoPath -and -not (Test-Path $LogoPath)) { throw "Logo not found: $LogoPath" }
    [pscustomobject]@{ PSTypeName = 'AgHealth.Brand'; Name = $Name; Product = $Product; Tagline = $Tagline
                       Url = $Url; Contact = $Contact; LogoPath = $LogoPath; AccentColor = $AccentColor
                       SourceName = if ($SourceName) { $SourceName } else { [Environment]::MachineName } }
}

function Get-AgHealthDefaultBrand { New-AgHealthBrand }

function New-AgHealthSlackChannel {
    <#
    .SYNOPSIS
        A Slack incoming-webhook channel: one message per alert event.
    .EXAMPLE
        New-AgHealthSlackChannel -WebhookCredential (Get-AgHealthSecret SlackWebhook)
    #>
    param([Parameter(Mandatory)] [pscredential] $WebhookCredential,    # the webhook URL is the password
          [string] $Name = 'Slack',
          [object] $Brand = (Get-AgHealthDefaultBrand))
    [pscustomobject]@{ PSTypeName = 'AgHealth.Channel'; Name = $Name; Kind = 'Slack'; Mode = 'PerEvent'
                       Webhook = $WebhookCredential.Password; Brand = $Brand }
}

function New-AgHealthEmailChannel {
    <#
    .SYNOPSIS
        An SMTP email channel: one digest per run. Defaults suit Gmail with an app password.
    .EXAMPLE
        # Gmail
        New-AgHealthEmailChannel -Credential (Get-AgHealthSecret Gmail) -To achungolm@gmail.com
    .EXAMPLE
        # Your own domain through an SMTP relay (Brevo): the login is the relay's, the sender is yours
        New-AgHealthEmailChannel -Credential (Get-AgHealthSecret Brevo) -SmtpServer smtp-relay.brevo.com `
            -From alerts@sql-it-techsolutions.com -ReplyTo achungolm@gmail.com -To achungolm@gmail.com
    #>
    param([Parameter(Mandatory)] [pscredential] $Credential,
          [Parameter(Mandatory)] [string[]] $To,
          [string] $From,                                   # defaults to the credential's user name
          [string] $FromName,                               # what the inbox shows; default: brand name, else product
          [string] $ReplyTo,                                # where a DBA's reply goes
          [string] $SmtpServer = 'smtp.gmail.com',
          [int]    $Port = 587,
          [string] $Name = 'Email',
          [object] $Brand = (Get-AgHealthDefaultBrand))
    [pscustomobject]@{ PSTypeName = 'AgHealth.Channel'; Name = $Name; Kind = 'Email'; Mode = 'Digest'
                       Credential = $Credential; To = $To; SmtpServer = $SmtpServer; Port = $Port
                       From = if ($From) { $From } else { $Credential.UserName }
                       FromName = if ($FromName) { $FromName } elseif ($Brand.Name) { $Brand.Name } else { $Brand.Product }
                       ReplyTo = $ReplyTo; Brand = $Brand }
}

function New-AgHealthTestChannel {
    <#
    .SYNOPSIS
        An in-memory channel for tests and previews: records what it was sent and how Slack and email
        would have rendered it, or fails on demand.
    #>
    param([string] $Name = 'Test', [ValidateSet('PerEvent', 'Digest')] [string] $Mode = 'PerEvent',
          [string] $FailWith, [object] $Brand = (Get-AgHealthDefaultBrand))
    [pscustomobject]@{ PSTypeName = 'AgHealth.Channel'; Name = $Name; Kind = 'Test'; Mode = $Mode; Brand = $Brand
                       FailWith = $FailWith; Sent = [Collections.Generic.List[object]]::new()
                       # What Slack and email would have received: { Slack = <json per event>; Email = @{Subject; Body} }
                       Rendered = [Collections.Generic.List[object]]::new() }
}

function Send-AgHealthChannelMessage {
    # Delivers one event (PerEvent) or a batch (Digest) on one channel. Throws on failure.
    param($Channel, [object[]] $Events)
    switch ($Channel.Kind) {
        'Slack' {
            $uri = [Net.NetworkCredential]::new('', $Channel.Webhook).Password
            $null = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' `
                                      -Body ([Text.Encoding]::UTF8.GetBytes((ConvertTo-AgHealthSlackMessage $Events[0] $Channel.Brand)))
        }
        'Email' {
            $mail   = ConvertTo-AgHealthEmail $Events $Channel.Brand
            $client = [Net.Mail.SmtpClient]::new($Channel.SmtpServer, $Channel.Port)
            $msg    = [Net.Mail.MailMessage]::new()
            $msg.From    = [Net.Mail.MailAddress]::new($Channel.From, $Channel.FromName)
            foreach ($t in $Channel.To) { $msg.To.Add($t) }
            if ($Channel.ReplyTo) { $msg.ReplyToList.Add($Channel.ReplyTo) }
            $msg.Subject = $mail.Subject
            if ($Channel.Brand.LogoPath) {
                # The logo travels inside the email (cid:), so it shows without "load images" and offline
                $view = [Net.Mail.AlternateView]::CreateAlternateViewFromString($mail.Body, [Text.Encoding]::UTF8, 'text/html')
                $mime = if ($Channel.Brand.LogoPath -match '\.jpe?g$') { 'image/jpeg' } else { 'image/png' }
                $logo = [Net.Mail.LinkedResource]::new($Channel.Brand.LogoPath, $mime)
                $logo.ContentId = 'brandlogo'
                $view.LinkedResources.Add($logo)
                $msg.AlternateViews.Add($view)
            }
            else { $msg.Body = $mail.Body }
            try {
                $client.EnableSsl      = $true
                $client.Credentials    = $Channel.Credential.GetNetworkCredential()
                $msg.IsBodyHtml        = $true
                $msg.SubjectEncoding   = [Text.Encoding]::UTF8
                $msg.BodyEncoding      = [Text.Encoding]::UTF8
                $client.Send($msg)
            }
            finally { $msg.Dispose(); $client.Dispose() }
        }
        'Test' {
            if ($Channel.FailWith) { throw $Channel.FailWith }
            $Channel.Rendered.Add([pscustomobject]@{
                Slack = @($Events | ForEach-Object { ConvertTo-AgHealthSlackMessage $_ $Channel.Brand })
                Email = ConvertTo-AgHealthEmail $Events $Channel.Brand })
            $Channel.Sent.Add($Events)
        }
        default { throw "Unknown channel kind '$($Channel.Kind)'." }
    }
}

function Send-AgHealthNotification {
    <#
    .SYNOPSIS
        Announces new, escalated and resolved alerts on every channel, exactly once per channel.
    .DESCRIPTION
        Reads aghealth.PendingNotification. For each channel, sends only the events that channel has not
        already delivered; logs every attempt; marks an event done once every channel has it.
        A failed channel is retried on the next run. Returns one row per event and channel.
    .EXAMPLE
        $slack = New-AgHealthSlackChannel -WebhookCredential (Get-AgHealthSecret SlackWebhook)
        $email = New-AgHealthEmailChannel -Credential (Get-AgHealthSecret Gmail) -To achungolm@gmail.com
        Send-AgHealthNotification -ControlInstance localhost,14340 -ControlCredential $ctlCred -Channel $slack, $email
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ControlInstance,
        [string] $ControlDatabase = 'AgSyncControl',
        [pscredential] $ControlCredential,
        [Parameter(Mandatory)] [object[]] $Channel,
        [string] $AgName                                     # optional: only this AG
    )
    $control = @{ SqlInstance = $ControlInstance; Database = $ControlDatabase }
    if ($ControlCredential) { $control.SqlCredential = $ControlCredential }

    if (@($Channel | Where-Object { $null -eq $_ -or $_.PSObject.TypeNames -notcontains 'AgHealth.Channel' }).Count) {
        throw 'Every -Channel must come from New-AgHealthSlackChannel, New-AgHealthEmailChannel or New-AgHealthTestChannel (one was empty or not a channel).'
    }
    $names = @($Channel.Name)
    if (($names | Sort-Object -Unique).Count -ne $names.Count) { throw 'Channel names must be unique.' }

    $query = 'SELECT * FROM aghealth.PendingNotification' + $(if ($AgName) { ' WHERE AgName = @ag' }) + ' ORDER BY AlertId;'
    $pending = @(Invoke-DbaQuery @control -EnableException -Query $query -SqlParameter @{ ag = "$AgName" })
    if (-not $pending.Count) { return }

    # What each channel has already delivered, so a retry never duplicates,
    # and which channels announced each alert as open (only those are owed its resolution)
    $ids      = ($pending.AlertId | ForEach-Object { [long]$_ }) -join ','

    # Evidence collected when each alert opened, shown in every channel
    $evidence = @{}
    foreach ($ev in Invoke-DbaQuery @control -EnableException -Query @"
SELECT AlertId, Label, Value FROM aghealth.AlertEvidence WHERE AlertId IN ($ids) ORDER BY AlertId, SortOrder;
"@) {
        $key = [long]$ev.AlertId
        if (-not $evidence.ContainsKey($key)) { $evidence[$key] = [Collections.Generic.List[object]]::new() }
        $evidence[$key].Add([pscustomobject]@{ Label = $ev.Label; Value = $ev.Value })
    }
    $plans = @{}
    foreach ($sc in Invoke-DbaQuery @control -EnableException -Query @"
SELECT AlertId, Step, Stage, Title, RunOn, Caution, Sql FROM aghealth.AlertScript WHERE AlertId IN ($ids) ORDER BY AlertId, Step;
"@) {
        $key = [long]$sc.AlertId
        if (-not $plans.ContainsKey($key)) { $plans[$key] = [Collections.Generic.List[object]]::new() }
        $plans[$key].Add([pscustomobject]@{ Step = [int]$sc.Step; Stage = [string]$sc.Stage; Title = [string]$sc.Title
                                           RunOn = [string]$sc.RunOn; Caution = Get-AgHealthText $sc.Caution; Sql = [string]$sc.Sql })
    }
    foreach ($p in $pending) {
        $list = $evidence[[long]$p.AlertId]
        Add-Member -InputObject $p -NotePropertyName Evidence -NotePropertyValue $(if ($list) { $list.ToArray() } else { @() }) -Force
        $steps = $plans[[long]$p.AlertId]
        Add-Member -InputObject $p -NotePropertyName Plan -NotePropertyValue $(if ($steps) { $steps.ToArray() } else { @() }) -Force
    }
    $done     = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $openSent = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in Invoke-DbaQuery @control -EnableException -Query @"
SELECT AlertId, Channel, EventKey FROM aghealth.Notification WHERE Status = 'Sent' AND AlertId IN ($ids);
"@) {
        $null = $done.Add("$($n.AlertId)|$($n.Channel)|$($n.EventKey)")
        if ($n.EventKey -like 'Open:*') { $null = $openSent.Add("$($n.AlertId)|$($n.Channel)") }
    }

    $record = {
        param($AlertEvent, $Ch, [string] $Status, [string] $ErrorText)
        $err = if ($ErrorText) { $ErrorText.Substring(0, [Math]::Min(1000, $ErrorText.Length)) } else { [DBNull]::Value }
        Invoke-DbaQuery @control -EnableException -Query 'EXEC aghealth.usp_RecordNotification @a, @c, @k, @s, @e;' `
                        -SqlParameter @{ a = $AlertEvent.AlertId; c = $Ch.Name; k = $AlertEvent.EventKey; s = $Status; e = $err }
        [pscustomobject]@{ PSTypeName = 'AgHealth.Notification'; AlertId = $AlertEvent.AlertId; RuleName = $AlertEvent.RuleName
                           Event = $AlertEvent.Event; Severity = $AlertEvent.Severity; Channel = $Ch.Name; Status = $Status
                           Error = $ErrorText }
    }

    foreach ($ch in $Channel) {
        $todo = @($pending | Where-Object {
            -not $done.Contains("$($_.AlertId)|$($ch.Name)|$($_.EventKey)") -and
            # A channel that never announced the alert gets neither its reminders nor its resolution
            (($_.EventKey -ne 'Resolved' -and $_.EventKey -notlike 'Reminder:*') -or
             $openSent.Contains("$($_.AlertId)|$($ch.Name)"))
        })
        if (-not $todo.Count) { continue }

        if ($ch.Mode -eq 'Digest') {
            $errorText = $null
            try { Send-AgHealthChannelMessage $ch $todo } catch { $errorText = $_.Exception.Message }
            foreach ($e in $todo) { & $record $e $ch $(if ($errorText) { 'Failed' } else { 'Sent' }) $errorText }
        }
        else {
            foreach ($e in $todo) {
                $errorText = $null
                try { Send-AgHealthChannelMessage $ch @($e) } catch { $errorText = $_.Exception.Message }
                & $record $e $ch $(if ($errorText) { 'Failed' } else { 'Sent' }) $errorText
            }
        }
    }

    # An event is done when every channel has delivered it (now or on an earlier run)
    $json = ConvertTo-Json -InputObject $names -Compress
    foreach ($e in $pending) {
        $null = Invoke-DbaQuery @control -EnableException -Query 'EXEC aghealth.usp_CompleteNotification @a, @k, @c;' `
                                -SqlParameter @{ a = $e.AlertId; k = $e.EventKey; c = $json }
    }
}

function Get-AgHealthSecretPath {
    param([string] $Name, [ValidateSet('User', 'Machine')] [string] $Scope = 'User')
    if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
        throw 'Saved secrets use Windows DPAPI. On other platforms, pass credentials directly.'
    }
    $root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AlwaysOnCommandCenter\secrets'
    if ($Scope -eq 'Machine') { Join-Path $root "machine\$Name.json" } else { Join-Path $root "$Name.xml" }
}

function Save-AgHealthSecret {
    <#
    .SYNOPSIS
        Stores a credential, encrypted with Windows DPAPI, outside the repo.
    .DESCRIPTION
        -Scope User (default): encrypted with your Windows sign-in. Strongest; readable only when you are
            signed in, or by a task that stores your Windows password.
        -Scope Machine: encrypted with this computer's key, and the file is restricted to your account.
            Readable by a background task that stores no password (Task Scheduler "S4U"). Trade-off:
            an administrator of this computer could also read it. Fine for a lab or a dedicated monitoring host.
    .EXAMPLE
        Save-AgHealthSecret -Name Gmail -Credential (Get-Credential achungolm@gmail.com)
    .EXAMPLE
        # Copy an existing secret to the machine store, for a no-password background task
        Save-AgHealthSecret -Name Gmail -Credential (Get-AgHealthSecret Gmail -Scope User) -Scope Machine
    #>
    param([Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9_-]+$')] [string] $Name,
          [Parameter(Mandatory)] [pscredential] $Credential,
          [ValidateSet('User', 'Machine')] [string] $Scope = 'User')
    $path = Get-AgHealthSecretPath $Name $Scope
    $null = New-Item -ItemType Directory -Path (Split-Path $path) -Force

    if ($Scope -eq 'User') {
        $Credential | Export-Clixml -Path $path -Force
    }
    else {
        Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
        $entropy = [Text.Encoding]::UTF8.GetBytes("AlwaysOnCommandCenter:$Name")
        $plain   = [Text.Encoding]::UTF8.GetBytes($Credential.GetNetworkCredential().Password)
        try   { $blob = [Security.Cryptography.ProtectedData]::Protect($plain, $entropy, 'LocalMachine') }
        finally { [Array]::Clear($plain, 0, $plain.Length) }
        $doc = [ordered]@{ v = 1; scope = 'Machine'; user = $Credential.UserName
                           secret = [Convert]::ToBase64String($blob) } | ConvertTo-Json

        # Lock the file down to this account BEFORE anything secret is written to it
        $null = New-Item -ItemType File -Path $path -Force
        $acl  = Get-Acl -Path $path
        $acl.SetAccessRuleProtection($true, $false)                       # no inherited permissions
        foreach ($rule in @($acl.Access)) { $null = $acl.RemoveAccessRule($rule) }
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($me, 'FullControl', 'Allow'))
        Set-Acl -Path $path -AclObject $acl
        Set-Content -Path $path -Value $doc -Encoding utf8
    }
    Write-Verbose "Saved $Name ($Scope scope) to $path."
}

function Get-AgHealthSecret {
    <#
    .SYNOPSIS
        Reads a saved credential. -Scope Any (default) prefers the machine store, then the user store.
    #>
    param([Parameter(Mandatory)] [string] $Name,
          [ValidateSet('Any', 'User', 'Machine')] [string] $Scope = 'Any')
    $machine = Get-AgHealthSecretPath $Name 'Machine'
    $user    = Get-AgHealthSecretPath $Name 'User'

    if ($Scope -in 'Any', 'Machine' -and (Test-Path $machine)) {
        Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
        $doc     = Get-Content -Path $machine -Raw | ConvertFrom-Json
        $entropy = [Text.Encoding]::UTF8.GetBytes("AlwaysOnCommandCenter:$Name")
        $plain   = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($doc.secret), $entropy, 'LocalMachine')
        try {
            $secure = ConvertTo-SecureString ([Text.Encoding]::UTF8.GetString($plain)) -AsPlainText -Force
            return [pscredential]::new($doc.user, $secure)
        }
        finally { [Array]::Clear($plain, 0, $plain.Length) }
    }
    if ($Scope -in 'Any', 'User' -and (Test-Path $user)) {
        return Import-Clixml -Path $user
    }
    throw "Secret '$Name' not found (scope $Scope). Save it first with Save-AgHealthSecret."
}

#endregion

Export-ModuleMember -Function Invoke-AgHealthCollection, Invoke-AgGuardCollection, Send-AgHealthNotification, Export-AgDashboardData, New-AgHealthBrand,
                              New-AgHealthSlackChannel, New-AgHealthEmailChannel, New-AgHealthTestChannel,
                              Save-AgHealthSecret, Get-AgHealthSecret
