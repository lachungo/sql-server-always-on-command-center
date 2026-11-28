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

-- Object-level alerts (Object Guard): one open alert per object, e.g. 'dbo.TradeLedger'. '' for AG, replica
-- and database alerts. Resolution can be measured (the object is back) or acknowledged by a person.
IF COL_LENGTH('aghealth.Alert', 'ObjectName') IS NULL
    ALTER TABLE aghealth.Alert ADD ObjectName nvarchar(260) NOT NULL CONSTRAINT DF_Alert_Object DEFAULT N'';
IF COL_LENGTH('aghealth.Alert', 'ResolvedBy') IS NULL
    ALTER TABLE aghealth.Alert ADD ResolvedBy nvarchar(128) NULL;      -- 'measured' or the person who acknowledged it
IF COL_LENGTH('aghealth.Alert', 'ResolutionNote') IS NULL
    ALTER TABLE aghealth.Alert ADD ResolutionNote nvarchar(400) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes i
               JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
               WHERE i.object_id = OBJECT_ID('aghealth.Alert') AND i.name = 'UX_Alert_OneOpen'
                 AND COL_NAME(ic.object_id, ic.column_id) = 'ObjectName')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('aghealth.Alert') AND name = 'UX_Alert_OneOpen')
        DROP INDEX UX_Alert_OneOpen ON aghealth.Alert;
    CREATE UNIQUE INDEX UX_Alert_OneOpen ON aghealth.Alert (RuleId, AgName, ReplicaServerName, DatabaseName, ObjectName)
        WHERE State = 'Open';
END;
GO

-- Evidence: facts collected when the alert opened (who, when, from where, rows, recovery point),
-- so the person on call, or the AI agent, starts from answers instead of a to-do list.
IF OBJECT_ID('aghealth.AlertEvidence') IS NULL
CREATE TABLE aghealth.AlertEvidence (
    AlertId     bigint         NOT NULL CONSTRAINT FK_AlertEvidence_Alert REFERENCES aghealth.Alert(AlertId) ON DELETE CASCADE,
    SortOrder   int            NOT NULL,
    Label       nvarchar(60)   NOT NULL,
    Value       nvarchar(2000) NOT NULL,
    CollectedAt datetime2(3)   NOT NULL CONSTRAINT DF_AlertEvidence_At DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_AlertEvidence PRIMARY KEY (AlertId, SortOrder));
GO

-- Reminders: an alert that stays open is announced again, on a schedule, so silence never looks like health.
-- The schedule is data: a default per severity, optionally overridden per rule (RepeatMinutes 0 = never remind).
IF COL_LENGTH('aghealth.Alert', 'ReminderCount') IS NULL
    ALTER TABLE aghealth.Alert ADD ReminderCount int NOT NULL CONSTRAINT DF_Alert_ReminderCount DEFAULT 0;
IF COL_LENGTH('aghealth.Alert', 'LastRemindedAt') IS NULL
    ALTER TABLE aghealth.Alert ADD LastRemindedAt datetime2(3) NULL;
IF COL_LENGTH('aghealth.AlertRule', 'RepeatMinutes') IS NULL
    ALTER TABLE aghealth.AlertRule ADD RepeatMinutes int NULL;      -- NULL: use the severity's policy; 0: never
IF COL_LENGTH('aghealth.AlertRule', 'MaxRepeats') IS NULL
    ALTER TABLE aghealth.AlertRule ADD MaxRepeats int NULL;         -- NULL: use the severity's policy
GO
IF OBJECT_ID('aghealth.ReminderPolicy') IS NULL
CREATE TABLE aghealth.ReminderPolicy (
    Severity      varchar(10) NOT NULL CONSTRAINT PK_ReminderPolicy PRIMARY KEY,
    RepeatMinutes int         NOT NULL,     -- 0 = never remind
    MaxRepeats    int         NOT NULL,
    CONSTRAINT CK_ReminderPolicy_Severity CHECK (Severity IN ('Warning','Critical')),
    CONSTRAINT CK_ReminderPolicy_Values   CHECK (RepeatMinutes >= 0 AND MaxRepeats >= 0));
GO
INSERT aghealth.ReminderPolicy (Severity, RepeatMinutes, MaxRepeats)
SELECT v.Severity, v.RepeatMinutes, v.MaxRepeats
FROM (VALUES ('Critical', 30, 8), ('Warning', 240, 3)) v(Severity, RepeatMinutes, MaxRepeats)
WHERE NOT EXISTS (SELECT 1 FROM aghealth.ReminderPolicy p WHERE p.Severity = v.Severity);
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

    -- AG Sync history (auto-sync runs every minute): kept like snapshots
    IF OBJECT_ID('agsync.SyncRun') IS NOT NULL
    BEGIN
        DELETE f FROM agsync.DriftFinding f JOIN agsync.SyncRun r ON r.RunId = f.RunId WHERE r.StartedAt < @SnapCutoff;
        DELETE agsync.SyncRun WHERE StartedAt < @SnapCutoff AND RunId NOT IN (SELECT RunId FROM agsync.DriftFinding);
    END;

    -- Object Guard (sql/ObjectGuard.sql): raw events like snapshots, findings like alerts
    IF OBJECT_ID('aghealth.GuardCapture') IS NOT NULL
        DELETE aghealth.GuardCapture WHERE CapturedAt < @SnapCutoff;
    IF OBJECT_ID('aghealth.ObjectEvent') IS NOT NULL
        DELETE o FROM aghealth.ObjectEvent o
        WHERE o.DetectedAt < @AlertCutoff
          AND NOT EXISTS (SELECT 1 FROM aghealth.Alert a WHERE a.AlertId = o.AlertId AND a.State = 'Open');
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
        -- A new severity has its own reminder schedule
        ReminderCount  = CASE WHEN a.Severity <> n.Severity THEN 0    ELSE a.ReminderCount  END,
        LastRemindedAt = CASE WHEN a.Severity <> n.Severity THEN NULL ELSE a.LastRemindedAt END,
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
-- New, escalated and resolved alerts
SELECT a.AlertId, a.AgName, a.ReplicaServerName, a.DatabaseName, a.ObjectName, a.Severity, a.State, r.RuleName,
       a.LastValue, a.Message, a.FirstSeenAt, a.LastSeenAt, a.ResolvedAt,
       r.Metric, r.Operator, r.ExpectedValue, r.WarnThreshold, r.CritThreshold, r.Description, r.Runbook,
       a.ResolvedBy, a.ResolutionNote,
       CASE WHEN a.State = 'Open' THEN 'Open:' + a.Severity ELSE 'Resolved' END AS EventKey,
       CASE WHEN a.State = 'Resolved' THEN 'Resolved'
            WHEN EXISTS (SELECT 1 FROM aghealth.Notification n
                         WHERE n.AlertId = a.AlertId AND n.Status = 'Sent'
                           AND n.EventKey LIKE 'Open:%' AND n.EventKey <> 'Open:' + a.Severity)
                 THEN 'Escalated'
            ELSE 'Opened' END AS Event,
       CAST(NULL AS int) AS ReminderNumber, CAST(NULL AS int) AS MaxReminders
FROM aghealth.Alert a
JOIN aghealth.AlertRule r ON r.RuleId = a.RuleId
WHERE (a.State = 'Open' AND a.NotifiedAt IS NULL)
   OR (a.State = 'Resolved' AND a.ResolvedNotifiedAt IS NULL
       AND EXISTS (SELECT 1 FROM aghealth.Notification n
                   WHERE n.AlertId = a.AlertId AND n.Status = 'Sent' AND n.EventKey LIKE 'Open:%'))

UNION ALL

-- Reminders: still open, fully announced, and its next reminder is due
SELECT a.AlertId, a.AgName, a.ReplicaServerName, a.DatabaseName, a.ObjectName, a.Severity, a.State, r.RuleName,
       a.LastValue, a.Message, a.FirstSeenAt, a.LastSeenAt, a.ResolvedAt,
       r.Metric, r.Operator, r.ExpectedValue, r.WarnThreshold, r.CritThreshold, r.Description, r.Runbook,
       a.ResolvedBy, a.ResolutionNote,
       CONCAT('Reminder:', a.Severity, ':', a.ReminderCount + 1) AS EventKey,
       'Reminder' AS Event,
       a.ReminderCount + 1 AS ReminderNumber, pol.MaxRepeats AS MaxReminders
FROM aghealth.Alert a
JOIN aghealth.AlertRule r ON r.RuleId = a.RuleId
CROSS APPLY (SELECT COALESCE(r.RepeatMinutes, p.RepeatMinutes) AS RepeatMinutes,
                    COALESCE(r.MaxRepeats,    p.MaxRepeats)    AS MaxRepeats
             FROM aghealth.ReminderPolicy p WHERE p.Severity = a.Severity) pol
WHERE a.State = 'Open'
  AND a.NotifiedAt IS NOT NULL
  AND pol.RepeatMinutes > 0
  AND a.ReminderCount < pol.MaxRepeats
  AND DATEDIFF(SECOND, COALESCE(a.LastRemindedAt, a.NotifiedAt), SYSUTCDATETIME()) >= pol.RepeatMinutes * 60
  AND EXISTS (SELECT 1 FROM aghealth.Notification n
              WHERE n.AlertId = a.AlertId AND n.Status = 'Sent' AND n.EventKey LIKE 'Open:%');
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

-- Marks an event announced once every channel that owes it has it. Returns 1 if the event is now fully announced.
-- A resolution or a reminder is owed only by the channels that announced the alert as open.
CREATE OR ALTER PROCEDURE aghealth.usp_CompleteNotification
    @AlertId  bigint,
    @EventKey varchar(20),
    @Channels nvarchar(max)          -- JSON array of the channel names in use, e.g. ["Slack","Email"]
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @needed int =
        CASE WHEN @EventKey = 'Resolved' OR @EventKey LIKE 'Reminder:%'
             THEN (SELECT COUNT(DISTINCT n.Channel) FROM aghealth.Notification n
                   WHERE n.AlertId = @AlertId AND n.Status = 'Sent' AND n.EventKey LIKE 'Open:%'
                     AND n.Channel IN (SELECT value FROM OPENJSON(@Channels)))
             ELSE (SELECT COUNT(*) FROM OPENJSON(@Channels)) END;
    DECLARE @sent int = (SELECT COUNT(*) FROM aghealth.Notification n
                         WHERE n.AlertId = @AlertId AND n.EventKey = @EventKey AND n.Status = 'Sent'
                           AND n.Channel IN (SELECT value FROM OPENJSON(@Channels)));
    IF @sent < @needed BEGIN SELECT CAST(0 AS bit) AS Completed; RETURN; END;

    IF @EventKey LIKE 'Reminder:%'
    BEGIN
        -- 'Reminder:<Severity>:<n>': record reminder n as sent (idempotent)
        DECLARE @n int = TRY_CAST(RIGHT(@EventKey, CHARINDEX(':', REVERSE(@EventKey)) - 1) AS int);
        UPDATE aghealth.Alert
        SET ReminderCount = @n, LastRemindedAt = SYSUTCDATETIME()
        WHERE AlertId = @AlertId AND ReminderCount < @n;
    END
    ELSE
        UPDATE aghealth.Alert
        SET NotifiedAt         = CASE WHEN @EventKey <> 'Resolved' THEN SYSUTCDATETIME() ELSE NotifiedAt END,
            ResolvedNotifiedAt = CASE WHEN @EventKey  = 'Resolved' THEN SYSUTCDATETIME() ELSE ResolvedNotifiedAt END
        WHERE AlertId = @AlertId;
    SELECT CAST(1 AS bit) AS Completed;
END;
GO

-- Scripts attached to an alert when it opens: the recovery plan for a dropped object or lost rows, and later
-- the Diagnose / Fix / Verify steps of every rule. Each step says where it runs and what it changes.
--   Stage: Prepare | Stage | Compare | Decide | CopyBack | Verify | CleanUp
IF OBJECT_ID('aghealth.AlertScript') IS NULL
CREATE TABLE aghealth.AlertScript (
    AlertId   bigint         NOT NULL CONSTRAINT FK_AlertScript_Alert REFERENCES aghealth.Alert(AlertId) ON DELETE CASCADE,
    Step      int            NOT NULL,
    Stage     varchar(20)    NOT NULL,
    Title     nvarchar(200)  NOT NULL,
    RunOn     nvarchar(128)  NOT NULL,
    Caution   nvarchar(400)  NULL,          -- e.g. 'Only after the business confirms the rows must come back'
    Sql       nvarchar(max)  NOT NULL,
    CreatedAt datetime2(3)   NOT NULL CONSTRAINT DF_AlertScript_At DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_AlertScript PRIMARY KEY (AlertId, Step));
GO

-- The business decision on an object alert, recorded before anything is copied back:
--   Intended : the change was meant to happen (a purge, an archive job). The alert closes now.
--   Recover  : the data must come back. Approval is recorded on the alert; the copy back follows,
--              and the alert closes when the guard measures the rows (or the object) back.
IF OBJECT_ID('aghealth.AlertDecision') IS NULL
CREATE TABLE aghealth.AlertDecision (
    DecisionId    bigint IDENTITY CONSTRAINT PK_AlertDecision PRIMARY KEY,
    AlertId       bigint         NOT NULL CONSTRAINT FK_AlertDecision_Alert REFERENCES aghealth.Alert(AlertId) ON DELETE CASCADE,
    Decision      varchar(10)    NOT NULL,
    DecidedBy     nvarchar(128)  NOT NULL,      -- the DBA
    ConfirmedWith nvarchar(128)  NOT NULL,      -- the business owner who confirmed it
    Note          nvarchar(400)  NULL,
    DecidedAt     datetime2(3)   NOT NULL CONSTRAINT DF_AlertDecision_At DEFAULT SYSUTCDATETIME(),
    CONSTRAINT CK_AlertDecision CHECK (Decision IN ('Intended', 'Recover')));
GO

CREATE OR ALTER PROCEDURE aghealth.usp_RecordDecision
    @AlertId       bigint,
    @Decision      varchar(10),
    @DecidedBy     nvarchar(128),
    @ConfirmedWith nvarchar(128),
    @Note          nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT, XACT_ABORT ON;
    IF @Decision NOT IN ('Intended', 'Recover') THROW 50003, 'Decision must be Intended or Recover.', 1;
    IF NULLIF(LTRIM(@DecidedBy), N'') IS NULL OR NULLIF(LTRIM(@ConfirmedWith), N'') IS NULL
        THROW 50004, 'Say who decided and who in the business confirmed it.', 1;
    IF NOT EXISTS (SELECT 1 FROM aghealth.Alert WHERE AlertId = @AlertId AND State = 'Open')
        THROW 50002, 'No open alert with that AlertId.', 1;

    DECLARE @text nvarchar(400) = LEFT(CONCAT(
        CASE @Decision WHEN 'Intended' THEN N'Intended' ELSE N'Recover' END,
        N': confirmed by ', @DecidedBy, N' with ', @ConfirmedWith,
        CASE WHEN @Note IS NOT NULL THEN CONCAT(N' (', @Note, N')') END), 400);

    BEGIN TRAN;
    INSERT aghealth.AlertDecision (AlertId, Decision, DecidedBy, ConfirmedWith, Note)
    VALUES (@AlertId, @Decision, @DecidedBy, @ConfirmedWith, @Note);

    -- Shown with the alert from now on (evidence lines 13+ are decisions)
    INSERT aghealth.AlertEvidence (AlertId, SortOrder, Label, Value)
    SELECT @AlertId, 13 + COUNT(*), N'Decision', CONCAT(@text, N' at ', FORMAT(SYSUTCDATETIME(), 'yyyy-MM-dd HH:mm'), N' UTC')
    FROM aghealth.AlertEvidence WHERE AlertId = @AlertId AND SortOrder >= 13;

    IF @Decision = 'Intended'
        UPDATE aghealth.Alert
        SET State = 'Resolved', ResolvedAt = SYSUTCDATETIME(), ResolvedBy = @DecidedBy, ResolutionNote = @text
        WHERE AlertId = @AlertId AND State = 'Open';
    COMMIT;
    SELECT @AlertId AS AlertId, @Decision AS Decision, @text AS Recorded;
END;
GO

-- A person closes an alert that cannot be measured closed (e.g. an approved schema change, a planned purge).
-- AG health alerts reopen on the next snapshot if the problem is still there, so acknowledging never hides one.
CREATE OR ALTER PROCEDURE aghealth.usp_ResolveAlert
    @AlertId    bigint,
    @ResolvedBy nvarchar(128),
    @Note       nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE aghealth.Alert
    SET State = 'Resolved', ResolvedAt = SYSUTCDATETIME(), ResolvedBy = @ResolvedBy, ResolutionNote = @Note
    WHERE AlertId = @AlertId AND State = 'Open';
    IF @@ROWCOUNT = 0 THROW 50002, 'No open alert with that AlertId.', 1;
END;
GO

-- Replica drift as alerts, from the latest AG Sync run of each AG (agsync.DriftFinding):
--   MissingOnSecondary : a login or job on the primary is missing or different on a secondary, and was not
--                        fixed automatically (elevated, needs approval, or failed). Breaks apps after a failover.
--   OnlyOnSecondary    : a login or job currently exists on a secondary but not on the primary (e.g. added on a
--                        reporting replica, or dropped on the primary). Never copied or removed automatically: a
--                        person confirms who owns it, or records it as an approved exception (aghealth.DriftException).
-- Both resolve when the next AG Sync run no longer finds them.
INSERT aghealth.AlertRule (RuleName, Scope, Metric, Operator, ExpectedValue, Severity, AppliesTo, ConsecutiveSnapshots, Description, Runbook)
SELECT v.RuleName, 'Replica', 'DriftState', '<>', 'In sync', v.Sev, 'All', 1, v.Descr, v.Runbook
FROM (VALUES
    ('MissingOnSecondary', 'Warning', N'A login or Agent job on the primary is missing or different on this secondary: applications that need it break if this replica becomes PRIMARY',
     N'Fixed automatically when the policy allows. Otherwise Evidence says why it waits (an elevated login, a SID that differs): confirm with the owner, then run Invoke-AgSync -Mode Apply.'),
    ('OnlyOnSecondary',    'Warning', N'A login or Agent job currently exists on this secondary but not on the primary',
     N'Find out who owns it and why it is only here (reporting replicas attract these; it may also have been dropped on the primary). Keep it as an approved exception (aghealth.usp_ApproveDriftException), create it on the primary if every replica needs it, or remove it.')
) v(RuleName, Sev, Descr, Runbook)
WHERE NOT EXISTS (SELECT 1 FROM aghealth.AlertRule r WHERE r.RuleName = v.RuleName);

-- First wording claimed the object was "created here directly", which the history cannot prove
UPDATE aghealth.AlertRule
SET Description = N'A login or Agent job currently exists on this secondary but not on the primary',
    Runbook = N'Find out who owns it and why it is only here (reporting replicas attract these; it may also have been dropped on the primary). Keep it as an approved exception (aghealth.usp_ApproveDriftException), create it on the primary if every replica needs it, or remove it.'
WHERE RuleName = 'OnlyOnSecondary' AND Description LIKE N'%created here directly%';
UPDATE aghealth.AlertRule
SET Runbook = N'Fixed automatically when the policy allows. Otherwise Evidence says why it waits (an elevated login, an Agent job, a SID that differs): confirm with the owner, then approve that object with agsync.usp_ApproveSync; the next run applies it, and only it.'
WHERE RuleName = 'MissingOnSecondary' AND Runbook LIKE N'%then run Invoke-AgSync -Mode Apply.';
GO

-- Approved exceptions: an object that is meant to exist only on one secondary (e.g. a reporting login).
-- While approved and unexpired, its OnlyOnSecondary alert stays closed and the dashboard shows it as intentional.
-- It is tied to the primary at the time of approval: after a failover the roles have changed, so the exception
-- is put on hold and the alert comes back until someone re-approves it.
IF OBJECT_ID('aghealth.DriftException') IS NULL
CREATE TABLE aghealth.DriftException (
    ExceptionId       int IDENTITY CONSTRAINT PK_DriftException PRIMARY KEY,
    AgName            sysname        NOT NULL,
    ReplicaServerName sysname        NOT NULL,
    ObjectType        varchar(30)    NOT NULL,       -- Login | AgentJob
    ObjectName        sysname        NOT NULL,
    Justification     nvarchar(400)  NOT NULL,
    ApprovedBy        nvarchar(128)  NOT NULL,
    ApprovedAt        datetime2(0)   NOT NULL CONSTRAINT DF_DriftException_At DEFAULT SYSUTCDATETIME(),
    ExpiresAt         datetime2(0)   NOT NULL,
    PrimaryAtApproval sysname        NULL,
    RevokedAt         datetime2(0)   NULL,
    RevokedBy         nvarchar(128)  NULL);
GO

CREATE OR ALTER PROCEDURE aghealth.usp_ApproveDriftException
    @AgName        sysname,
    @Replica       sysname,
    @ObjectType    varchar(30) = 'Login',
    @ObjectName    sysname,
    @Justification nvarchar(400),
    @ApprovedBy    nvarchar(128),
    @ReviewDays    int = 90
AS
BEGIN
    SET NOCOUNT, XACT_ABORT ON;
    IF @ObjectType NOT IN ('Login', 'AgentJob') THROW 50031, 'ObjectType must be Login or AgentJob.', 1;
    IF NULLIF(LTRIM(@Justification), N'') IS NULL OR NULLIF(LTRIM(@ApprovedBy), N'') IS NULL
        THROW 50032, 'Give the business justification and who approves it.', 1;
    IF @ReviewDays NOT BETWEEN 1 AND 365 THROW 50033, 'Review period must be 1 to 365 days.', 1;
    DECLARE @Primary sysname = (SELECT TOP (1) PrimaryReplica FROM aghealth.Snapshot
                                WHERE AgName = @AgName AND Status = 'Succeeded' ORDER BY SnapshotId DESC);
    IF @Primary IS NULL THROW 50034, 'No successful snapshot of this AG: cannot tell which replica is primary.', 1;
    IF @Replica = @Primary THROW 50035, 'That replica is the primary: an exception is for an object that exists only on a secondary.', 1;
    BEGIN TRAN;
    UPDATE aghealth.DriftException SET RevokedAt = SYSUTCDATETIME(), RevokedBy = @ApprovedBy
    WHERE AgName = @AgName AND ReplicaServerName = @Replica AND ObjectType = @ObjectType AND ObjectName = @ObjectName
      AND RevokedAt IS NULL;
    INSERT aghealth.DriftException (AgName, ReplicaServerName, ObjectType, ObjectName, Justification, ApprovedBy, ExpiresAt, PrimaryAtApproval)
    OUTPUT inserted.ExceptionId, inserted.ObjectType, inserted.ObjectName, inserted.ReplicaServerName, inserted.ExpiresAt, inserted.PrimaryAtApproval
    VALUES (@AgName, @Replica, @ObjectType, @ObjectName, @Justification, @ApprovedBy, DATEADD(DAY, @ReviewDays, SYSUTCDATETIME()), @Primary);
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE aghealth.usp_RevokeDriftException
    @ExceptionId int,
    @RevokedBy   nvarchar(128)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE aghealth.DriftException SET RevokedAt = SYSUTCDATETIME(), RevokedBy = @RevokedBy
    WHERE ExceptionId = @ExceptionId AND RevokedAt IS NULL;
    IF @@ROWCOUNT = 0 THROW 50036, 'No active exception with that id.', 1;
END;
GO

CREATE OR ALTER PROCEDURE aghealth.usp_DriftEvaluate
    @AgName     sysname,
    @SnapshotId bigint
AS
BEGIN
    SET NOCOUNT, XACT_ABORT ON;
    IF OBJECT_ID('agsync.SyncRun') IS NULL RETURN;
    DECLARE @RunId int = (SELECT MAX(RunId) FROM agsync.SyncRun WHERE AgName = @AgName AND Status = 'Succeeded');
    IF @RunId IS NULL RETURN;
    DECLARE @At datetime2(3) = SYSUTCDATETIME(), @RunAt datetime2(3), @Mode varchar(10), @Primary sysname,
            @RMiss int, @ROnly int, @MissOn bit, @OnlyOn bit;
    SELECT @RunAt = StartedAt, @Mode = Mode, @Primary = PrimaryReplica FROM agsync.SyncRun WHERE RunId = @RunId;
    SELECT @RMiss = RuleId, @MissOn = IsEnabled FROM aghealth.AlertRule WHERE RuleName = 'MissingOnSecondary';
    SELECT @ROnly = RuleId, @OnlyOn = IsEnabled FROM aghealth.AlertRule WHERE RuleName = 'OnlyOnSecondary';

    -- What the latest run found and did not fix, one row per replica and object
    CREATE TABLE #D (RuleId int, Replica sysname, ObjectName nvarchar(260), DriftType varchar(20), Action varchar(20),
                     Detail nvarchar(4000) NULL, Kind nvarchar(30), Name sysname, PRIMARY KEY (RuleId, Replica, ObjectName));
    INSERT #D
    SELECT x.RuleId, x.TargetReplica, x.ObjectName, MAX(x.DriftType), MAX(x.Action), MAX(x.Detail), MAX(x.Kind), MAX(x.Name)
    FROM (SELECT CASE WHEN f.DriftType = 'ExtraOnTarget' THEN @ROnly ELSE @RMiss END AS RuleId, f.TargetReplica,
                 CONCAT(CASE f.ObjectType WHEN 'AgentJob' THEN N'Agent job ' ELSE N'Login ' END, f.ObjectName) AS ObjectName,
                 f.DriftType, f.Action, f.Detail,
                 CASE f.ObjectType WHEN 'AgentJob' THEN N'Agent job' ELSE N'Login' END AS Kind, f.ObjectName AS Name
          FROM agsync.DriftFinding f
          WHERE f.RunId = @RunId AND f.ObjectType IN ('Login', 'AgentJob')
            AND (f.DriftType = 'ExtraOnTarget' OR (f.DriftType IN ('Missing', 'Different') AND f.Action <> 'Applied'))) x
    WHERE (x.RuleId = @RMiss AND @MissOn = 1) OR (x.RuleId = @ROnly AND @OnlyOn = 1)
    GROUP BY x.RuleId, x.TargetReplica, x.ObjectName;

    -- Approved exceptions: honoured while unexpired and while the primary is the one they were approved under
    CREATE TABLE #X (Replica sysname, ObjectName nvarchar(260), ExceptionId int, ApprovedBy nvarchar(128),
                     ExpiresAt datetime2(0), Justification nvarchar(400), PrimaryAtApproval sysname NULL, OnHold bit);
    INSERT #X
    SELECT d.Replica, d.ObjectName, e.ExceptionId, e.ApprovedBy, e.ExpiresAt, e.Justification, e.PrimaryAtApproval,
           CASE WHEN ISNULL(e.PrimaryAtApproval, N'') = ISNULL(@Primary, N'') THEN 0 ELSE 1 END
    FROM #D d
    CROSS APPLY (SELECT TOP (1) * FROM aghealth.DriftException e
                 WHERE e.AgName = @AgName AND e.ReplicaServerName = d.Replica AND e.ObjectName = d.Name
                   AND e.ObjectType = CASE d.Kind WHEN N'Agent job' THEN 'AgentJob' ELSE 'Login' END
                   AND e.RevokedAt IS NULL AND e.ExpiresAt > @At
                 ORDER BY e.ExceptionId DESC) e
    WHERE d.RuleId = @ROnly;
    DELETE d FROM #D d JOIN #X x ON x.Replica = d.Replica AND x.ObjectName = d.ObjectName AND x.OnHold = 0
    WHERE d.RuleId = @ROnly;

    DECLARE @Changes TABLE (AlertId bigint, Change varchar(12));
    BEGIN TRAN;
    UPDATE a SET LastSeenAt = @At, LastSnapshotId = @SnapshotId,
                 LastValue = CASE WHEN d.Action = 'NeedsApproval' THEN 'Needs approval' ELSE d.DriftType END
    OUTPUT inserted.AlertId, 'Ongoing' INTO @Changes
    FROM aghealth.Alert a JOIN #D d ON d.RuleId = a.RuleId AND d.Replica = a.ReplicaServerName AND d.ObjectName = a.ObjectName
    WHERE a.State = 'Open' AND a.AgName = @AgName AND a.DatabaseName = '';

    INSERT aghealth.Alert (RuleId, AgName, ReplicaServerName, DatabaseName, ObjectName, Severity, FirstSeenAt, LastSeenAt,
                           OpenSnapshotId, LastSnapshotId, LastValue, Message)
    OUTPUT inserted.AlertId, 'Opened' INTO @Changes
    SELECT d.RuleId, @AgName, d.Replica, '', d.ObjectName, 'Warning', @At, @At, @SnapshotId, @SnapshotId,
           CASE WHEN d.Action = 'NeedsApproval' THEN 'Needs approval' ELSE d.DriftType END,
           LEFT(CONCAT(CASE WHEN d.RuleId = @RMiss THEN N'MissingOnSecondary' ELSE N'OnlyOnSecondary' END, N' on ', @AgName, N'/', d.Replica, N': ',
                       d.Kind, N' ', d.Name,
                       CASE WHEN d.RuleId = @ROnly THEN N' exists here but not on the primary ' + ISNULL(@Primary, N'')
                            WHEN d.DriftType = 'Different' THEN N' differs from the primary ' + ISNULL(@Primary, N'')
                            ELSE N' is on the primary ' + ISNULL(@Primary, N'') + N' but missing here' END, N'.'), 1000)
    FROM #D d
    WHERE NOT EXISTS (SELECT 1 FROM aghealth.Alert a WHERE a.State = 'Open' AND a.AgName = @AgName AND a.RuleId = d.RuleId
                         AND a.ReplicaServerName = d.Replica AND a.DatabaseName = '' AND a.ObjectName = d.ObjectName);

    INSERT aghealth.AlertEvidence (AlertId, SortOrder, Label, Value)
    SELECT c.AlertId, v.SortOrder, v.Label, v.Value
    FROM @Changes c
    JOIN aghealth.Alert a ON a.AlertId = c.AlertId
    JOIN #D d ON d.RuleId = a.RuleId AND d.Replica = a.ReplicaServerName AND d.ObjectName = a.ObjectName
    CROSS APPLY (VALUES
        (1, N'What', CONCAT(d.Kind, N' ', d.Name)),
        (2, N'Replica', d.Replica),
        (3, N'Primary', @Primary),
        (4, N'Found', CASE WHEN d.RuleId = @ROnly THEN N'Currently exists only on this secondary, not on the primary'
                           WHEN d.DriftType = 'Different' THEN N'Different from the primary'
                           ELSE N'Missing on this secondary' END),
        (5, N'Why it matters', CASE WHEN d.RuleId = @ROnly THEN N'Not part of failover: if it matters to an application, that application breaks when another replica becomes PRIMARY; if it should not exist, it is an unmanaged account'
                                    ELSE N'Applications that use it break if this replica becomes PRIMARY' END),
        (6, N'AG Sync', CONCAT(d.Action, CASE WHEN NULLIF(d.Detail, N'') IS NOT NULL THEN N': ' + d.Detail END)),
        (7, N'Checked', CONCAT(FORMAT(@RunAt, 'yyyy-MM-dd HH:mm'), N' UTC, AG Sync run ', @RunId, N' (', @Mode, N')')),
        (8, N'Exception', (SELECT TOP (1) CONCAT(N'Exception ', x.ExceptionId, N' by ', x.ApprovedBy, N' is on hold: approved while ',
                                                 ISNULL(x.PrimaryAtApproval, N'?'), N' was primary, and the primary is now ', @Primary,
                                                 N'. Re-approve it if it still belongs only here.')
                           FROM #X x WHERE x.Replica = d.Replica AND x.ObjectName = d.ObjectName AND x.OnHold = 1))
    ) v(SortOrder, Label, Value)
    WHERE c.Change = 'Opened' AND v.Value IS NOT NULL;

    -- Measured: the latest run no longer finds it
    UPDATE a SET State = 'Resolved', ResolvedAt = @At, LastSnapshotId = @SnapshotId, ResolvedBy = N'measured', LastValue = 'In sync',
                 ResolutionNote = LEFT(CASE
                     WHEN a.RuleId = @ROnly AND x.ExceptionId IS NOT NULL
                          THEN CONCAT(N'Approved exception ', x.ExceptionId, N' by ', x.ApprovedBy, N', review by ',
                                      FORMAT(x.ExpiresAt, 'yyyy-MM-dd'), N': ', x.Justification)
                     WHEN a.RuleId = @ROnly THEN N'Measured: no longer only on the secondary (created on the primary, or removed).'
                     ELSE CONCAT(N'Measured: now in sync with the primary.',
                                 (SELECT TOP (1) CONCAT(N' Approved by ', ap.ApprovedBy, N' (approval ', ap.ApprovalId, N'): ', ap.Reason)
                                  FROM agsync.Approval ap
                                  WHERE ap.AgName = @AgName AND ap.TargetReplica = a.ReplicaServerName AND ap.Outcome = 'Applied'
                                    AND CONCAT(CASE ap.ObjectType WHEN 'AgentJob' THEN N'Agent job ' ELSE N'Login ' END, ap.ObjectName) = a.ObjectName
                                    AND ap.UsedAt >= a.FirstSeenAt
                                  ORDER BY ap.ApprovalId DESC)) END, 400)
    OUTPUT inserted.AlertId, 'Resolved' INTO @Changes
    FROM aghealth.Alert a
    LEFT JOIN #X x ON a.RuleId = @ROnly AND x.Replica = a.ReplicaServerName AND x.ObjectName = a.ObjectName AND x.OnHold = 0
    WHERE a.State = 'Open' AND a.AgName = @AgName AND a.RuleId IN (@RMiss, @ROnly) AND a.DatabaseName = ''
      AND NOT EXISTS (SELECT 1 FROM #D d WHERE d.RuleId = a.RuleId AND d.Replica = a.ReplicaServerName AND d.ObjectName = a.ObjectName);
    COMMIT;

    SELECT c.Change, a.AlertId, a.Severity, r.RuleName, a.ReplicaServerName, a.ObjectName, a.LastValue
    FROM @Changes c JOIN aghealth.Alert a ON a.AlertId = c.AlertId JOIN aghealth.AlertRule r ON r.RuleId = a.RuleId
    WHERE c.Change <> 'Ongoing';
END;
GO

-- How each AG appears on the dashboard: a friendly name, an environment tag, shown or hidden, and the order.
-- An AG with no row here is shown, as itself, in the 'Unassigned' environment.
IF OBJECT_ID('aghealth.AgDisplay') IS NULL
CREATE TABLE aghealth.AgDisplay (
    AgName      sysname       NOT NULL CONSTRAINT PK_AgDisplay PRIMARY KEY,
    DisplayName nvarchar(128) NULL,
    Environment nvarchar(30)  NULL,          -- e.g. Lab, Pilot, MT, Production
    IsVisible   bit           NOT NULL CONSTRAINT DF_AgDisplay_Visible DEFAULT 1,
    SortOrder   int           NOT NULL CONSTRAINT DF_AgDisplay_Sort DEFAULT 100);
GO

-- Roles: the collector writes, the dashboard reads. Nothing else gets access to this schema.
IF DATABASE_PRINCIPAL_ID('aghealth_writer') IS NULL CREATE ROLE aghealth_writer;
IF DATABASE_PRINCIPAL_ID('aghealth_reader') IS NULL CREATE ROLE aghealth_reader;
GRANT SELECT, INSERT, UPDATE ON SCHEMA::aghealth TO aghealth_writer;
GRANT EXECUTE ON aghealth.usp_PurgeHistory         TO aghealth_writer;
GRANT EXECUTE ON aghealth.usp_EvaluateAlerts       TO aghealth_writer;
GRANT EXECUTE ON aghealth.usp_RecordNotification   TO aghealth_writer;
GRANT EXECUTE ON aghealth.usp_CompleteNotification TO aghealth_writer;
GRANT EXECUTE ON aghealth.usp_ResolveAlert         TO aghealth_writer;
GRANT EXECUTE ON aghealth.usp_RecordDecision       TO aghealth_writer;
GRANT EXECUTE ON aghealth.usp_DriftEvaluate        TO aghealth_writer;
GRANT EXECUTE ON aghealth.usp_ApproveDriftException TO aghealth_writer;
GRANT EXECUTE ON aghealth.usp_RevokeDriftException  TO aghealth_writer;
GRANT SELECT ON SCHEMA::aghealth TO aghealth_reader;

-- The control account already used by AG Sync becomes the collector's writer
IF DATABASE_PRINCIPAL_ID('agsync_control') IS NOT NULL
   AND IS_ROLEMEMBER('aghealth_writer', 'agsync_control') = 0
    ALTER ROLE aghealth_writer ADD MEMBER agsync_control;
GO
