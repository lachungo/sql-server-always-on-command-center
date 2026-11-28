<#
.SYNOPSIS
    Installs Object Guard for one Availability Group: the controller schema, the AgGuard event session on
    every replica, and read access for the detect account in every AG database. Safe to re-run.

.DESCRIPTION
    1. Controller: runs sql/HealthSchema.sql, then sql/ObjectGuard.sql (both re-runnable, tuned settings kept).
    2. Every replica: creates (or replaces) the AgGuard Extended Events session and starts it, with
       STARTUP_STATE = ON so it survives a restart. It is on every replica so it is already there after a failover.
       What it captures, and nothing else:
         - object_created / object_altered / object_deleted in user databases (DDL: who, from where, which SQL)
         - DELETE statements that affect at least 100 rows, and TRUNCATE TABLE (who removed the data)
       Files: AgGuard*.xel in the instance's log folder, 5 x 20 MB, oldest overwritten.
    3. Every replica: lets the detect login read the backup history in msdb (backupset, backupmediafamily,
       backupfile), for the recovery plans of dropped objects and lost rows.
    4. Primary: creates a user for the detect login in every AG database (it replicates to the secondaries), so
       the collector can read the object list and row counts. The login keeps VIEW SERVER STATE and
       VIEW ANY DEFINITION only: no data access, no write access.

    Run it with an administrator login (sa in the lab). The scheduled monitor never uses this login.

.EXAMPLE
    ./ops/Install-AgGuard.ps1 -Replica 'localhost,14341','localhost,14342','localhost,14343' -AgName aglab_ag `
                              -ControlInstance 'localhost,14340' -SqlCredential $sa

    Author: Louis Achungo | SQL IT Tech Solutions
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string[]] $Replica,
    [Parameter(Mandatory)] [string] $AgName,
    [Parameter(Mandatory)] [string] $ControlInstance,
    [string] $ControlDatabase = 'AgSyncControl',
    [Parameter(Mandatory)] [pscredential] $SqlCredential,         # an administrator: creates the session and the users
    [pscredential] $ControlCredential,                            # defaults to -SqlCredential
    [string] $DetectLogin = 'agsync_detect'
)
$ErrorActionPreference = 'Stop'
Import-Module dbatools
if (-not $ControlCredential) { $ControlCredential = $SqlCredential }
$root = Split-Path $PSScriptRoot -Parent

$session = @"
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'AgGuard')
    DROP EVENT SESSION AgGuard ON SERVER;

CREATE EVENT SESSION AgGuard ON SERVER
ADD EVENT sqlserver.object_created (
    ACTION (sqlserver.server_principal_name, sqlserver.client_hostname, sqlserver.client_app_name,
            sqlserver.session_id, sqlserver.sql_text, sqlserver.database_name)
    WHERE ([database_id] > (4))),
ADD EVENT sqlserver.object_altered (
    ACTION (sqlserver.server_principal_name, sqlserver.client_hostname, sqlserver.client_app_name,
            sqlserver.session_id, sqlserver.sql_text, sqlserver.database_name)
    WHERE ([database_id] > (4))),
ADD EVENT sqlserver.object_deleted (
    ACTION (sqlserver.server_principal_name, sqlserver.client_hostname, sqlserver.client_app_name,
            sqlserver.session_id, sqlserver.sql_text, sqlserver.database_name)
    WHERE ([database_id] > (4))),
ADD EVENT sqlserver.sql_statement_completed (
    SET collect_statement = (1)
    ACTION (sqlserver.server_principal_name, sqlserver.client_hostname, sqlserver.client_app_name,
            sqlserver.session_id, sqlserver.database_name, sqlserver.transaction_id)
    WHERE ([sqlserver].[database_id] > (4)
       AND (([row_count] >= (100) AND [sqlserver].[like_i_sql_unicode_string]([statement], N'%delete%'))
         OR [sqlserver].[like_i_sql_unicode_string]([statement], N'%truncate%table%')))),
ADD EVENT sqlserver.sp_statement_completed (
    SET collect_statement = (1)
    ACTION (sqlserver.server_principal_name, sqlserver.client_hostname, sqlserver.client_app_name,
            sqlserver.session_id, sqlserver.database_name, sqlserver.transaction_id)
    WHERE ([sqlserver].[database_id] > (4)
       AND (([row_count] >= (100) AND [sqlserver].[like_i_sql_unicode_string]([statement], N'%delete%'))
         OR [sqlserver].[like_i_sql_unicode_string]([statement], N'%truncate%table%'))))
ADD TARGET package0.event_file (SET filename = N'AgGuard', max_file_size = (20), max_rollover_files = (5))
WITH (EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS, MAX_DISPATCH_LATENCY = 5 SECONDS, STARTUP_STATE = ON);

ALTER EVENT SESSION AgGuard ON SERVER STATE = START;
"@

# 1. Controller schema
Write-Host "Controller $ControlInstance : health schema and Object Guard schema"
foreach ($file in 'HealthSchema.sql', 'ObjectGuard.sql') {
    Invoke-DbaQuery -SqlInstance $ControlInstance -SqlCredential $ControlCredential -File (Join-Path $root "sql/$file") -EnableException
}

# 2. The event session on every replica; find the primary on the way
$primary = $null
$report  = foreach ($r in $Replica) {
    try {
        Invoke-DbaQuery -SqlInstance $r -SqlCredential $SqlCredential -Database master -Query $session -EnableException
        # Recovery plans read the backup history of every replica: which files, and which logical files to move
        Invoke-DbaQuery -SqlInstance $r -SqlCredential $SqlCredential -Database msdb -EnableException -Query @"
IF USER_ID(@login) IS NULL AND SUSER_ID(@login) IS NOT NULL
BEGIN
    DECLARE @sql nvarchar(400) = N'CREATE USER ' + QUOTENAME(@login) + N' FOR LOGIN ' + QUOTENAME(@login) + N';';
    EXEC (@sql);
END;
IF USER_ID(@login) IS NOT NULL
BEGIN
    DECLARE @g nvarchar(600) = N'GRANT SELECT ON dbo.backupset TO ' + QUOTENAME(@login) + N'; '
                             + N'GRANT SELECT ON dbo.backupmediafamily TO ' + QUOTENAME(@login) + N'; '
                             + N'GRANT SELECT ON dbo.backupfile TO ' + QUOTENAME(@login) + N';';
    EXEC (@g);
END;
"@ -SqlParameter @{ login = $DetectLogin }
        $info = Invoke-DbaQuery -SqlInstance $r -SqlCredential $SqlCredential -EnableException -Query @"
SELECT @@SERVERNAME AS Name,
       (SELECT ars.role_desc FROM sys.availability_groups ag
        JOIN sys.dm_hadr_availability_replica_states ars ON ars.group_id = ag.group_id AND ars.is_local = 1
        WHERE ag.name = @ag) AS Role,
       (SELECT CAST(t.target_data AS xml).value('(EventFileTarget/File/@name)[1]', 'nvarchar(260)')
        FROM sys.dm_xe_sessions s JOIN sys.dm_xe_session_targets t ON t.event_session_address = s.address
        WHERE s.name = N'AgGuard' AND t.target_name = N'event_file') AS EventFile;
"@ -SqlParameter @{ ag = $AgName }
        if ($info.Role -eq 'PRIMARY') { $primary = $r }
        [pscustomobject]@{ Replica = $info.Name; Instance = $r; Role = $info.Role; Session = 'Running'; EventFile = $info.EventFile }
    }
    catch {
        [pscustomobject]@{ Replica = $null; Instance = $r; Role = $null; Session = "FAILED: $($_.Exception.Message)"; EventFile = $null }
    }
}
$report | Format-Table -AutoSize | Out-String | Write-Host
if (-not $primary) { throw "No replica reports PRIMARY for ${AgName}: the database users were not created. Fix that and re-run." }

# 3. Read access for the detect login in every AG database (created on the primary, replicates to the secondaries)
$dbs = Invoke-DbaQuery -SqlInstance $primary -SqlCredential $SqlCredential -EnableException -Query @"
SELECT adc.database_name AS DatabaseName
FROM sys.availability_groups ag
JOIN sys.availability_databases_cluster adc ON adc.group_id = ag.group_id
WHERE ag.name = @ag;
"@ -SqlParameter @{ ag = $AgName }
foreach ($db in $dbs.DatabaseName) {
    Invoke-DbaQuery -SqlInstance $primary -SqlCredential $SqlCredential -Database $db -EnableException -Query @"
IF SUSER_ID(@login) IS NULL THROW 50001, 'The detect login does not exist on the primary.', 1;
IF USER_ID(@login) IS NULL
BEGIN
    DECLARE @sql nvarchar(400) = N'CREATE USER ' + QUOTENAME(@login) + N' FOR LOGIN ' + QUOTENAME(@login) + N';';
    EXEC (@sql);
END;
"@ -SqlParameter @{ login = $DetectLogin }
    Write-Host "Primary $primary : $DetectLogin can read the object list of $db"
}
Write-Host "Object Guard installed for $AgName. The next monitoring run takes the baseline inventory (no alerts on the first run)."
