-- AgSync control database: run on the controller instance (outside the AG)
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
    Mode           varchar(10)    NOT NULL,
    StartedAt      datetime2(0)   NOT NULL DEFAULT SYSUTCDATETIME(),
    EndedAt        datetime2(0)   NULL,
    Status         varchar(20)    NOT NULL DEFAULT 'Running',
    FindingCount   int            NULL,
    ErrorMessage   nvarchar(4000) NULL);

IF OBJECT_ID('agsync.DriftFinding') IS NULL
CREATE TABLE agsync.DriftFinding (
    FindingId     bigint IDENTITY PRIMARY KEY,
    RunId         int            NOT NULL REFERENCES agsync.SyncRun(RunId),
    ObjectType    varchar(30)    NOT NULL,
    ObjectName    sysname        NOT NULL,
    SourceReplica sysname        NOT NULL,
    TargetReplica sysname        NOT NULL,
    DriftType     varchar(20)    NOT NULL,
    Detail        nvarchar(4000) NULL,
    Action        varchar(20)    NOT NULL DEFAULT 'Pending',
    ActionAt      datetime2(0)   NULL,
    DetectedAt    datetime2(0)   NOT NULL DEFAULT SYSUTCDATETIME());

IF OBJECT_ID('agsync.ObjectExclusion') IS NULL
CREATE TABLE agsync.ObjectExclusion (
    ObjectType        varchar(30)   NOT NULL,
    ObjectNamePattern sysname       NOT NULL,
    Reason            nvarchar(400) NULL,
    CONSTRAINT PK_ObjectExclusion PRIMARY KEY (ObjectType, ObjectNamePattern));

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
