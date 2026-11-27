-- AG Health schema: run on the controller instance (outside the AG), after ControlDb.sql. Safe to re-run.
-- The collector writes one Snapshot per AG per run, plus the replica and database state it saw.
-- Alert rules are data, not code: change a threshold with an UPDATE, no redeploy.
USE AgSyncControl;
GO
IF SCHEMA_ID('aghealth') IS NULL EXEC('CREATE SCHEMA aghealth');
GO

-- One row per collection of one AG
IF OBJECT_ID('aghealth.Snapshot') IS NULL
CREATE TABLE aghealth.Snapshot (
    SnapshotId     bigint IDENTITY CONSTRAINT PK_Snapshot PRIMARY KEY,
    AgName         sysname        NOT NULL,
    PrimaryReplica sysname        NULL,                 -- NULL when no replica reports PRIMARY
    CollectedAt    datetime2(3)   NOT NULL CONSTRAINT DF_Snapshot_CollectedAt DEFAULT SYSUTCDATETIME(),
    CollectorHost  nvarchar(128)  NULL,
    DurationMs     int            NULL,
    Status         varchar(20)    NOT NULL CONSTRAINT DF_Snapshot_Status DEFAULT 'Running', -- Running | Succeeded | Partial | Failed
    ErrorMessage   nvarchar(4000) NULL,
    CONSTRAINT CK_Snapshot_Status CHECK (Status IN ('Running','Succeeded','Partial','Failed')));

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Snapshot_Ag_CollectedAt')
CREATE INDEX IX_Snapshot_Ag_CollectedAt ON aghealth.Snapshot (AgName, CollectedAt DESC) INCLUDE (Status, PrimaryReplica);

-- One row per replica per snapshot (from the primary's view, plus the collector's own reachability test)
IF OBJECT_ID('aghealth.ReplicaState') IS NULL
CREATE TABLE aghealth.ReplicaState (
    SnapshotId            bigint        NOT NULL CONSTRAINT FK_ReplicaState_Snapshot REFERENCES aghealth.Snapshot(SnapshotId) ON DELETE CASCADE,
    ReplicaServerName     sysname       NOT NULL,
    Role                  varchar(20)   NULL,           -- PRIMARY | SECONDARY | RESOLVING
    AvailabilityMode      varchar(30)   NULL,           -- SYNCHRONOUS_COMMIT | ASYNCHRONOUS_COMMIT
    FailoverMode          varchar(20)   NULL,
    ConnectedState        varchar(20)   NULL,           -- CONNECTED | DISCONNECTED
    OperationalState      varchar(30)   NULL,
    SynchronizationHealth varchar(20)   NULL,           -- HEALTHY | PARTIALLY_HEALTHY | NOT_HEALTHY
    IsReachable           bit           NOT NULL,       -- could the collector open a connection to it
    LastConnectError      int           NULL,
    LastConnectErrorText  nvarchar(1024) NULL,
    CONSTRAINT PK_ReplicaState PRIMARY KEY (SnapshotId, ReplicaServerName));

-- One row per database per replica per snapshot
IF OBJECT_ID('aghealth.DatabaseState') IS NULL
CREATE TABLE aghealth.DatabaseState (
    SnapshotId             bigint        NOT NULL,
    ReplicaServerName      sysname       NOT NULL,
    DatabaseName           sysname       NOT NULL,
    IsPrimaryReplica       bit           NOT NULL,
    SynchronizationState   varchar(30)   NULL,          -- SYNCHRONIZED | SYNCHRONIZING | NOT SYNCHRONIZING | ...
    SynchronizationHealth  varchar(20)   NULL,
    IsSuspended            bit           NOT NULL CONSTRAINT DF_DatabaseState_IsSuspended DEFAULT 0,
    SuspendReason          varchar(40)   NULL,          -- e.g. SUSPEND_FROM_PARTNER
    LogSendQueueKb         bigint        NULL,
    LogSendRateKbSec       bigint        NULL,
    RedoQueueKb            bigint        NULL,
    RedoRateKbSec          bigint        NULL,
    LastHardenedLsn        numeric(25,0) NULL,
    LastCommitTime         datetime2(3)  NULL,
    EstimatedDataLossSec   int           NULL,          -- primary last commit minus this replica's last commit (RPO)
    EstimatedRecoverySec   int           NULL,          -- redo queue / redo rate (RTO)
    CONSTRAINT PK_DatabaseState PRIMARY KEY (SnapshotId, ReplicaServerName, DatabaseName),
    CONSTRAINT FK_DatabaseState_Replica FOREIGN KEY (SnapshotId, ReplicaServerName)
        REFERENCES aghealth.ReplicaState (SnapshotId, ReplicaServerName) ON DELETE CASCADE);

-- Alert rules.
--   Operator '>'  : numeric metric; Warning at WarnThreshold, Critical at CritThreshold.
--   Operator '<>' : state metric; fires with Severity when the value is not ExpectedValue.
--   AppliesTo     : lets "not SYNCHRONIZED" be critical on a sync secondary and normal on an async one.
--   ConsecutiveSnapshots : how many snapshots in a row must breach before the alert opens (no flapping).
IF OBJECT_ID('aghealth.AlertRule') IS NULL
CREATE TABLE aghealth.AlertRule (
    RuleId               int IDENTITY  CONSTRAINT PK_AlertRule PRIMARY KEY,
    RuleName             varchar(60)   NOT NULL CONSTRAINT UQ_AlertRule_Name UNIQUE,
    Scope                varchar(10)   NOT NULL,        -- Ag | Replica | Database
    Metric               sysname       NOT NULL,        -- a column of Snapshot, ReplicaState or DatabaseState
    Operator             varchar(2)    NOT NULL,
    WarnThreshold        decimal(19,2) NULL,
    CritThreshold        decimal(19,2) NULL,
    ExpectedValue        varchar(60)   NULL,
    Severity             varchar(10)   NULL,            -- for '<>' rules: Warning | Critical
    AppliesTo            varchar(12)   NOT NULL CONSTRAINT DF_AlertRule_AppliesTo DEFAULT 'All', -- All | Synchronous | Asynchronous
    ConsecutiveSnapshots tinyint       NOT NULL CONSTRAINT DF_AlertRule_Consecutive DEFAULT 1,
    IsEnabled            bit           NOT NULL CONSTRAINT DF_AlertRule_IsEnabled DEFAULT 1,
    Description          nvarchar(400) NULL,
    CONSTRAINT CK_AlertRule_Scope     CHECK (Scope IN ('Ag','Replica','Database')),
    CONSTRAINT CK_AlertRule_AppliesTo CHECK (AppliesTo IN ('All','Synchronous','Asynchronous')),
    CONSTRAINT CK_AlertRule_Shape CHECK (
        (Operator = '>'  AND WarnThreshold IS NOT NULL AND CritThreshold >= WarnThreshold AND ExpectedValue IS NULL)
     OR (Operator = '<>' AND ExpectedValue IS NOT NULL AND Severity IN ('Warning','Critical'))),
    CONSTRAINT CK_AlertRule_Consecutive CHECK (ConsecutiveSnapshots BETWEEN 1 AND 20));

-- Alerts. One open alert per rule and object at a time; it is updated while the breach lasts
-- and resolved when it clears. Replica and database are '' (not NULL) when they do not apply,
-- so the filtered unique index can enforce the "one open alert" rule.
IF OBJECT_ID('aghealth.Alert') IS NULL
CREATE TABLE aghealth.Alert (
    AlertId           bigint IDENTITY CONSTRAINT PK_Alert PRIMARY KEY,
    RuleId            int            NOT NULL CONSTRAINT FK_Alert_Rule REFERENCES aghealth.AlertRule(RuleId),
    AgName            sysname        NOT NULL,
    ReplicaServerName sysname        NOT NULL CONSTRAINT DF_Alert_Replica  DEFAULT '',
    DatabaseName      sysname        NOT NULL CONSTRAINT DF_Alert_Database DEFAULT '',
    Severity          varchar(10)    NOT NULL,          -- Warning | Critical (can escalate while open)
    State             varchar(10)    NOT NULL CONSTRAINT DF_Alert_State DEFAULT 'Open', -- Open | Resolved
    FirstSeenAt       datetime2(3)   NOT NULL,
    LastSeenAt        datetime2(3)   NOT NULL,
    ResolvedAt        datetime2(3)   NULL,
    OpenSnapshotId    bigint         NOT NULL,
    LastSnapshotId    bigint         NOT NULL,
    LastValue         varchar(60)    NULL,
    Message           nvarchar(1000) NOT NULL,
    NotifiedAt        datetime2(3)   NULL,              -- set by the notifier; NULL = not yet sent
    CONSTRAINT CK_Alert_Severity CHECK (Severity IN ('Warning','Critical')),
    CONSTRAINT CK_Alert_State    CHECK (State IN ('Open','Resolved')));

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_Alert_OneOpen')
CREATE UNIQUE INDEX UX_Alert_OneOpen ON aghealth.Alert (RuleId, AgName, ReplicaServerName, DatabaseName)
    WHERE State = 'Open';

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Alert_State_LastSeen')
CREATE INDEX IX_Alert_State_LastSeen ON aghealth.Alert (State, LastSeenAt DESC) INCLUDE (Severity, AgName);
GO

-- Resolution notices are tracked separately from the open/escalation notice
IF COL_LENGTH('aghealth.Alert', 'ResolvedNotifiedAt') IS NULL
    ALTER TABLE aghealth.Alert ADD ResolvedNotifiedAt datetime2(3) NULL;
GO

-- Notification log, one row per alert, channel and event. It is what makes delivery safe to retry:
-- if Slack succeeded and email failed, the next run retries email only, and Slack never gets a duplicate.
--   EventKey: Open:Warning | Open:Critical | Resolved
IF OBJECT_ID('aghealth.Notification') IS NULL
CREATE TABLE aghealth.Notification (
    NotificationId bigint IDENTITY CONSTRAINT PK_Notification PRIMARY KEY,
    AlertId        bigint         NOT NULL CONSTRAINT FK_Notification_Alert REFERENCES aghealth.Alert(AlertId) ON DELETE CASCADE,
    Channel        varchar(30)    NOT NULL,
    EventKey       varchar(20)    NOT NULL,
    Status         varchar(10)    NOT NULL,             -- Sent | Failed
    Attempts       int            NOT NULL CONSTRAINT DF_Notification_Attempts DEFAULT 1,
    FirstAttemptAt datetime2(3)   NOT NULL CONSTRAINT DF_Notification_First DEFAULT SYSUTCDATETIME(),
    LastAttemptAt  datetime2(3)   NOT NULL CONSTRAINT DF_Notification_Last  DEFAULT SYSUTCDATETIME(),
    LastError      nvarchar(1000) NULL,
    CONSTRAINT UQ_Notification UNIQUE (AlertId, Channel, EventKey),
    CONSTRAINT CK_Notification_Status CHECK (Status IN ('Sent','Failed')));
GO

-- Default rules. Inserted only if missing, so tuned thresholds survive a re-run.
INSERT aghealth.AlertRule (RuleName, Scope, Metric, Operator, WarnThreshold, CritThreshold, ExpectedValue, Severity, AppliesTo, ConsecutiveSnapshots, Description)
SELECT v.RuleName, v.Scope, v.Metric, v.Op, v.Warn, v.Crit, v.Expected, v.Sev, v.AppliesTo, v.Consec, v.Descr
FROM (VALUES
    ('CollectionFailed',          'Ag',       'Status',                '<>', NULL,    NULL,    'Succeeded',     'Critical', 'All',          2, N'The collector could not complete a snapshot of this AG'),
    ('ReplicaUnreachable',        'Replica',  'IsReachable',           '<>', NULL,    NULL,    '1',             'Critical', 'All',          2, N'The collector cannot connect to this replica'),
    ('ReplicaDisconnected',       'Replica',  'ConnectedState',        '<>', NULL,    NULL,    'CONNECTED',     'Critical', 'All',          2, N'The primary reports this replica as disconnected'),
    ('ReplicaNotHealthy',         'Replica',  'SynchronizationHealth', '<>', NULL,    NULL,    'HEALTHY',       'Warning',  'All',          2, N'Replica synchronization health is not HEALTHY'),
    ('DatabaseSuspended',         'Database', 'IsSuspended',           '<>', NULL,    NULL,    '0',             'Critical', 'All',          1, N'Data movement is suspended; the log on the primary will grow'),
    ('SyncSecondaryNotSynced',    'Database', 'SynchronizationState',  '<>', NULL,    NULL,    'SYNCHRONIZED',  'Critical', 'Synchronous',  2, N'A synchronous secondary is not SYNCHRONIZED; failover would lose data or be refused'),
    ('AsyncSecondaryNotMoving',   'Database', 'SynchronizationState',  '<>', NULL,    NULL,    'SYNCHRONIZING', 'Warning',  'Asynchronous', 2, N'An asynchronous secondary is not receiving log'),
    ('LogSendQueueHigh',          'Database', 'LogSendQueueKb',        '>',  102400,  1048576, NULL,            NULL,       'All',          3, N'Log not yet sent to the secondary (KB): exposure if the primary fails'),
    ('RedoQueueHigh',             'Database', 'RedoQueueKb',           '>',  512000,  2097152, NULL,            NULL,       'All',          3, N'Log received but not yet redone (KB): failover will take longer'),
    ('EstimatedDataLossHigh',     'Database', 'EstimatedDataLossSec',  '>',  60,      300,     NULL,            NULL,       'Asynchronous', 3, N'Seconds of committed work the secondary is behind (RPO)'),
    ('EstimatedRecoveryHigh',     'Database', 'EstimatedRecoverySec',  '>',  300,     900,     NULL,            NULL,       'All',          3, N'Seconds to redo the queue before the database can come online (RTO)')
) v(RuleName, Scope, Metric, Op, Warn, Crit, Expected, Sev, AppliesTo, Consec, Descr)
WHERE NOT EXISTS (SELECT 1 FROM aghealth.AlertRule r WHERE r.RuleName = v.RuleName);
GO

-- What to check: a short runbook hint per rule, shown in every notification. Data, like the thresholds.
IF COL_LENGTH('aghealth.AlertRule', 'Runbook') IS NULL
    ALTER TABLE aghealth.AlertRule ADD Runbook nvarchar(400) NULL;
GO
UPDATE r SET Runbook = v.Runbook
FROM aghealth.AlertRule r
JOIN (VALUES
    ('CollectionFailed',        N'Check that the collector can reach every replica and the controller. The reason is in aghealth.Snapshot.ErrorMessage.'),
    ('ReplicaUnreachable',      N'Confirm the SQL Server service is running on the replica and its port is reachable from the collector.'),
    ('ReplicaDisconnected',     N'Check the HADR endpoint is STARTED on both replicas (sys.database_mirroring_endpoints), the certificates are valid and port 5022 is open.'),
    ('ReplicaNotHealthy',       N'Health rolls up from the replica''s databases: start with the database alerts for this replica.'),
    ('DatabaseSuspended',       N'Read suspend_reason_desc in sys.dm_hadr_database_replica_states on the secondary, fix the cause, then run ALTER DATABASE ... SET HADR RESUME on the secondary.'),
    ('SyncSecondaryNotSynced',  N'A lossless failover to this replica is not possible right now. Check its send and redo queues and the network between replicas.'),
    ('AsyncSecondaryNotMoving', N'The DR copy is falling behind. Check the replica is connected and not suspended.'),
    ('LogSendQueueHigh',        N'Log is not leaving the primary fast enough: check network throughput to the secondary, and large transactions or index maintenance on the primary.'),
    ('RedoQueueHigh',           N'The secondary is not redoing fast enough: check its I/O and CPU, and read-only queries blocking the redo thread.'),
    ('EstimatedDataLossHigh',   N'This much committed work would be lost if the primary failed now. Check the send queue and the network to the DR replica.'),
    ('EstimatedRecoveryHigh',   N'A failover to this replica would take this long before its databases come online. Check the redo queue and the secondary''s I/O.')
) v(RuleName, Runbook) ON v.RuleName = r.RuleName
WHERE r.Runbook IS NULL;
GO

-- Retention. Deleting snapshots cascades to replica and database state.
-- Resolved alerts are kept longer than raw state, because they are the incident history.
CREATE OR ALTER PROCEDURE aghealth.usp_PurgeHistory
    @KeepSnapshotDays int = 14,
    @KeepAlertDays    int = 180,
    @BatchSize        int = 5000
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SnapCutoff  datetime2(3) = DATEADD(DAY, -@KeepSnapshotDays, SYSUTCDATETIME()),
            @AlertCutoff datetime2(3) = DATEADD(DAY, -@KeepAlertDays,    SYSUTCDATETIME()),
            @Rows int = 1;

    -- Never purge a snapshot that an open alert still points at
    WHILE @Rows > 0
    BEGIN
        DELETE TOP (@BatchSize) s
        FROM aghealth.Snapshot s
        WHERE s.CollectedAt < @SnapCutoff
          AND NOT EXISTS (SELECT 1 FROM aghealth.Alert a
                          WHERE a.State = 'Open'
                            AND s.SnapshotId IN (a.OpenSnapshotId, a.LastSnapshotId));
        SET @Rows = @@ROWCOUNT;
    END;

    DELETE aghealth.Alert WHERE State = 'Resolved' AND ResolvedAt < @AlertCutoff;
END;
GO

-- Alert evaluation for one snapshot. Called by the collector after every snapshot.
--   Opens   : the rule has breached for ConsecutiveSnapshots snapshots in a row (no flapping on one bad reading).
--   Updates : an open alert stays open while the breach lasts; Warning -> Critical escalates and re-notifies.
--   Resolves: only when the object was measured in this snapshot and is back within the rule.
--             An object missing from the snapshot (e.g. the collector could not see it) is never "resolved".
--   Disabled rules resolve their open alerts. AppliesTo mismatches (e.g. a replica switched to async) also resolve.
CREATE OR ALTER PROCEDURE aghealth.usp_EvaluateAlerts
    @SnapshotId bigint
AS
BEGIN
    SET NOCOUNT, XACT_ABORT ON;

    DECLARE @Ag sysname, @At datetime2(3);
    SELECT @Ag = AgName, @At = CollectedAt
    FROM aghealth.Snapshot WHERE SnapshotId = @SnapshotId AND Status <> 'Running';
    IF @Ag IS NULL THROW 50001, 'Snapshot not found, or still running.', 1;

    -- The last 20 snapshots of this AG, newest = Seq 1 (20 = the highest ConsecutiveSnapshots allowed)
    CREATE TABLE #Win (SnapshotId bigint PRIMARY KEY, Seq int NOT NULL);
    INSERT #Win (SnapshotId, Seq)
    SELECT TOP (20) SnapshotId, ROW_NUMBER() OVER (ORDER BY SnapshotId DESC)
    FROM aghealth.Snapshot
    WHERE AgName = @Ag AND SnapshotId <= @SnapshotId AND Status <> 'Running'
    ORDER BY SnapshotId DESC;

    -- Every metric of every object in the window, as text
    CREATE TABLE #M (Seq int, Scope varchar(10), ReplicaServerName sysname, DatabaseName sysname,
                     AvailabilityMode varchar(30) NULL, Metric sysname, Value varchar(60) NULL);

    INSERT #M
    SELECT w.Seq, 'Ag', '', '', NULL, v.Metric, v.Value
    FROM #Win w JOIN aghealth.Snapshot s ON s.SnapshotId = w.SnapshotId
    CROSS APPLY (VALUES ('Status',         CONVERT(varchar(60), s.Status)),
                        ('PrimaryReplica', CONVERT(varchar(60), s.PrimaryReplica)),
                        ('DurationMs',     CONVERT(varchar(60), s.DurationMs))) v(Metric, Value);

    INSERT #M
    SELECT w.Seq, 'Replica', r.ReplicaServerName, '', r.AvailabilityMode, v.Metric, v.Value
    FROM #Win w JOIN aghealth.ReplicaState r ON r.SnapshotId = w.SnapshotId
    CROSS APPLY (VALUES ('Role',                  CONVERT(varchar(60), r.Role)),
                        ('ConnectedState',        CONVERT(varchar(60), r.ConnectedState)),
                        ('OperationalState',      CONVERT(varchar(60), r.OperationalState)),
                        ('SynchronizationHealth', CONVERT(varchar(60), r.SynchronizationHealth)),
                        ('IsReachable',           CONVERT(varchar(60), r.IsReachable)),
                        ('LastConnectError',      CONVERT(varchar(60), r.LastConnectError))) v(Metric, Value);

    INSERT #M
    SELECT w.Seq, 'Database', d.ReplicaServerName, d.DatabaseName, r.AvailabilityMode, v.Metric, v.Value
    FROM #Win w
    JOIN aghealth.DatabaseState d ON d.SnapshotId = w.SnapshotId
    JOIN aghealth.ReplicaState  r ON r.SnapshotId = d.SnapshotId AND r.ReplicaServerName = d.ReplicaServerName
    CROSS APPLY (VALUES ('SynchronizationState',  CONVERT(varchar(60), d.SynchronizationState)),
                        ('SynchronizationHealth', CONVERT(varchar(60), d.SynchronizationHealth)),
                        ('IsSuspended',           CONVERT(varchar(60), d.IsSuspended)),
                        ('SuspendReason',         CONVERT(varchar(60), d.SuspendReason)),
                        ('LogSendQueueKb',        CONVERT(varchar(60), d.LogSendQueueKb)),
                        ('LogSendRateKbSec',      CONVERT(varchar(60), d.LogSendRateKbSec)),
                        ('RedoQueueKb',           CONVERT(varchar(60), d.RedoQueueKb)),
                        ('RedoRateKbSec',         CONVERT(varchar(60), d.RedoRateKbSec)),
                        ('EstimatedDataLossSec',  CONVERT(varchar(60), d.EstimatedDataLossSec)),
                        ('EstimatedRecoverySec',  CONVERT(varchar(60), d.EstimatedRecoverySec))) v(Metric, Value);

    -- Rule applied to each measurement: Severity is NULL when within the rule (or not applicable)
    CREATE TABLE #B (RuleId int, ReplicaServerName sysname, DatabaseName sysname, Seq int,
                     Value varchar(60) NULL, Severity varchar(10) NULL);
    INSERT #B
    SELECT ru.RuleId, m.ReplicaServerName, m.DatabaseName, m.Seq, m.Value,
           CASE WHEN ru.IsEnabled = 0 OR m.Value IS NULL THEN NULL
                WHEN NOT (ru.AppliesTo = 'All'
                       OR (ru.AppliesTo = 'Synchronous'  AND m.AvailabilityMode = 'SYNCHRONOUS_COMMIT')
                       OR (ru.AppliesTo = 'Asynchronous' AND m.AvailabilityMode = 'ASYNCHRONOUS_COMMIT')) THEN NULL
                WHEN ru.Operator = '<>' THEN CASE WHEN m.Value <> ru.ExpectedValue THEN ru.Severity END
                WHEN ru.Operator = '>'  THEN
                     CASE WHEN TRY_CONVERT(decimal(19,2), m.Value) > ru.CritThreshold THEN 'Critical'
                          WHEN TRY_CONVERT(decimal(19,2), m.Value) > ru.WarnThreshold THEN 'Warning' END
           END
    FROM #M m
    JOIN aghealth.AlertRule ru ON ru.Scope = m.Scope AND ru.Metric = m.Metric;

    -- The current snapshot, with "has it breached N times in a row" and the alert text
    CREATE TABLE #Now (RuleId int, ReplicaServerName sysname, DatabaseName sysname, Value varchar(60) NULL,
                       Severity varchar(10) NULL, Qualifies bit, Message nvarchar(1000));
    INSERT #Now
    SELECT b.RuleId, b.ReplicaServerName, b.DatabaseName, b.Value, b.Severity,
           CASE WHEN b.Severity IS NOT NULL
                 AND (SELECT COUNT(*) FROM #B h
                      WHERE h.RuleId = b.RuleId AND h.ReplicaServerName = b.ReplicaServerName
                        AND h.DatabaseName = b.DatabaseName AND h.Severity IS NOT NULL
                        AND h.Seq <= ru.ConsecutiveSnapshots) = ru.ConsecutiveSnapshots
                THEN 1 ELSE 0 END,
           LEFT(CONCAT(ru.RuleName, N' on ', @Ag,
                       CASE WHEN b.ReplicaServerName <> '' THEN N'/' + b.ReplicaServerName END,
                       CASE WHEN b.DatabaseName      <> '' THEN N'/' + b.DatabaseName END,
                       N': ', ru.Metric, N' = ', b.Value,
                       CASE WHEN ru.Operator = '>'
                            THEN CONCAT(N' (warn > ', CONVERT(varchar(30), CONVERT(decimal(19,0), ru.WarnThreshold)),
                                        N', critical > ', CONVERT(varchar(30), CONVERT(decimal(19,0), ru.CritThreshold)), N')')
                            ELSE CONCAT(N' (expected ', ru.ExpectedValue, N')') END,
                       N'. ', ru.Description), 1000)
    FROM #B b JOIN aghealth.AlertRule ru ON ru.RuleId = b.RuleId
    WHERE b.Seq = 1;

    DECLARE @Changes TABLE (AlertId bigint, Change varchar(12));
    DECLARE @Lock nvarchar(255) = CONCAT(N'aghealth.EvaluateAlerts:', @Ag);

    BEGIN TRAN;
    -- One evaluator per AG at a time
    EXEC sp_getapplock @Resource = @Lock, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 30000;

    -- Still breaching: keep open, track severity
    UPDATE a
    SET LastSeenAt = @At, LastSnapshotId = @SnapshotId, LastValue = n.Value, Message = n.Message,
        NotifiedAt = CASE WHEN a.Severity = 'Warning' AND n.Severity = 'Critical' THEN NULL ELSE a.NotifiedAt END,
        Severity   = n.Severity
    OUTPUT inserted.AlertId,
           CASE WHEN deleted.Severity = 'Warning'  AND inserted.Severity = 'Critical' THEN 'Escalated'
                WHEN deleted.Severity = 'Critical' AND inserted.Severity = 'Warning'  THEN 'Downgraded'
                ELSE 'Ongoing' END
    INTO @Changes
    FROM aghealth.Alert a
    JOIN #Now n ON n.RuleId = a.RuleId AND n.ReplicaServerName = a.ReplicaServerName AND n.DatabaseName = a.DatabaseName
    WHERE a.State = 'Open' AND a.AgName = @Ag AND n.Severity IS NOT NULL;

    -- Measured now and within the rule: resolve
    UPDATE a
    SET State = 'Resolved', ResolvedAt = @At, LastSnapshotId = @SnapshotId, LastValue = n.Value
    OUTPUT inserted.AlertId, 'Resolved' INTO @Changes
    FROM aghealth.Alert a
    JOIN #Now n ON n.RuleId = a.RuleId AND n.ReplicaServerName = a.ReplicaServerName AND n.DatabaseName = a.DatabaseName
    WHERE a.State = 'Open' AND a.AgName = @Ag AND n.Severity IS NULL;

    -- Breached N snapshots in a row and nothing open yet: open
    INSERT aghealth.Alert (RuleId, AgName, ReplicaServerName, DatabaseName, Severity, FirstSeenAt, LastSeenAt,
                           OpenSnapshotId, LastSnapshotId, LastValue, Message)
    OUTPUT inserted.AlertId, 'Opened' INTO @Changes
    SELECT n.RuleId, @Ag, n.ReplicaServerName, n.DatabaseName, n.Severity, @At, @At,
           @SnapshotId, @SnapshotId, n.Value, n.Message
    FROM #Now n
    WHERE n.Qualifies = 1
      AND NOT EXISTS (SELECT 1 FROM aghealth.Alert a
                      WHERE a.State = 'Open' AND a.AgName = @Ag AND a.RuleId = n.RuleId
                        AND a.ReplicaServerName = n.ReplicaServerName AND a.DatabaseName = n.DatabaseName);
    COMMIT;

    -- What changed in this evaluation, worst first
    SELECT c.Change, a.AlertId, a.Severity, r.RuleName, a.ReplicaServerName, a.DatabaseName,
           a.LastValue, a.FirstSeenAt, a.ResolvedAt, a.Message
    FROM @Changes c
    JOIN aghealth.Alert a     ON a.AlertId = c.AlertId
    JOIN aghealth.AlertRule r ON r.RuleId  = a.RuleId
    ORDER BY CASE c.Change WHEN 'Opened' THEN 1 WHEN 'Escalated' THEN 2 WHEN 'Downgraded' THEN 3
                           WHEN 'Resolved' THEN 4 ELSE 5 END,
             CASE a.Severity WHEN 'Critical' THEN 1 ELSE 2 END, r.RuleName;
END;
GO

-- What still has to be announced:
--   an open alert whose current severity has not been announced on every channel (new, or escalated), and
--   a resolved alert that at least one channel announced as open, whose resolution is still owed.
-- An alert that opened and resolved before any channel announced it is never announced at all.
-- Escalated means a channel already announced a different severity of this alert; a retry is not an escalation.
CREATE OR ALTER VIEW aghealth.PendingNotification
AS
SELECT a.AlertId, a.AgName, a.ReplicaServerName, a.DatabaseName, a.Severity, a.State, r.RuleName,
       a.LastValue, a.Message, a.FirstSeenAt, a.LastSeenAt, a.ResolvedAt,
       r.Metric, r.Operator, r.ExpectedValue, r.WarnThreshold, r.CritThreshold, r.Description, r.Runbook,
       CASE WHEN a.State = 'Open' THEN 'Open:' + a.Severity ELSE 'Resolved' END AS EventKey,
       CASE WHEN a.State = 'Resolved' THEN 'Resolved'
            WHEN EXISTS (SELECT 1 FROM aghealth.Notification n
                         WHERE n.AlertId = a.AlertId AND n.Status = 'Sent'
                           AND n.EventKey LIKE 'Open:%' AND n.EventKey <> 'Open:' + a.Severity)
                 THEN 'Escalated'
            ELSE 'Opened' END AS Event
FROM aghealth.Alert a
JOIN aghealth.AlertRule r ON r.RuleId = a.RuleId
WHERE (a.State = 'Open' AND a.NotifiedAt IS NULL)
   OR (a.State = 'Resolved' AND a.ResolvedNotifiedAt IS NULL
       AND EXISTS (SELECT 1 FROM aghealth.Notification n
                   WHERE n.AlertId = a.AlertId AND n.Status = 'Sent' AND n.EventKey LIKE 'Open:%'));
GO

-- Records one delivery attempt (insert the first time, count retries after that)
CREATE OR ALTER PROCEDURE aghealth.usp_RecordNotification
    @AlertId  bigint,
    @Channel  varchar(30),
    @EventKey varchar(20),
    @Status   varchar(10),
    @Error    nvarchar(1000) = NULL
AS
BEGIN
    SET NOCOUNT, XACT_ABORT ON;
    BEGIN TRAN;
    UPDATE aghealth.Notification WITH (UPDLOCK, HOLDLOCK)
    SET Status = @Status, Attempts = Attempts + 1, LastAttemptAt = SYSUTCDATETIME(), LastError = @Error
    WHERE AlertId = @AlertId AND Channel = @Channel AND EventKey = @EventKey;
    IF @@ROWCOUNT = 0
        INSERT aghealth.Notification (AlertId, Channel, EventKey, Status, LastError)
        VALUES (@AlertId, @Channel, @EventKey, @Status, @Error);
    COMMIT;
END;
GO

-- Marks an event announced once every channel that owes it has it. Returns 1 if the alert is now fully announced.
-- A resolution is owed only by the channels that announced the alert as open.
CREATE OR ALTER PROCEDURE aghealth.usp_CompleteNotification
    @AlertId  bigint,
    @EventKey varchar(20),
    @Channels nvarchar(max)          -- JSON array of the channel names in use, e.g. ["Slack","Email"]
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @needed int =
        CASE WHEN @EventKey = 'Resolved'
             THEN (SELECT COUNT(DISTINCT n.Channel) FROM aghealth.Notification n
                   WHERE n.AlertId = @AlertId AND n.Status = 'Sent' AND n.EventKey LIKE 'Open:%'
                     AND n.Channel IN (SELECT value FROM OPENJSON(@Channels)))
             ELSE (SELECT COUNT(*) FROM OPENJSON(@Channels)) END;
    DECLARE @sent int = (SELECT COUNT(*) FROM aghealth.Notification n
                         WHERE n.AlertId = @AlertId AND n.EventKey = @EventKey AND n.Status = 'Sent'
                           AND n.Channel IN (SELECT value FROM OPENJSON(@Channels)));
    IF @sent < @needed BEGIN SELECT CAST(0 AS bit) AS Completed; RETURN; END;

    UPDATE aghealth.Alert
    SET NotifiedAt         = CASE WHEN @EventKey <> 'Resolved' THEN SYSUTCDATETIME() ELSE NotifiedAt END,
        ResolvedNotifiedAt = CASE WHEN @EventKey  = 'Resolved' THEN SYSUTCDATETIME() ELSE ResolvedNotifiedAt END
    WHERE AlertId = @AlertId;
    SELECT CAST(1 AS bit) AS Completed;
END;
GO

-- Roles: the collector writes, the dashboard reads. Nothing else gets access to this schema.
IF DATABASE_PRINCIPAL_ID('aghealth_writer') IS NULL CREATE ROLE aghealth_writer;
IF DATABASE_PRINCIPAL_ID('aghealth_reader') IS NULL CREATE ROLE aghealth_reader;
GRANT SELECT, INSERT, UPDATE ON SCHEMA::aghealth TO aghealth_writer;
GRANT EXECUTE ON aghealth.usp_PurgeHistory         TO aghealth_writer;
GRANT EXECUTE ON aghealth.usp_EvaluateAlerts       TO aghealth_writer;
GRANT EXECUTE ON aghealth.usp_RecordNotification   TO aghealth_writer;
GRANT EXECUTE ON aghealth.usp_CompleteNotification TO aghealth_writer;
GRANT SELECT ON SCHEMA::aghealth TO aghealth_reader;

-- The control account already used by AG Sync becomes the collector's writer
IF DATABASE_PRINCIPAL_ID('agsync_control') IS NOT NULL
   AND IS_ROLEMEMBER('aghealth_writer', 'agsync_control') = 0
    ALTER ROLE aghealth_writer ADD MEMBER agsync_control;
GO
