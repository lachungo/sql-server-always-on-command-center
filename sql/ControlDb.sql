-- AgSync control database: run on the controller instance (outside the AG). Safe to re-run.
IF DB_ID('AgSyncControl') IS NULL CREATE DATABASE AgSyncControl;
GO
USE AgSyncControl;
GO
IF SCHEMA_ID('agsync') IS NULL EXEC('CREATE SCHEMA agsync');
GO
IF OBJECT_ID('agsync.SyncRun') IS NULL
CREATE TABLE agsync.SyncRun (
    RunId          int IDENTITY PRIMARY KEY,
    AgName         sysname        NOT NULL,
    PrimaryReplica sysname        NULL,
    Mode           varchar(10)    NOT NULL,              -- Detect | Apply
    StartedAt      datetime2(0)   NOT NULL DEFAULT SYSUTCDATETIME(),
    EndedAt        datetime2(0)   NULL,
    Status         varchar(20)    NOT NULL DEFAULT 'Running',
    FindingCount   int            NULL,
    ErrorMessage   nvarchar(4000) NULL);

IF OBJECT_ID('agsync.DriftFinding') IS NULL
CREATE TABLE agsync.DriftFinding (
    FindingId     bigint IDENTITY PRIMARY KEY,
    RunId         int            NOT NULL REFERENCES agsync.SyncRun(RunId),
    ObjectType    varchar(30)    NOT NULL,              -- Login | AgentJob
    ObjectName    sysname        NOT NULL,
    SourceReplica sysname        NOT NULL,
    TargetReplica sysname        NOT NULL,
    DriftType     varchar(20)    NOT NULL,              -- Missing | Different | ExtraOnTarget | NotRoleAware
    Detail        nvarchar(4000) NULL,
    Action        varchar(20)    NOT NULL DEFAULT 'Pending', -- Applied | AlertOnly | Skipped | Failed
    ActionAt      datetime2(0)   NULL,
    DetectedAt    datetime2(0)   NOT NULL DEFAULT SYSUTCDATETIME());

IF OBJECT_ID('agsync.ObjectExclusion') IS NULL
CREATE TABLE agsync.ObjectExclusion (
    ObjectType        varchar(30)   NOT NULL,
    ObjectNamePattern sysname       NOT NULL,           -- SQL LIKE pattern
    Reason            nvarchar(400) NULL,
    CONSTRAINT PK_ObjectExclusion PRIMARY KEY (ObjectType, ObjectNamePattern));

-- Objects that are local to each instance by design and must never be synced
INSERT agsync.ObjectExclusion (ObjectType, ObjectNamePattern, Reason)
SELECT v.t, v.p, v.r FROM (VALUES
    ('Login',    'sa',          'Built-in; managed per instance'),
    ('Login',    '##%',         'Internal certificate-based logins'),
    ('Login',    'NT %',        'Local service/system accounts'),
    ('Login',    'BUILTIN\%',   'Local Windows groups; exist per instance'),
    ('Login',    'dbm_login',   'HADR endpoint login; created per replica'),
    ('AgentJob', 'syspolicy_purge_history', 'Built-in maintenance job')
) v(t, p, r)
WHERE NOT EXISTS (SELECT 1 FROM agsync.ObjectExclusion e
                  WHERE e.ObjectType = v.t AND e.ObjectNamePattern = v.p);
GO

-- ---- Scoped approvals ---------------------------------------------------------------------------
-- Auto mode applies ordinary changes by itself and holds back anything that grants power (an elevated login,
-- an Agent job, a SID rebuild, a new AG database). A held-back change runs only after a DBA approves THAT
-- object, on THAT replica, as it is defined at that moment:
--   * the approval is bound to a fingerprint of the definition (type, SID, roles, permissions; or the job's
--     steps, schedules and owner). If the login gains a role after the approval, the fingerprint no longer
--     matches and the change waits again;
--   * one approval, one use: it is marked used by the run that applies it, with the outcome;
--   * approvals expire (24 hours by default).
IF COL_LENGTH('agsync.DriftFinding', 'Fingerprint') IS NULL
    ALTER TABLE agsync.DriftFinding ADD Fingerprint varchar(66) NULL;
GO
IF OBJECT_ID('agsync.Approval') IS NULL
CREATE TABLE agsync.Approval (
    ApprovalId         int IDENTITY CONSTRAINT PK_Approval PRIMARY KEY,
    AgName             sysname        NOT NULL,
    ObjectType         varchar(30)    NOT NULL,
    ObjectName         sysname        NOT NULL,
    TargetReplica      sysname        NOT NULL,
    Fingerprint        varchar(66)    NOT NULL,      -- what was approved, exactly
    ApprovedDefinition nvarchar(4000) NULL,          -- the same, readable (e.g. type=SQL_LOGIN; roles=sysadmin)
    ApprovedBy         nvarchar(128)  NOT NULL,
    Reason             nvarchar(400)  NOT NULL,
    ApprovedAt         datetime2(0)   NOT NULL CONSTRAINT DF_Approval_At DEFAULT SYSUTCDATETIME(),
    ExpiresAt          datetime2(0)   NOT NULL,
    UsedAt             datetime2(0)   NULL,
    UsedRunId          int            NULL,
    Outcome            varchar(20)    NULL);          -- Applied | Failed
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Approval_Open')
CREATE INDEX IX_Approval_Open ON agsync.Approval (AgName, ObjectType, ObjectName, TargetReplica) WHERE UsedAt IS NULL;
GO

-- Approves what the latest AG Sync run of the AG holds back for one object (one replica, or every replica
-- where it waits). Returns the approvals created. The next Auto run applies them, and only them.
CREATE OR ALTER PROCEDURE agsync.usp_ApproveSync
    @AgName        sysname,
    @ObjectType    varchar(30),           -- Login | AgentJob | Database
    @ObjectName    sysname,
    @TargetReplica sysname = NULL,        -- NULL: every replica where it waits
    @ApprovedBy    nvarchar(128),
    @Reason        nvarchar(400),
    @ValidHours    int = 24
AS
BEGIN
    SET NOCOUNT ON;
    IF NULLIF(LTRIM(@ApprovedBy), N'') IS NULL OR NULLIF(LTRIM(@Reason), N'') IS NULL
        THROW 50021, 'Say who approves and why: the approval is part of the audit trail.', 1;
    IF @ValidHours NOT BETWEEN 1 AND 168 THROW 50022, 'An approval is valid for 1 to 168 hours.', 1;
    DECLARE @RunId int = (SELECT MAX(RunId) FROM agsync.SyncRun WHERE AgName = @AgName AND Status = 'Succeeded');
    DECLARE @Out TABLE (ApprovalId int, TargetReplica sysname, ApprovedDefinition nvarchar(4000), ExpiresAt datetime2(0));

    INSERT agsync.Approval (AgName, ObjectType, ObjectName, TargetReplica, Fingerprint, ApprovedDefinition,
                            ApprovedBy, Reason, ExpiresAt)
    OUTPUT inserted.ApprovalId, inserted.TargetReplica, inserted.ApprovedDefinition, inserted.ExpiresAt INTO @Out
    SELECT @AgName, f.ObjectType, f.ObjectName, f.TargetReplica, f.Fingerprint, f.Detail,
           @ApprovedBy, @Reason, DATEADD(HOUR, @ValidHours, SYSUTCDATETIME())
    FROM agsync.DriftFinding f
    WHERE f.RunId = @RunId AND f.ObjectType = @ObjectType AND f.ObjectName = @ObjectName
      AND f.Action = 'NeedsApproval' AND f.Fingerprint IS NOT NULL
      AND (@TargetReplica IS NULL OR f.TargetReplica = @TargetReplica);

    IF NOT EXISTS (SELECT 1 FROM @Out)
        THROW 50023, 'Nothing by that name is waiting for approval in the latest AG Sync run of this AG.', 1;
    SELECT ApprovalId, @ObjectType AS ObjectType, @ObjectName AS ObjectName, TargetReplica, ApprovedDefinition, ExpiresAt
    FROM @Out;
END;
GO
