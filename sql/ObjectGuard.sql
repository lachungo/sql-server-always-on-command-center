-- Object Guard: dropped objects, unapproved schema changes and mass data loss in AG databases.
-- Run on the controller, after HealthSchema.sql. Safe to re-run: settings and tuned rules are kept.
--
-- How it works, every monitoring run:
--   1. The collector inventories every AG database on the primary: tables, views, procedures, functions,
--      triggers and synonyms, with the row count of every table.
--   2. It reads the AgGuard Extended Events session on the primary (who did what, from where, with which SQL).
--   3. aghealth.usp_GuardEvaluate compares the inventory with the previous one:
--        gone             -> ObjectDropped  (Critical; Warning if an approved login did it)
--        new or changed   -> UnapprovedDDL  (only when the login is not approved: users do not do DDL)
--        many rows gone   -> MassDataLoss   (users delete data, so this is judged by size, not by occurrence)
--      and attaches the evidence: login, host, application, statement, rows, and the recovery point.
--   4. Resolution is measured where it can be: the object exists again, or the rows are back.
--      Everything else is acknowledged by a person (aghealth.usp_ResolveAlert).
--
-- Author: Louis Achungo | SQL IT Tech Solutions
USE AgSyncControl;
GO

-- Settings are data
IF OBJECT_ID('aghealth.GuardSetting') IS NULL
CREATE TABLE aghealth.GuardSetting (
    Name        varchar(60)   NOT NULL CONSTRAINT PK_GuardSetting PRIMARY KEY,
    Value       nvarchar(200) NOT NULL,
    Description nvarchar(400) NULL);
GO
INSERT aghealth.GuardSetting (Name, Value, Description)
SELECT v.Name, v.Value, v.Descr
FROM (VALUES
    ('MassDeleteMinRows',     N'1000', N'A table must lose at least this many rows between two runs to count as mass data loss (per-table override: aghealth.GuardTable)'),
    ('EvidenceWindowMinutes', N'15',   N'How far back to look in the captured events for who made a change'),
    ('RecoveryInstance',      N'',     N'Where recovery plans restore the standby database. Empty: the replica that holds the full backup. Best: a separate restore server that can read the backup files')
) v(Name, Value, Descr)
WHERE NOT EXISTS (SELECT 1 FROM aghealth.GuardSetting s WHERE s.Name = v.Name);
GO

-- DBA and deployment accounts: allowed to change the schema. Everyone else doing DDL is an alert.
-- For mass data loss this list only labels the account in the evidence; the business still confirms.
IF OBJECT_ID('aghealth.GuardApprovedLogin') IS NULL
CREATE TABLE aghealth.GuardApprovedLogin (
    LoginName sysname       NOT NULL CONSTRAINT PK_GuardApprovedLogin PRIMARY KEY,
    Note      nvarchar(200) NULL,
    AddedAt   datetime2(3)  NOT NULL CONSTRAINT DF_GuardApprovedLogin_At DEFAULT SYSUTCDATETIME());
GO
INSERT aghealth.GuardApprovedLogin (LoginName, Note)
SELECT v.LoginName, v.Note
FROM (VALUES (N'sa', N'Lab administrator'), (N'agsync_apply', N'AG Sync apply account')) v(LoginName, Note)
WHERE NOT EXISTS (SELECT 1 FROM aghealth.GuardApprovedLogin a WHERE a.LoginName = v.LoginName);
GO

-- Per-table overrides: a staging table that is purged every night is not a mass delete
IF OBJECT_ID('aghealth.GuardTable') IS NULL
CREATE TABLE aghealth.GuardTable (
    DatabaseName      sysname NOT NULL,
    SchemaName        sysname NOT NULL,
    TableName         sysname NOT NULL,
    IsIgnored         bit     NOT NULL CONSTRAINT DF_GuardTable_Ignored DEFAULT 0,
    MassDeleteMinRows bigint  NULL,
    CONSTRAINT PK_GuardTable PRIMARY KEY (DatabaseName, SchemaName, TableName));
GO

-- The current inventory: one row per object, kept after a drop (IsPresent = 0) so a restore is recognised
IF OBJECT_ID('aghealth.ObjectInventory') IS NULL
CREATE TABLE aghealth.ObjectInventory (
    AgName       sysname       NOT NULL,
    DatabaseName sysname       NOT NULL,
    SchemaName   sysname       NOT NULL,
    ObjectName   sysname       NOT NULL,
    ObjectType   nvarchar(60)  NOT NULL,
    ObjectId     int           NOT NULL,
    CreateDate   datetime2(3)  NULL,
    ModifyDate   datetime2(3)  NULL,
    TableRows    bigint        NULL,          -- tables only
    IsPresent    bit           NOT NULL CONSTRAINT DF_ObjectInventory_Present DEFAULT 1,
    FirstSeenAt  datetime2(3)  NOT NULL,
    LastSeenAt   datetime2(3)  NOT NULL,
    MissingSince datetime2(3)  NULL,
    CONSTRAINT PK_ObjectInventory PRIMARY KEY (AgName, DatabaseName, SchemaName, ObjectName));
GO

-- Databases whose baseline inventory has been taken. Kept apart from the inventory, so the first
-- object created in an empty database is a change, not part of a baseline that never ends.
IF OBJECT_ID('aghealth.GuardBaseline') IS NULL
CREATE TABLE aghealth.GuardBaseline (
    AgName       sysname      NOT NULL,
    DatabaseName sysname      NOT NULL,
    BaselineAt   datetime2(3) NOT NULL,
    CONSTRAINT PK_GuardBaseline PRIMARY KEY (AgName, DatabaseName));
GO
-- Installs from before this table: a database with an inventory already has its baseline
INSERT aghealth.GuardBaseline (AgName, DatabaseName, BaselineAt)
SELECT i.AgName, i.DatabaseName, MIN(i.FirstSeenAt)
FROM aghealth.ObjectInventory i
WHERE NOT EXISTS (SELECT 1 FROM aghealth.GuardBaseline b WHERE b.AgName = i.AgName AND b.DatabaseName = i.DatabaseName)
GROUP BY i.AgName, i.DatabaseName;
GO

-- Raw events from the AgGuard Extended Events session: the "who, from where, with what SQL" timeline
IF OBJECT_ID('aghealth.GuardCapture') IS NULL
CREATE TABLE aghealth.GuardCapture (
    CaptureId         bigint IDENTITY CONSTRAINT PK_GuardCapture PRIMARY KEY,
    AgName            sysname        NOT NULL,
    ReplicaServerName sysname        NOT NULL,
    EventTime         datetime2(7)   NOT NULL,     -- UTC
    EventName         varchar(40)    NOT NULL,     -- object_created | object_altered | object_deleted | sql_statement_completed | sp_statement_completed
    DatabaseName      sysname        NULL,
    ObjectId          int            NULL,
    ObjectName        sysname        NULL,
    ObjectType        nvarchar(60)   NULL,
    DdlPhase          varchar(20)    NULL,         -- Begin | Commit | Rollback (object events)
    LoginName         sysname        NULL,
    HostName          nvarchar(128)  NULL,
    AppName           nvarchar(256)  NULL,
    SessionId         int            NULL,
    TransactionId     bigint         NULL,
    RowCnt            bigint         NULL,         -- statement events
    DurationUs        bigint         NULL,
    Statement         nvarchar(max)  NULL,
    CapturedAt        datetime2(3)   NOT NULL CONSTRAINT DF_GuardCapture_At DEFAULT SYSUTCDATETIME());

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_GuardCapture_Db_Time')
CREATE INDEX IX_GuardCapture_Db_Time ON aghealth.GuardCapture (AgName, DatabaseName, EventTime DESC)
    INCLUDE (EventName, ObjectId, LoginName);
GO

-- Where reading the event files stopped, per replica (only new events are read and stored)
IF OBJECT_ID('aghealth.GuardBookmark') IS NULL
CREATE TABLE aghealth.GuardBookmark (
    AgName            sysname      NOT NULL,
    ReplicaServerName sysname      NOT NULL,
    LastEventTime     datetime2(7) NOT NULL,
    CONSTRAINT PK_GuardBookmark PRIMARY KEY (AgName, ReplicaServerName));
GO

-- Findings: every drop, create, change, restore and mass data loss, with its evidence. The dashboard timeline.
IF OBJECT_ID('aghealth.ObjectEvent') IS NULL
CREATE TABLE aghealth.ObjectEvent (
    ObjectEventId     bigint IDENTITY CONSTRAINT PK_ObjectEvent PRIMARY KEY,
    AgName            sysname        NOT NULL,
    DatabaseName      sysname        NOT NULL,
    SchemaName        sysname        NOT NULL,
    ObjectName        sysname        NOT NULL,
    ObjectType        nvarchar(60)   NULL,
    EventType         varchar(20)    NOT NULL,
    DetectedAt        datetime2(3)   NOT NULL,
    SnapshotId        bigint         NOT NULL,
    ReplicaServerName sysname        NOT NULL,      -- the primary it happened on
    RowsBefore        bigint         NULL,
    RowsAfter         bigint         NULL,
    OccurredAt        datetime2(7)   NULL,          -- UTC, from the captured event
    LoginName         sysname        NULL,
    HostName          nvarchar(128)  NULL,
    AppName           nvarchar(256)  NULL,
    SessionId         int            NULL,
    TransactionId     bigint         NULL,
    Statement         nvarchar(max)  NULL,
    RecoveryPointUtc  datetime2(3)   NULL,          -- restore to just before the change (STOPAT)
    IsApproved        bit            NULL,          -- NULL = the login is not known
    AlertId           bigint         NULL,
    CONSTRAINT CK_ObjectEvent_Type CHECK (EventType IN ('Dropped','Created','Altered','Restored','DataLoss')));

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ObjectEvent_Ag_Detected')
CREATE INDEX IX_ObjectEvent_Ag_Detected ON aghealth.ObjectEvent (AgName, DetectedAt DESC);
GO

-- The three rules. Their metrics are not snapshot columns, so usp_EvaluateAlerts never touches these alerts.
INSERT aghealth.AlertRule (RuleName, Scope, Metric, Operator, WarnThreshold, CritThreshold, ExpectedValue, Severity, AppliesTo, ConsecutiveSnapshots, Description)
SELECT v.RuleName, 'Database', v.Metric, v.Op, v.Warn, v.Crit, v.Expected, v.Sev, 'All', 1, v.Descr
FROM (VALUES
    ('ObjectDropped', 'ObjectPresence', '<>', NULL, NULL, 'Present',        'Critical', N'An object in an AG database was dropped. The drop has already reached every replica: the AG is not a backup'),
    ('UnapprovedDDL', 'DdlLogin',       '<>', NULL, NULL, 'Approved login', 'Critical', N'The schema was changed by a login that is not approved for DDL'),
    ('MassDataLoss',  'RowsLostPct',    '>',  10,   50,   NULL,             NULL,       N'A table lost a large share of its rows since the previous run (DELETE without WHERE, TRUNCATE)')
) v(RuleName, Metric, Op, Warn, Crit, Expected, Sev, Descr)
WHERE NOT EXISTS (SELECT 1 FROM aghealth.AlertRule r WHERE r.RuleName = v.RuleName);

-- Runbooks. Earlier wordings of these three are replaced; a runbook you wrote yourself is kept.
UPDATE r SET Runbook = v.Runbook
FROM aghealth.AlertRule r
JOIN (VALUES
    ('ObjectDropped', N'Confirm with the business and the account in Evidence whether this drop was intended. If it was not, follow the recovery plan: restore to a standby database, compare, and copy the object back only once the business confirms. Production is never restored over.'),
    ('UnapprovedDDL', N'Users and applications do not change the schema. Confirm the change with the account in Evidence and its owner. If it was legitimate, close the alert (last step of the plan) and, for a DBA or deployment account, add it to aghealth.GuardApprovedLogin.'),
    ('MassDataLoss',  N'Confirm with the business whether this delete was intended (a purge, an archive job). If it was not, follow the recovery plan: restore to a standby database, compare, and copy the rows back only once the business confirms. Production is never restored over.')
) v(RuleName, Runbook) ON v.RuleName = r.RuleName
WHERE r.Runbook IS NULL
   OR r.Runbook LIKE N'Restore the database to a side copy%'
   OR r.Runbook LIKE N'Users do not change the schema%'
   OR r.Runbook LIKE N'If it was not intended: restore to a side copy%';
GO

-- One Object Guard pass for one AG. Called by the collector after the health snapshot.
--   @Databases : JSON array of the databases inventoried in this run, e.g. ["SyncLab"]. A database that
--                could not be read is left out, so a failed read never looks like "every object was dropped".
--   @Inventory : JSON array of objects (DatabaseName, SchemaName, ObjectName, ObjectType, ObjectId,
--                CreateDate, ModifyDate, TableRows).
--   @Captures  : JSON array of new AgGuard events read from the primary.
CREATE OR ALTER PROCEDURE aghealth.usp_GuardEvaluate
    @AgName     sysname,
    @SnapshotId bigint,
    @Replica    sysname,              -- the primary the inventory was read from
    @Databases  nvarchar(max),
    @Inventory  nvarchar(max),
    @Captures   nvarchar(max) = N'[]'
AS
BEGIN
    SET NOCOUNT, XACT_ABORT ON;
    DECLARE @At datetime2(3) = SYSUTCDATETIME(), @Dot nvarchar(3) = N' ' + NCHAR(183) + N' ';
    DECLARE @MinRows bigint = ISNULL(TRY_CAST((SELECT Value FROM aghealth.GuardSetting WHERE Name = 'MassDeleteMinRows') AS bigint), 1000);
    DECLARE @Window  int    = ISNULL(TRY_CAST((SELECT Value FROM aghealth.GuardSetting WHERE Name = 'EvidenceWindowMinutes') AS int), 15);
    DECLARE @RuleDrop int, @RuleDdl int, @RuleLoss int, @LossWarn decimal(19,2), @LossCrit decimal(19,2),
            @DropOn bit, @DdlOn bit, @LossOn bit;
    SELECT @RuleDrop = RuleId, @DropOn = IsEnabled FROM aghealth.AlertRule WHERE RuleName = 'ObjectDropped';
    SELECT @RuleDdl  = RuleId, @DdlOn  = IsEnabled FROM aghealth.AlertRule WHERE RuleName = 'UnapprovedDDL';
    SELECT @RuleLoss = RuleId, @LossOn = IsEnabled, @LossWarn = WarnThreshold, @LossCrit = CritThreshold
    FROM aghealth.AlertRule WHERE RuleName = 'MassDataLoss';
    IF @RuleDrop IS NULL OR @RuleDdl IS NULL OR @RuleLoss IS NULL
        THROW 50010, 'Object Guard rules are missing: run sql/ObjectGuard.sql.', 1;

    -- ---- Inputs ------------------------------------------------------------------------------------
    CREATE TABLE #Db (DatabaseName sysname PRIMARY KEY);
    INSERT #Db SELECT DISTINCT CONVERT(sysname, value) FROM OPENJSON(@Databases);

    CREATE TABLE #Cur (DatabaseName sysname, SchemaName sysname, ObjectName sysname, ObjectType nvarchar(60),
                       ObjectId int, CreateDate datetime2(3), ModifyDate datetime2(3), TableRows bigint NULL,
                       PRIMARY KEY (DatabaseName, SchemaName, ObjectName));
    INSERT #Cur
    SELECT j.DatabaseName, j.SchemaName, j.ObjectName, j.ObjectType, j.ObjectId, j.CreateDate, j.ModifyDate, j.TableRows
    FROM OPENJSON(@Inventory) WITH (DatabaseName sysname, SchemaName sysname, ObjectName sysname, ObjectType nvarchar(60),
                                    ObjectId int, CreateDate datetime2(3), ModifyDate datetime2(3), TableRows bigint) j
    WHERE j.DatabaseName IN (SELECT DatabaseName FROM #Db);

    CREATE TABLE #Cap (ReplicaServerName sysname, EventTime datetime2(7), EventName varchar(40), DatabaseName sysname NULL,
                       ObjectId int NULL, ObjectName sysname NULL, ObjectType nvarchar(60) NULL, DdlPhase varchar(20) NULL,
                       LoginName sysname NULL, HostName nvarchar(128) NULL, AppName nvarchar(256) NULL, SessionId int NULL,
                       TransactionId bigint NULL, RowCnt bigint NULL, DurationUs bigint NULL, Statement nvarchar(max) NULL);
    INSERT #Cap
    SELECT j.ReplicaServerName, j.EventTime, j.EventName, j.DatabaseName, j.ObjectId, j.ObjectName, j.ObjectType, j.DdlPhase,
           j.LoginName, j.HostName, j.AppName, j.SessionId, j.TransactionId, j.RowCnt, j.DurationUs, j.Statement
    FROM OPENJSON(@Captures) WITH (ReplicaServerName sysname, EventTime datetime2(7), EventName varchar(40), DatabaseName sysname,
                                   ObjectId int, ObjectName sysname, ObjectType nvarchar(60), DdlPhase varchar(20),
                                   LoginName sysname, HostName nvarchar(128), AppName nvarchar(256), SessionId int,
                                   TransactionId bigint, RowCnt bigint, DurationUs bigint, Statement nvarchar(max)) j
    WHERE j.EventTime IS NOT NULL;

    -- Bookmarks move past everything read, including the noise removed below
    CREATE TABLE #Bm (ReplicaServerName sysname PRIMARY KEY, LastEventTime datetime2(7));
    INSERT #Bm SELECT ReplicaServerName, MAX(EventTime) FROM #Cap GROUP BY ReplicaServerName;

    -- Noise: statistics are created by the engine for any query, and rolled-back DDL changed nothing
    DELETE #Cap
    WHERE ObjectType IN (N'STATS', N'STATISTICS')
       OR ObjectName LIKE N'[_]WA[_]Sys[_]%'
       OR DdlPhase = 'Rollback'
       OR DatabaseName IN (N'master', N'model', N'msdb', N'tempdb');

    -- ---- Findings ----------------------------------------------------------------------------------
    -- A database seen for the first time is inventoried silently: that is the baseline, not a change
    CREATE TABLE #First (DatabaseName sysname PRIMARY KEY);
    INSERT #First SELECT d.DatabaseName FROM #Db d
    WHERE NOT EXISTS (SELECT 1 FROM aghealth.GuardBaseline b WHERE b.AgName = @AgName AND b.DatabaseName = d.DatabaseName);

    CREATE TABLE #F (Id int IDENTITY PRIMARY KEY, DatabaseName sysname, SchemaName sysname, ObjectName sysname,
                     ObjectType nvarchar(60) NULL, ObjectId int NULL, EventType varchar(20),
                     RowsBefore bigint NULL, RowsAfter bigint NULL);

    -- Dropped: present at the last run, gone now
    INSERT #F (DatabaseName, SchemaName, ObjectName, ObjectType, ObjectId, EventType, RowsBefore, RowsAfter)
    SELECT i.DatabaseName, i.SchemaName, i.ObjectName, i.ObjectType, i.ObjectId, 'Dropped', i.TableRows, NULL
    FROM aghealth.ObjectInventory i
    JOIN #Db d ON d.DatabaseName = i.DatabaseName
    WHERE i.AgName = @AgName AND i.IsPresent = 1
      AND NOT EXISTS (SELECT 1 FROM #Cur c WHERE c.DatabaseName = i.DatabaseName
                         AND c.SchemaName = i.SchemaName AND c.ObjectName = i.ObjectName);

    -- Created (a new name) or Restored (a name that had been dropped)
    INSERT #F (DatabaseName, SchemaName, ObjectName, ObjectType, ObjectId, EventType, RowsBefore, RowsAfter)
    SELECT c.DatabaseName, c.SchemaName, c.ObjectName, c.ObjectType, c.ObjectId,
           CASE WHEN i.ObjectName IS NULL THEN 'Created' ELSE 'Restored' END, NULL, c.TableRows
    FROM #Cur c
    LEFT JOIN aghealth.ObjectInventory i
           ON i.AgName = @AgName AND i.DatabaseName = c.DatabaseName AND i.SchemaName = c.SchemaName AND i.ObjectName = c.ObjectName
    WHERE c.DatabaseName NOT IN (SELECT DatabaseName FROM #First)
      AND (i.ObjectName IS NULL OR i.IsPresent = 0);

    -- Changed: a captured DDL event on an object that exists and is not already a finding (ALTER, index changes)
    INSERT #F (DatabaseName, SchemaName, ObjectName, ObjectType, ObjectId, EventType)
    SELECT DISTINCT c.DatabaseName, c.SchemaName, c.ObjectName, c.ObjectType, c.ObjectId, 'Altered'
    FROM #Cap x
    JOIN #Cur c ON c.DatabaseName = x.DatabaseName AND c.ObjectId = x.ObjectId
    WHERE x.EventName IN ('object_altered', 'object_created', 'object_deleted')
      AND ISNULL(x.DdlPhase, 'Commit') = 'Commit'
      AND c.DatabaseName NOT IN (SELECT DatabaseName FROM #First)
      AND NOT EXISTS (SELECT 1 FROM #F f WHERE f.DatabaseName = c.DatabaseName
                         AND f.SchemaName = c.SchemaName AND f.ObjectName = c.ObjectName);

    -- Data loss: a table that lost at least the minimum number of rows, and more than the warning share of them
    INSERT #F (DatabaseName, SchemaName, ObjectName, ObjectType, ObjectId, EventType, RowsBefore, RowsAfter)
    SELECT c.DatabaseName, c.SchemaName, c.ObjectName, c.ObjectType, c.ObjectId, 'DataLoss', i.TableRows, c.TableRows
    FROM #Cur c
    JOIN aghealth.ObjectInventory i
      ON i.AgName = @AgName AND i.DatabaseName = c.DatabaseName AND i.SchemaName = c.SchemaName
     AND i.ObjectName = c.ObjectName AND i.IsPresent = 1
    LEFT JOIN aghealth.GuardTable g
      ON g.DatabaseName = c.DatabaseName AND g.SchemaName = c.SchemaName AND g.TableName = c.ObjectName
    WHERE c.TableRows IS NOT NULL AND i.TableRows > 0 AND ISNULL(g.IsIgnored, 0) = 0
      AND i.TableRows - c.TableRows >= ISNULL(g.MassDeleteMinRows, @MinRows)
      AND (i.TableRows - c.TableRows) * 100.0 / i.TableRows > @LossWarn;

    -- ---- Evidence: who did it ---------------------------------------------------------------------
    CREATE TABLE #E (Id int PRIMARY KEY, OccurredAt datetime2(7) NULL, LoginName sysname NULL, HostName nvarchar(128) NULL,
                     AppName nvarchar(256) NULL, SessionId int NULL, TransactionId bigint NULL, Statement nvarchar(max) NULL,
                     RecoveryPointUtc datetime2(3) NULL, IsApproved bit NULL);

    BEGIN TRAN;
    DECLARE @Lock nvarchar(255) = CONCAT(N'aghealth.GuardEvaluate:', @AgName);
    EXEC sp_getapplock @Resource = @Lock, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 30000;

    -- Keep the raw events (the timeline), then move the bookmarks
    INSERT aghealth.GuardCapture (AgName, ReplicaServerName, EventTime, EventName, DatabaseName, ObjectId, ObjectName, ObjectType,
                                  DdlPhase, LoginName, HostName, AppName, SessionId, TransactionId, RowCnt, DurationUs, Statement)
    SELECT @AgName, ReplicaServerName, EventTime, EventName, DatabaseName, ObjectId, ObjectName, ObjectType,
           DdlPhase, LoginName, HostName, AppName, SessionId, TransactionId, RowCnt, DurationUs, Statement
    FROM #Cap;

    UPDATE b SET LastEventTime = m.LastEventTime
    FROM aghealth.GuardBookmark b JOIN #Bm m ON m.ReplicaServerName = b.ReplicaServerName
    WHERE b.AgName = @AgName AND m.LastEventTime > b.LastEventTime;
    INSERT aghealth.GuardBookmark (AgName, ReplicaServerName, LastEventTime)
    SELECT @AgName, m.ReplicaServerName, m.LastEventTime FROM #Bm m
    WHERE NOT EXISTS (SELECT 1 FROM aghealth.GuardBookmark b WHERE b.AgName = @AgName AND b.ReplicaServerName = m.ReplicaServerName);

    -- Match each finding to the event that explains it (stored events, so a late run still finds them)
    INSERT #E (Id, OccurredAt, LoginName, HostName, AppName, SessionId, TransactionId, Statement, RecoveryPointUtc)
    SELECT f.Id, m.EventTime, m.LoginName, m.HostName, m.AppName, m.SessionId, m.TransactionId, m.Statement,
           -- Recovery point: one second before the change started
           DATEADD(SECOND, -1, DATEADD(MILLISECOND, -CONVERT(int, ISNULL(m.DurationUs, 0) / 1000),
                                       CONVERT(datetime2(3), ISNULL(m.StartedAt, m.EventTime))))
    FROM #F f
    OUTER APPLY (
        SELECT TOP (1) g.EventTime, g.LoginName, g.HostName, g.AppName, g.SessionId, g.TransactionId,
               g.Statement, g.DurationUs,
               -- An object change starts at its Begin phase, when the Begin event was captured
               (SELECT MIN(b.EventTime) FROM aghealth.GuardCapture b
                WHERE b.AgName = @AgName AND b.DatabaseName = g.DatabaseName AND b.ObjectId = g.ObjectId
                  AND b.TransactionId = g.TransactionId AND b.EventName = g.EventName) AS StartedAt
        FROM aghealth.GuardCapture g
        WHERE g.AgName = @AgName AND g.DatabaseName = f.DatabaseName
          AND g.EventTime >= DATEADD(MINUTE, -@Window, @At)
          AND ((f.EventType = 'Dropped'  AND g.EventName = 'object_deleted' AND g.ObjectId = f.ObjectId)
            OR (f.EventType IN ('Created', 'Restored') AND g.EventName = 'object_created' AND g.ObjectId = f.ObjectId)
            OR (f.EventType = 'Altered'  AND g.EventName IN ('object_altered', 'object_created', 'object_deleted') AND g.ObjectId = f.ObjectId)
            OR (f.EventType = 'DataLoss' AND g.EventName IN ('sql_statement_completed', 'sp_statement_completed')
                AND g.Statement LIKE N'%' + f.ObjectName + N'%'))
        ORDER BY CASE WHEN ISNULL(g.DdlPhase, 'Commit') = 'Commit' THEN 0 ELSE 1 END, g.EventTime DESC
    ) m;

    UPDATE e SET IsApproved = CASE WHEN e.LoginName IS NULL THEN NULL
                                   WHEN EXISTS (SELECT 1 FROM aghealth.GuardApprovedLogin a WHERE a.LoginName = e.LoginName) THEN 1
                                   ELSE 0 END
    FROM #E e;

    -- ---- Inventory ---------------------------------------------------------------------------------
    UPDATE i SET IsPresent = 0, MissingSince = @At
    FROM aghealth.ObjectInventory i
    JOIN #F f ON f.EventType = 'Dropped' AND f.DatabaseName = i.DatabaseName AND f.SchemaName = i.SchemaName AND f.ObjectName = i.ObjectName
    WHERE i.AgName = @AgName;

    UPDATE i SET ObjectType = c.ObjectType, ObjectId = c.ObjectId, CreateDate = c.CreateDate, ModifyDate = c.ModifyDate,
                 TableRows = c.TableRows, IsPresent = 1, MissingSince = NULL, LastSeenAt = @At
    FROM aghealth.ObjectInventory i
    JOIN #Cur c ON c.DatabaseName = i.DatabaseName AND c.SchemaName = i.SchemaName AND c.ObjectName = i.ObjectName
    WHERE i.AgName = @AgName;

    INSERT aghealth.ObjectInventory (AgName, DatabaseName, SchemaName, ObjectName, ObjectType, ObjectId, CreateDate, ModifyDate,
                                     TableRows, IsPresent, FirstSeenAt, LastSeenAt)
    SELECT @AgName, c.DatabaseName, c.SchemaName, c.ObjectName, c.ObjectType, c.ObjectId, c.CreateDate, c.ModifyDate,
           c.TableRows, 1, @At, @At
    FROM #Cur c
    WHERE NOT EXISTS (SELECT 1 FROM aghealth.ObjectInventory i WHERE i.AgName = @AgName AND i.DatabaseName = c.DatabaseName
                         AND i.SchemaName = c.SchemaName AND i.ObjectName = c.ObjectName);

    INSERT aghealth.GuardBaseline (AgName, DatabaseName, BaselineAt)
    SELECT @AgName, DatabaseName, @At FROM #First;

    -- ---- Record the findings -----------------------------------------------------------------------
    DECLARE @Ev TABLE (ObjectEventId bigint, Id int);
    MERGE aghealth.ObjectEvent AS t
    USING (SELECT f.*, e.OccurredAt, e.LoginName, e.HostName, e.AppName, e.SessionId, e.TransactionId, e.Statement,
                  e.RecoveryPointUtc, e.IsApproved
           FROM #F f JOIN #E e ON e.Id = f.Id) AS s
    ON 1 = 0
    WHEN NOT MATCHED THEN
        INSERT (AgName, DatabaseName, SchemaName, ObjectName, ObjectType, EventType, DetectedAt, SnapshotId, ReplicaServerName,
                RowsBefore, RowsAfter, OccurredAt, LoginName, HostName, AppName, SessionId, TransactionId, Statement,
                RecoveryPointUtc, IsApproved)
        VALUES (@AgName, s.DatabaseName, s.SchemaName, s.ObjectName, s.ObjectType, s.EventType, @At, @SnapshotId, @Replica,
                s.RowsBefore, s.RowsAfter, s.OccurredAt, s.LoginName, s.HostName, s.AppName, s.SessionId, s.TransactionId,
                s.Statement, s.RecoveryPointUtc, s.IsApproved)
    OUTPUT inserted.ObjectEventId, s.Id INTO @Ev;

    -- ---- Alerts ------------------------------------------------------------------------------------
    -- What each finding means for an alert (approved schema changes are recorded, not alerted)
    CREATE TABLE #A (ObjectEventId bigint, RuleId int, DatabaseName sysname, ObjectName nvarchar(260), Severity varchar(10),
                     LastValue varchar(60), Message nvarchar(1000), RowsBefore bigint NULL);
    INSERT #A
    SELECT ev.ObjectEventId,
           CASE o.EventType WHEN 'Dropped' THEN @RuleDrop WHEN 'DataLoss' THEN @RuleLoss ELSE @RuleDdl END,
           o.DatabaseName, CONCAT(o.SchemaName, N'.', o.ObjectName),
           CASE WHEN o.EventType = 'Dropped'  THEN CASE WHEN o.IsApproved = 1 THEN 'Warning' ELSE 'Critical' END
                WHEN o.EventType = 'DataLoss' THEN CASE WHEN (o.RowsBefore - o.RowsAfter) * 100.0 / o.RowsBefore > @LossCrit
                                                        THEN 'Critical' ELSE 'Warning' END
                ELSE CASE WHEN o.IsApproved = 0 THEN 'Critical' ELSE 'Warning' END END,
           CASE WHEN o.EventType = 'Dropped'  THEN 'Dropped'
                WHEN o.EventType = 'DataLoss' THEN CONVERT(varchar(60), CONVERT(decimal(9,1), (o.RowsBefore - o.RowsAfter) * 100.0 / o.RowsBefore))
                WHEN o.IsApproved = 0         THEN 'Unapproved login'
                ELSE 'Unknown login' END,
           LEFT(CONCAT(CASE o.EventType WHEN 'Dropped' THEN N'ObjectDropped' WHEN 'DataLoss' THEN N'MassDataLoss' ELSE N'UnapprovedDDL' END,
                       N' on ', @AgName, N'/', o.DatabaseName, N'/', o.SchemaName, N'.', o.ObjectName, N': ',
                       CASE o.EventType WHEN 'Dropped'  THEN N'dropped'
                                        WHEN 'DataLoss' THEN CONCAT(FORMAT(o.RowsBefore - o.RowsAfter, 'N0'), N' of ',
                                                                    FORMAT(o.RowsBefore, 'N0'), N' rows removed')
                                        WHEN 'Created'  THEN N'created'
                                        WHEN 'Restored' THEN N'created again'
                                        ELSE N'changed' END,
                       CASE WHEN o.LoginName IS NOT NULL THEN CONCAT(N' by ', o.LoginName) ELSE N' (login not captured)' END,
                       CASE WHEN o.HostName  IS NOT NULL THEN CONCAT(N' from ', o.HostName) END,
                       CASE WHEN o.OccurredAt IS NOT NULL THEN CONCAT(N' at ', FORMAT(o.OccurredAt, 'HH:mm:ss'), N' UTC') END,
                       N'.'), 1000),
           o.RowsBefore
    FROM @Ev ev
    JOIN aghealth.ObjectEvent o ON o.ObjectEventId = ev.ObjectEventId
    WHERE (o.EventType = 'Dropped' AND @DropOn = 1)
       OR (o.EventType = 'DataLoss' AND @LossOn = 1)
       OR (o.EventType IN ('Created', 'Restored', 'Altered') AND @DdlOn = 1 AND ISNULL(o.IsApproved, 0) = 0);

    DECLARE @Changes TABLE (AlertId bigint, Change varchar(12), ObjectEventId bigint NULL);

    -- Already open for this object: keep it open, escalate if it got worse. Once open, mass loss is measured
    -- against the row count before the first loss, so further deletes in batches add up.
    UPDATE a
    SET LastSeenAt = @At, LastSnapshotId = @SnapshotId, Message = x.Message,
        LastValue  = CASE WHEN a.RuleId = @RuleLoss AND x.FirstRows > 0
                          THEN CONVERT(varchar(60), CONVERT(decimal(9,1), (x.FirstRows - x.NowRows) * 100.0 / x.FirstRows))
                          ELSE x.LastValue END,
        -- Severity only goes up while the alert is open; an escalation is announced and restarts reminders
        NotifiedAt     = CASE WHEN a.Severity <> x.NewSeverity THEN NULL ELSE a.NotifiedAt     END,
        ReminderCount  = CASE WHEN a.Severity <> x.NewSeverity THEN 0    ELSE a.ReminderCount  END,
        LastRemindedAt = CASE WHEN a.Severity <> x.NewSeverity THEN NULL ELSE a.LastRemindedAt END,
        Severity       = x.NewSeverity
    OUTPUT inserted.AlertId,
           CASE WHEN deleted.Severity = 'Warning' AND inserted.Severity = 'Critical' THEN 'Escalated' ELSE 'Ongoing' END,
           NULL
    INTO @Changes
    FROM aghealth.Alert a
    CROSS APPLY (
        SELECT TOP (1) n.Message, n.LastValue,
               first.RowsBefore AS FirstRows, cur.TableRows AS NowRows,
               CASE WHEN a.Severity = 'Critical' THEN 'Critical'
                    WHEN a.RuleId = @RuleLoss AND first.RowsBefore > 0
                         AND (first.RowsBefore - cur.TableRows) * 100.0 / first.RowsBefore > @LossCrit THEN 'Critical'
                    ELSE n.Severity END AS NewSeverity
        FROM #A n
        OUTER APPLY (SELECT TOP (1) oe.RowsBefore FROM aghealth.ObjectEvent oe
                     WHERE oe.AlertId = a.AlertId AND oe.EventType = 'DataLoss' ORDER BY oe.ObjectEventId) first
        OUTER APPLY (SELECT TOP (1) c.TableRows FROM #Cur c
                     WHERE c.DatabaseName = a.DatabaseName AND CONCAT(c.SchemaName, N'.', c.ObjectName) = a.ObjectName) cur
        WHERE n.RuleId = a.RuleId AND n.DatabaseName = a.DatabaseName AND n.ObjectName = a.ObjectName
        ORDER BY CASE n.Severity WHEN 'Critical' THEN 1 ELSE 2 END
    ) x
    WHERE a.State = 'Open' AND a.AgName = @AgName AND a.ReplicaServerName = '';

    -- New: open one alert per object and rule (several findings in one run collapse into the worst)
    INSERT aghealth.Alert (RuleId, AgName, ReplicaServerName, DatabaseName, ObjectName, Severity, FirstSeenAt, LastSeenAt,
                           OpenSnapshotId, LastSnapshotId, LastValue, Message)
    OUTPUT inserted.AlertId, 'Opened', NULL INTO @Changes
    SELECT w.RuleId, @AgName, '', w.DatabaseName, w.ObjectName, w.Severity, @At, @At, @SnapshotId, @SnapshotId, w.LastValue, w.Message
    FROM (SELECT n.*, ROW_NUMBER() OVER (PARTITION BY n.RuleId, n.DatabaseName, n.ObjectName
                                         ORDER BY CASE n.Severity WHEN 'Critical' THEN 1 ELSE 2 END, n.ObjectEventId DESC) AS rn
          FROM #A n) w
    WHERE w.rn = 1
      AND NOT EXISTS (SELECT 1 FROM aghealth.Alert a
                      WHERE a.State = 'Open' AND a.AgName = @AgName AND a.RuleId = w.RuleId AND a.ReplicaServerName = ''
                        AND a.DatabaseName = w.DatabaseName AND a.ObjectName = w.ObjectName);

    -- Link every finding to its alert
    UPDATE o SET AlertId = a.AlertId
    FROM aghealth.ObjectEvent o
    JOIN #A n ON n.ObjectEventId = o.ObjectEventId
    JOIN aghealth.Alert a ON a.State = 'Open' AND a.AgName = @AgName AND a.RuleId = n.RuleId AND a.ReplicaServerName = ''
                         AND a.DatabaseName = n.DatabaseName AND a.ObjectName = n.ObjectName;

    -- Evidence for new alerts, from the finding that opened it
    INSERT aghealth.AlertEvidence (AlertId, SortOrder, Label, Value)
    SELECT c.AlertId, v.SortOrder, v.Label, v.Value
    FROM @Changes c
    CROSS APPLY (SELECT TOP (1) oe.* FROM aghealth.ObjectEvent oe WHERE oe.AlertId = c.AlertId ORDER BY oe.ObjectEventId DESC) o
    -- USER_TABLE -> TABLE, SQL_STORED_PROCEDURE -> PROCEDURE, SQL_SCALAR_FUNCTION -> SCALAR FUNCTION
    CROSS APPLY (SELECT REPLACE(REPLACE(REPLACE(REPLACE(ISNULL(o.ObjectType, N'OBJECT'), N'USER_TABLE', N'TABLE'),
                        N'SQL_STORED_PROCEDURE', N'PROCEDURE'), N'SQL_', N''), N'_', N' ') AS Kind) k
    CROSS APPLY (VALUES
        (1, N'What happened',
            CASE WHEN o.EventType = 'DataLoss' AND o.Statement LIKE N'%TRUNCATE%' THEN N'TRUNCATE TABLE'
                 WHEN o.EventType = 'DataLoss' AND o.Statement LIKE N'%DELETE%'   THEN N'DELETE'
                 WHEN o.EventType = 'DataLoss' THEN N'Rows removed'
                 WHEN o.EventType = 'Dropped'  THEN CONCAT(N'DROP ', k.Kind)
                 WHEN o.EventType = 'Restored' THEN CONCAT(N'CREATE ', k.Kind, N' (again, after a drop)')
                 WHEN o.EventType = 'Created'  THEN CONCAT(N'CREATE ', k.Kind)
                 ELSE CONCAT(N'ALTER ', k.Kind) END),
        -- The account, and what kind it is: the DBA confirms with the business whether this was meant to happen
        (2, N'Account', CASE WHEN o.LoginName IS NULL
                             THEN N'Not captured: is the AgGuard event session running on the primary?'
                             ELSE CONCAT(o.LoginName, N' (',
                                         CASE WHEN o.LoginName LIKE N'%\%' THEN N'Windows login' ELSE N'SQL login' END,
                                         CASE o.IsApproved WHEN 1 THEN N', DBA account' ELSE N', application or user account' END,
                                         N')') END),
        (4, N'When', CASE WHEN o.OccurredAt IS NOT NULL THEN FORMAT(o.OccurredAt, 'yyyy-MM-dd HH:mm:ss') + N' UTC'
                          ELSE N'Between the last two runs' END),
        (5, N'From', NULLIF(CONCAT_WS(@Dot, o.HostName, o.AppName,
                                      CASE WHEN o.SessionId IS NOT NULL THEN CONCAT(N'session ', o.SessionId) END), N'')),
        (6, N'Statement', LEFT(LTRIM(o.Statement), 600)),
        (7, N'Rows', CASE WHEN o.EventType = 'DataLoss'
                          THEN CONCAT(FORMAT(o.RowsBefore, 'N0'), N' before', @Dot, FORMAT(o.RowsAfter, 'N0'), N' after', @Dot,
                                      FORMAT(o.RowsBefore - o.RowsAfter, 'N0'), N' lost')
                          WHEN o.EventType = 'Dropped' AND o.RowsBefore IS NOT NULL
                          THEN CONCAT(FORMAT(o.RowsBefore, 'N0'), N' rows at the last run before the drop') END),
        (8, N'Primary', o.ReplicaServerName),
        (9, N'Recovery point', CASE WHEN o.RecoveryPointUtc IS NOT NULL
                                    THEN CONCAT(N'STOPAT ''', FORMAT(o.RecoveryPointUtc, 'yyyy-MM-ddTHH:mm:ss'), N''' (UTC, 1 s before the change)') END),
        (10, N'Transaction', CONVERT(nvarchar(30), o.TransactionId))
    ) v(SortOrder, Label, Value)
    WHERE c.Change = 'Opened' AND v.Value IS NOT NULL;

    -- ---- Measured resolution -----------------------------------------------------------------------
    -- A dropped object is resolved when it exists again; lost rows when the table is back within the rule
    UPDATE a
    SET State = 'Resolved', ResolvedAt = @At, LastSnapshotId = @SnapshotId, ResolvedBy = N'measured',
        LastValue = 'Present',
        ResolutionNote = LEFT(CONCAT(N'Measured: the object exists again.',
                                     (SELECT TOP (1) CONCAT(N' Approved: ', d.DecidedBy, N' with ', d.ConfirmedWith)
                                      FROM aghealth.AlertDecision d WHERE d.AlertId = a.AlertId AND d.Decision = 'Recover'
                                      ORDER BY d.DecisionId DESC)), 400)
    OUTPUT inserted.AlertId, 'Resolved', NULL INTO @Changes
    FROM aghealth.Alert a
    WHERE a.State = 'Open' AND a.AgName = @AgName AND a.RuleId = @RuleDrop AND a.ReplicaServerName = ''
      AND a.DatabaseName IN (SELECT DatabaseName FROM #Db)
      AND EXISTS (SELECT 1 FROM #Cur c WHERE c.DatabaseName = a.DatabaseName AND CONCAT(c.SchemaName, N'.', c.ObjectName) = a.ObjectName);

    UPDATE a
    SET State = 'Resolved', ResolvedAt = @At, LastSnapshotId = @SnapshotId, ResolvedBy = N'measured',
        LastValue = CONVERT(varchar(60), CONVERT(decimal(9,1), (r.FirstRows - r.NowRows) * 100.0 / r.FirstRows)),
        ResolutionNote = LEFT(CONCAT(N'Measured: rows are back, ', FORMAT(r.NowRows, 'N0'), N' of ', FORMAT(r.FirstRows, 'N0'), N'.',
                                     (SELECT TOP (1) CONCAT(N' Approved: ', d.DecidedBy, N' with ', d.ConfirmedWith)
                                      FROM aghealth.AlertDecision d WHERE d.AlertId = a.AlertId AND d.Decision = 'Recover'
                                      ORDER BY d.DecisionId DESC)), 400)
    OUTPUT inserted.AlertId, 'Resolved', NULL INTO @Changes
    FROM aghealth.Alert a
    CROSS APPLY (SELECT TOP (1) oe.RowsBefore AS FirstRows, c.TableRows AS NowRows
                 FROM aghealth.ObjectEvent oe
                 JOIN #Cur c ON c.DatabaseName = a.DatabaseName AND CONCAT(c.SchemaName, N'.', c.ObjectName) = a.ObjectName
                 WHERE oe.AlertId = a.AlertId AND oe.EventType = 'DataLoss'
                 ORDER BY oe.ObjectEventId) r
    WHERE a.State = 'Open' AND a.AgName = @AgName AND a.RuleId = @RuleLoss AND a.ReplicaServerName = ''
      AND r.FirstRows > 0 AND (r.FirstRows - r.NowRows) * 100.0 / r.FirstRows <= @LossWarn;

    COMMIT;

    -- What happened in this run: findings first, then alert changes
    SELECT o.ObjectEventId, o.EventType, o.DatabaseName, o.SchemaName, o.ObjectName, o.ObjectType, o.RowsBefore, o.RowsAfter,
           o.LoginName, o.HostName, o.AppName, o.OccurredAt, o.IsApproved, o.AlertId
    FROM @Ev ev JOIN aghealth.ObjectEvent o ON o.ObjectEventId = ev.ObjectEventId
    ORDER BY o.ObjectEventId;

    SELECT c.Change, a.AlertId, a.Severity, r.RuleName, a.ReplicaServerName, a.DatabaseName, a.ObjectName,
           a.LastValue, a.FirstSeenAt, a.ResolvedAt, a.Message
    FROM @Changes c
    JOIN aghealth.Alert a     ON a.AlertId = c.AlertId
    JOIN aghealth.AlertRule r ON r.RuleId  = a.RuleId
    ORDER BY CASE c.Change WHEN 'Opened' THEN 1 WHEN 'Escalated' THEN 2 WHEN 'Resolved' THEN 4 ELSE 5 END,
             CASE a.Severity WHEN 'Critical' THEN 1 ELSE 2 END;
END;
GO

GRANT EXECUTE ON aghealth.usp_GuardEvaluate TO aghealth_writer;
GO

-- Evidence written by the first version: 'Who' + 'Approved for DDL' become one 'Account' line
UPDATE e
SET Label = N'Account',
    Value = CONCAT(e.Value, N' (', CASE WHEN e.Value LIKE N'%\%' THEN N'Windows login' ELSE N'SQL login' END,
                   CASE WHEN EXISTS (SELECT 1 FROM aghealth.GuardApprovedLogin a WHERE a.LoginName = e.Value)
                        THEN N', DBA account' ELSE N', application or user account' END, N')')
FROM aghealth.AlertEvidence e
WHERE e.Label = N'Who' AND e.Value NOT LIKE N'Not captured%';
DELETE aghealth.AlertEvidence WHERE Label = N'Approved for DDL';
GO
