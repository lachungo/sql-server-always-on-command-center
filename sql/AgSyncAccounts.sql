-- AgSync service accounts: msdb permissions for the detect account (job definitions and backup history).
-- Run on EVERY replica: msdb is not part of the AG, so its users never travel with a failover.
-- The logins themselves are created on the primary and distributed by AgSync (same SID everywhere),
-- so this user maps to the same login on every replica.

IF SUSER_ID('agsync_detect') IS NULL
    THROW 50001, 'Login agsync_detect does not exist on this replica yet. Sync logins first.', 1;

IF USER_ID('agsync_detect') IS NULL
    CREATE USER agsync_detect FOR LOGIN agsync_detect;

GRANT SELECT ON dbo.sysjobs         TO agsync_detect;
GRANT SELECT ON dbo.sysjobsteps     TO agsync_detect;
GRANT SELECT ON dbo.sysjobschedules TO agsync_detect;
GRANT SELECT ON dbo.sysschedules    TO agsync_detect;
GRANT SELECT ON dbo.syscategories   TO agsync_detect;
GRANT SELECT ON dbo.backupset       TO agsync_detect;   -- new-database readiness: has it had a full backup?
