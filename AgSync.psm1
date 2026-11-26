#Requires -Modules dbatools
<#
    AgSync - keeps server-level objects consistent across Always On AG replicas.

    An Availability Group replicates databases, not the instance. Logins, SQL Agent jobs,
    linked servers and credentials live in master/msdb and stay behind on failover.

    Rules
      - Creates and changes are synced from the current primary to every secondary.
      - Objects found only on a secondary (ExtraOnTarget = possible drop) are alert-only.
      - Agent jobs without a primary-replica guard in step 1 are never synced.
      - New user databases are joined to the AG only when ready (FULL recovery + a full backup); the tool never
        changes a recovery model or takes a backup on its own.
      - Every run and every decision is logged to the control database.

    Public functions
      Get-AgSyncDrift   - report drift, change nothing
      Invoke-AgSync     - Detect (plan + log) or Apply (execute + log)

    Privilege separation
      - Detect account: VIEW SERVER STATE, VIEW ANY DEFINITION, SELECT on msdb job and backup history tables.
        Sees all drift except password hashes (reading a hash requires CONTROL SERVER) and says so.
      - Apply account: sysadmin (creating jobs owned by other logins requires it). Used only to apply.

    Author: Louis Achungo | SQL IT Tech Solutions
#>

#region Queries ---------------------------------------------------------------

$script:RoleQuery = @"
SELECT @@SERVERNAME AS replica_name, ars.role_desc,
       HAS_PERMS_BY_NAME(NULL, NULL, 'CONTROL SERVER') AS can_read_hash,   -- needed to read password hashes
       IS_SRVROLEMEMBER('sysadmin')                    AS is_sysadmin      -- needed to apply (jobs owned by others)
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_replica_states ars
  ON ars.group_id = ag.group_id AND ars.is_local = 1
WHERE ag.name = @ag;
"@

$script:LoginQuery = @"
SELECT sp.name, sp.type_desc, sp.is_disabled, sp.default_database_name,
       CONVERT(varchar(100), sp.sid, 1) AS sid,
       CONVERT(varchar(512), CAST(LOGINPROPERTY(sp.name, 'PasswordHash') AS varbinary(256)), 1) AS password_hash,
       sl.is_policy_checked, sl.is_expiration_checked,
       ISNULL((SELECT STRING_AGG(r.name, ',') WITHIN GROUP (ORDER BY r.name)
               FROM sys.server_role_members m
               JOIN sys.server_principals r ON r.principal_id = m.role_principal_id
               WHERE m.member_principal_id = sp.principal_id), '') AS server_roles,
       ISNULL((SELECT STRING_AGG(CONCAT(p.state_desc, ' ', p.permission_name), ',') WITHIN GROUP (ORDER BY p.permission_name)
               FROM sys.server_permissions p
               WHERE p.grantee_principal_id = sp.principal_id
                 AND p.class = 100                        -- server-level permissions only
                 AND p.permission_name <> 'CONNECT SQL'), '') AS server_permissions
FROM sys.server_principals sp
LEFT JOIN sys.sql_logins sl ON sl.principal_id = sp.principal_id
WHERE sp.type IN ('S', 'U', 'G');
"@

$script:LoginDependencyQuery = @"
SELECT (SELECT COUNT(*) FROM sys.dm_exec_sessions  WHERE login_name = @name)           AS sessions,
       (SELECT COUNT(*) FROM sys.databases         WHERE owner_sid = SUSER_SID(@name)) AS owned_dbs,
       (SELECT COUNT(*) FROM msdb.dbo.sysjobs      WHERE owner_sid = SUSER_SID(@name)) AS owned_jobs;
"@

$script:JobQuery = @"
SELECT j.name,
       j.enabled,
       SUSER_SNAME(j.owner_sid) AS owner_name,
       c.name AS category,
       CONVERT(varchar(66), HASHBYTES('SHA2_256', ISNULL((
           SELECT STRING_AGG(CONCAT(s.step_id, '|', s.step_name, '|', s.subsystem, '|', s.database_name, '|',
                                    s.on_success_action, '|', s.on_fail_action, '|', s.command), '#')
                  WITHIN GROUP (ORDER BY s.step_id)
           FROM msdb.dbo.sysjobsteps s WHERE s.job_id = j.job_id), N'')), 1) AS step_hash,
       CONVERT(varchar(66), HASHBYTES('SHA2_256', ISNULL((
           SELECT STRING_AGG(CONCAT(sc.name, '|', sc.enabled, '|', sc.freq_type, '|', sc.freq_interval, '|',
                                    sc.freq_subday_type, '|', sc.freq_subday_interval, '|', sc.active_start_time), '#')
                  WITHIN GROUP (ORDER BY sc.name)
           FROM msdb.dbo.sysjobschedules js
           JOIN msdb.dbo.sysschedules sc ON sc.schedule_id = js.schedule_id
           WHERE js.job_id = j.job_id), N'')), 1) AS schedule_hash,
       CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps s
                         WHERE s.job_id = j.job_id AND s.step_id = 1
                           AND s.command LIKE N'%fn_hadr_is_primary_replica%')
            THEN 1 ELSE 0 END AS role_aware
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id;
"@

$script:DatabaseQuery = @"
SELECT d.name,
       d.recovery_model_desc,
       d.state_desc,
       CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.backupset b
                         WHERE b.database_name = d.name AND b.type = 'D'
                           -- A backup of THIS database, not of a dropped namesake. msdb stores these times to the
                           -- whole second while create_date keeps milliseconds, so allow one second either way.
                           AND b.database_creation_date BETWEEN DATEADD(SECOND, -1, d.create_date)
                                                            AND DATEADD(SECOND,  1, d.create_date))
            THEN 1 ELSE 0 END AS has_full_backup
FROM sys.databases d
WHERE d.database_id > 4                -- user databases only
  AND d.is_distributor = 0             -- not a replication distribution database
  AND d.source_database_id IS NULL     -- not a database snapshot
  AND d.group_database_id IS NULL;     -- not already in an availability group
"@

#endregion

#region Display formats -------------------------------------------------------

Update-TypeData -TypeName 'AgSync.Finding' -DefaultDisplayPropertySet ObjectType, ObjectName, SourceReplica, TargetReplica, DriftType, Detail -Force
Update-TypeData -TypeName 'AgSync.Result'  -DefaultDisplayPropertySet ObjectType, ObjectName, TargetReplica, DriftType, Action, Note -Force

#endregion

#region Private helpers -------------------------------------------------------

function ConvertTo-AgSyncQuotedName {
    param([string] $Name)
    '[' + $Name.Replace(']', ']]') + ']'
}

function ConvertTo-AgSyncPermissionSql {
    # 'GRANT VIEW SERVER STATE' -> GRANT VIEW SERVER STATE TO [login];
    param([string] $Permission, [string] $QuotedName)
    $state, $perm = $Permission -split ' ', 2
    switch ($state) {
        'GRANT_WITH_GRANT_OPTION' { "GRANT $perm TO $QuotedName WITH GRANT OPTION;" }
        'DENY'                    { "DENY $perm TO $QuotedName;" }
        default                   { "GRANT $perm TO $QuotedName;" }
    }
}

function New-AgSyncContext {
    # Resolves the current topology once per call: who is primary, who are secondaries,
    # and how replica names (@@SERVERNAME) map to connection strings.
    param([string[]] $Replica, [string] $AgName, [pscredential] $SqlCredential,
          [string] $ControlInstance, [string] $ControlDatabase, [pscredential] $ControlCredential)

    $roles = foreach ($r in $Replica) {
        $row = Invoke-DbaQuery -SqlInstance $r -SqlCredential $SqlCredential -Query $script:RoleQuery `
                               -SqlParameter @{ ag = $AgName } -EnableException
        if (-not $row) { Write-Warning "$r is not a replica of AG '$AgName' - ignored."; continue }
        [pscustomobject]@{ Instance = $r; Name = $row.replica_name; Role = $row.role_desc
                           CanReadHash = [bool]$row.can_read_hash; IsSysadmin = [bool]$row.is_sysadmin }
    }

    $primary = @($roles | Where-Object Role -eq 'PRIMARY')
    if ($primary.Count -ne 1) { throw "Expected exactly one primary for AG '$AgName', found $($primary.Count)." }

    $byName = @{}
    foreach ($x in $roles) { $byName[$x.Name] = $x.Instance }

    [pscustomobject]@{
        AgName          = $AgName
        SqlCredential   = $SqlCredential
        ControlInstance = $ControlInstance
        ControlDatabase = $ControlDatabase
        # Control DB connection: SQL auth when a credential is given, otherwise Windows auth
        Control         = if ($ControlCredential) { @{ SqlInstance = $ControlInstance; Database = $ControlDatabase; SqlCredential = $ControlCredential } }
                          else                    { @{ SqlInstance = $ControlInstance; Database = $ControlDatabase } }
        Primary         = $primary[0]
        Secondaries     = @($roles | Where-Object Role -eq 'SECONDARY')
        ByName          = $byName
        # Privilege separation: what the account running this call is allowed to do, on every replica
        CanReadHash     = -not @($roles | Where-Object { -not $_.CanReadHash }).Count
        CanApply        = -not @($roles | Where-Object { -not $_.IsSysadmin }).Count
        NoApplyOn       = @($roles | Where-Object { -not $_.IsSysadmin } | ForEach-Object Name)
    }
}

function Get-AgSyncExclusion {
    # SQL LIKE patterns from the control DB, converted to PowerShell -like wildcards
    param($Ctx, [string] $ObjectType)
    $cs   = $Ctx.Control
    $rows = Invoke-DbaQuery @cs -EnableException `
                            -Query 'SELECT ObjectNamePattern FROM agsync.ObjectExclusion WHERE ObjectType = @t;' `
                            -SqlParameter @{ t = $ObjectType }
    @(@($rows) | Where-Object { $_ } | ForEach-Object { $_.ObjectNamePattern.Replace('%', '*').Replace('_', '?') })
}

function Get-AgSyncInventory {
    # Runs an inventory query on one instance and returns a name-keyed hashtable, exclusions removed
    param($Ctx, [string] $Instance, [string] $Query, [string[]] $Pattern)
    $h = @{}
    foreach ($row in Invoke-DbaQuery -SqlInstance $Instance -SqlCredential $Ctx.SqlCredential -Query $Query -EnableException) {
        $excluded = $false
        foreach ($p in $Pattern) { if ($row.name -like $p) { $excluded = $true; break } }
        if (-not $excluded) { $h[$row.name] = $row }
    }
    $h
}

function New-AgSyncFinding {
    param($ObjectType, $ObjectName, $SourceReplica, $TargetReplica, $DriftType,
          [string[]] $Property = @(), $Detail, $SourceObject, $TargetObject)
    [pscustomobject]@{
        PSTypeName    = 'AgSync.Finding'
        ObjectType    = $ObjectType
        ObjectName    = $ObjectName
        SourceReplica = $SourceReplica
        TargetReplica = $TargetReplica
        DriftType     = $DriftType
        Property      = $Property
        Detail        = $Detail
        SourceObject  = $SourceObject
        TargetObject  = $TargetObject
    }
}

function Compare-AgSyncInventory {
    # Generic primary-vs-secondary comparison: Missing, Different (by property), ExtraOnTarget
    param($ObjectType, [hashtable] $Source, [hashtable] $Target, $SourceName, $TargetName,
          [string[]] $CompareProperty, [scriptblock] $MissingDetail)

    foreach ($name in $Source.Keys) {
        $s = $Source[$name]
        if (-not $Target.ContainsKey($name)) {
            New-AgSyncFinding $ObjectType $name $SourceName $TargetName 'Missing' @() (& $MissingDetail $s) $s $null
            continue
        }
        $t = $Target[$name]
        $diffs = @(foreach ($p in $CompareProperty) { if ("$($s.$p)" -ne "$($t.$p)") { $p } })
        if ($diffs.Count) {
            $detail = (($diffs -replace '_hash$', 's') -join ', ') + ' differ'
            New-AgSyncFinding $ObjectType $name $SourceName $TargetName 'Different' $diffs $detail $s $t
        }
    }
    foreach ($name in @($Target.Keys | Where-Object { -not $Source.ContainsKey($_) })) {
        New-AgSyncFinding $ObjectType $name $SourceName $TargetName 'ExtraOnTarget' @() `
                          'Not on primary: possible drop, alert only' $null $Target[$name]
    }
}

#endregion

#region Logins ----------------------------------------------------------------

function Get-AgSyncLoginFinding {
    param($Ctx)
    $pattern = Get-AgSyncExclusion $Ctx 'Login'
    $props   = 'sid', 'password_hash', 'is_disabled', 'default_database_name', 'server_roles', 'server_permissions'
    if (-not $Ctx.CanReadHash) {
        # Say so instead of silently reporting "no password drift"
        Write-Warning 'Password hash drift NOT checked: the account lacks CONTROL SERVER (detect account). Run with the apply account to check passwords.'
        $props = $props | Where-Object { $_ -ne 'password_hash' }
    }
    $source  = Get-AgSyncInventory $Ctx $Ctx.Primary.Instance $script:LoginQuery $pattern
    foreach ($sec in $Ctx.Secondaries) {
        $target = Get-AgSyncInventory $Ctx $sec.Instance $script:LoginQuery $pattern
        Compare-AgSyncInventory -ObjectType 'Login' -Source $source -Target $target `
            -SourceName $Ctx.Primary.Name -TargetName $sec.Name `
            -CompareProperty $props `
            -MissingDetail { param($s) "type=$($s.type_desc); roles=$($s.server_roles)" }
    }
}

function New-AgSyncLoginCreateSql {
    # Recreates a login exactly: same SID, same password hash, same policy, roles and state
    param($s)
    $n = ConvertTo-AgSyncQuotedName $s.name
    $lines = @()
    if ($s.type_desc -eq 'SQL_LOGIN') {
        $pol = if ($s.is_policy_checked)     { 'ON' } else { 'OFF' }
        $exp = if ($s.is_expiration_checked) { 'ON' } else { 'OFF' }
        $lines += "CREATE LOGIN $n WITH PASSWORD = $($s.password_hash) HASHED, SID = $($s.sid), CHECK_POLICY = $pol, CHECK_EXPIRATION = $exp;"
    } else {
        $lines += "CREATE LOGIN $n FROM WINDOWS;"
    }
    if ($s.default_database_name -and $s.default_database_name -ne 'master') {
        $lines += "IF DB_ID('$($s.default_database_name)') IS NOT NULL EXEC('ALTER LOGIN $n WITH DEFAULT_DATABASE = [$($s.default_database_name)]');"
    }
    foreach ($role in ("$($s.server_roles)" -split ',' | Where-Object { $_ })) {
        $lines += "ALTER SERVER ROLE [$role] ADD MEMBER $n;"
    }
    foreach ($perm in ("$($s.server_permissions)" -split ',' | Where-Object { $_ })) {
        $lines += ConvertTo-AgSyncPermissionSql $perm $n
    }
    if ($s.is_disabled) { $lines += "ALTER LOGIN $n DISABLE;" }
    $lines -join "`n"
}

function Get-AgSyncLoginPlan {
    param($Ctx, $Finding)
    $f = $Finding; $s = $f.SourceObject; $t = $f.TargetObject
    $plan = [pscustomobject]@{ Action = 'Pending'; Kind = $null; Text = $null; Note = $f.Detail }

    if ($f.DriftType -eq 'ExtraOnTarget') { $plan.Action = 'AlertOnly'; return $plan }

    # Recreating a SQL login needs its password hash; the detect account cannot read it
    $needsHash = $f.DriftType -eq 'Missing' -or 'sid' -in $f.Property
    if ($needsHash -and $s.type_desc -eq 'SQL_LOGIN' -and -not $s.password_hash) {
        $plan.Action = 'AlertOnly'
        $plan.Note  += '; password hash not readable with this account - plan with the apply account'
        return $plan
    }

    if ($f.DriftType -eq 'Missing') {
        $plan.Kind = 'Sql'; $plan.Text = New-AgSyncLoginCreateSql $s
        return $plan
    }

    $n = ConvertTo-AgSyncQuotedName $s.name

    if ('sid' -in $f.Property) {
        # A wrong SID can only be fixed by drop + recreate, and only if nothing depends on it
        $deps = Invoke-DbaQuery -SqlInstance $Ctx.ByName[$f.TargetReplica] -SqlCredential $Ctx.SqlCredential `
                                -Query $script:LoginDependencyQuery -SqlParameter @{ name = $s.name } -EnableException
        if (($deps.sessions + $deps.owned_dbs + $deps.owned_jobs) -gt 0) {
            $plan.Action = 'AlertOnly'
            $plan.Note   = "SID mismatch but login in use on target (sessions=$($deps.sessions), dbs=$($deps.owned_dbs), jobs=$($deps.owned_jobs))"
        } else {
            $plan.Kind = 'Sql'; $plan.Text = "DROP LOGIN $n;`n" + (New-AgSyncLoginCreateSql $s)
        }
        return $plan
    }

    $lines = @()
    if ('password_hash' -in $f.Property -and $s.type_desc -eq 'SQL_LOGIN') {
        $lines += "ALTER LOGIN $n WITH PASSWORD = $($s.password_hash) HASHED;"
    }
    if ('is_disabled' -in $f.Property) {
        $lines += "ALTER LOGIN $n $(if ($s.is_disabled) { 'DISABLE' } else { 'ENABLE' });"
    }
    if ('default_database_name' -in $f.Property) {
        $lines += "IF DB_ID('$($s.default_database_name)') IS NOT NULL EXEC('ALTER LOGIN $n WITH DEFAULT_DATABASE = [$($s.default_database_name)]');"
    }
    if ('server_roles' -in $f.Property) {
        $srcRoles = @("$($s.server_roles)" -split ',' | Where-Object { $_ })
        $tgtRoles = @("$($t.server_roles)" -split ',' | Where-Object { $_ })
        foreach ($role in $srcRoles | Where-Object { $_ -notin $tgtRoles }) {
            $lines += "ALTER SERVER ROLE [$role] ADD MEMBER $n;"
        }
        $extra = @($tgtRoles | Where-Object { $_ -notin $srcRoles })
        if ($extra.Count) { $plan.Note += "; extra roles on target left in place: $($extra -join ',')" }
    }
    if ('server_permissions' -in $f.Property) {
        $srcPerms = @("$($s.server_permissions)" -split ',' | Where-Object { $_ })
        $tgtPerms = @("$($t.server_permissions)" -split ',' | Where-Object { $_ })
        foreach ($perm in $srcPerms | Where-Object { $_ -notin $tgtPerms }) {
            $lines += ConvertTo-AgSyncPermissionSql $perm $n
        }
        $extra = @($tgtPerms | Where-Object { $_ -notin $srcPerms })
        if ($extra.Count) { $plan.Note += "; extra permissions on target left in place: $($extra -join ',')" }
    }

    if ($lines.Count) { $plan.Kind = 'Sql'; $plan.Text = $lines -join "`n" }
    else              { $plan.Action = 'AlertOnly' }   # e.g. only extra roles on target: never removed automatically
    $plan
}

#endregion

#region Agent jobs ------------------------------------------------------------

function Get-AgSyncJobFinding {
    param($Ctx)
    $pattern = Get-AgSyncExclusion $Ctx 'AgentJob'
    $source  = Get-AgSyncInventory $Ctx $Ctx.Primary.Instance $script:JobQuery $pattern

    # A job without a primary-replica guard would run on every replica once synced
    foreach ($name in @($source.Keys | Where-Object { $source[$_].role_aware -eq 0 })) {
        New-AgSyncFinding 'AgentJob' $name $Ctx.Primary.Name $Ctx.Primary.Name 'NotRoleAware' @() `
            'Step 1 has no fn_hadr_is_primary_replica guard: would run on every replica' $source[$name] $null
    }

    foreach ($sec in $Ctx.Secondaries) {
        $target = Get-AgSyncInventory $Ctx $sec.Instance $script:JobQuery $pattern
        Compare-AgSyncInventory -ObjectType 'AgentJob' -Source $source -Target $target `
            -SourceName $Ctx.Primary.Name -TargetName $sec.Name `
            -CompareProperty 'step_hash', 'schedule_hash', 'enabled', 'owner_name', 'category' `
            -MissingDetail { param($s) "owner=$($s.owner_name); role_aware=$($s.role_aware)" }
    }
}

function Get-AgSyncJobPlan {
    param($Ctx, $Finding, [string[]] $Blocked)
    $f = $Finding
    $plan = [pscustomobject]@{ Action = 'Pending'; Kind = $null; Text = $null; Note = $f.Detail }

    if ($f.DriftType -in 'ExtraOnTarget', 'NotRoleAware') { $plan.Action = 'AlertOnly'; return $plan }

    if ($f.ObjectName -in $Blocked) {
        $plan.Action = 'Skipped'
        $plan.Note  += '; blocked until step 1 has a primary-replica guard'
        return $plan
    }

    $plan.Kind = 'CopyJob'
    $plan.Text = "Copy-DbaAgentJob -Source $($f.SourceReplica) -Destination $($f.TargetReplica) -Job '$($f.ObjectName)' -Force"
    $plan
}

#endregion

#region Databases -------------------------------------------------------------

function Get-AgSyncDatabaseFinding {
    # User databases on the primary that are in no availability group
    param($Ctx)
    $pattern = Get-AgSyncExclusion $Ctx 'Database'
    $source  = Get-AgSyncInventory $Ctx $Ctx.Primary.Instance $script:DatabaseQuery $pattern
    foreach ($name in $source.Keys) {
        $s = $source[$name]
        $backup = if ($s.has_full_backup) { 'yes' } else { 'no' }
        New-AgSyncFinding 'Database' $name $Ctx.Primary.Name $Ctx.AgName 'NotInAg' @() `
            "recovery=$($s.recovery_model_desc); full_backup=$backup; state=$($s.state_desc)" $s $null
    }
}

function Get-AgSyncDatabasePlan {
    # Joins a database only when it is ready. Never changes the recovery model or takes a backup on its own.
    param($Ctx, $Finding)
    $s = $Finding.SourceObject
    $n = ConvertTo-AgSyncQuotedName $s.name
    $plan = [pscustomobject]@{ Action = 'Pending'; Kind = $null; Text = $null; Note = $Finding.Detail; Instance = $null }

    $blockers = @()
    if ($s.state_desc -ne 'ONLINE')         { $blockers += "database is $($s.state_desc)" }
    if ($s.recovery_model_desc -ne 'FULL')  { $blockers += "recovery model is $($s.recovery_model_desc) (fix: ALTER DATABASE $n SET RECOVERY FULL;)" }
    if (-not $s.has_full_backup)            { $blockers += "no full backup since it was created (fix: BACKUP DATABASE $n TO DISK = ...;)" }
    if ($blockers.Count) {
        $plan.Action = 'AlertOnly'
        $plan.Note   = "Not ready to join $($Ctx.AgName): " + ($blockers -join '; ')
        return $plan
    }

    # Runs on the primary; automatic seeding then creates the database on every secondary
    $plan.Kind     = 'Sql'
    $plan.Instance = $Ctx.Primary.Instance
    $plan.Text     = "ALTER AVAILABILITY GROUP $(ConvertTo-AgSyncQuotedName $Ctx.AgName) ADD DATABASE $n;"
    $plan
}

#endregion

#region Run logging and execution ---------------------------------------------

function Start-AgSyncRun {
    param($Ctx, [string] $Mode)
    $cs = $Ctx.Control
    (Invoke-DbaQuery @cs -EnableException -Query @"
INSERT agsync.SyncRun (AgName, PrimaryReplica, Mode) OUTPUT INSERTED.RunId VALUES (@ag, @pri, @mode);
"@ -SqlParameter @{ ag = $Ctx.AgName; pri = $Ctx.Primary.Name; mode = $Mode }).RunId
}

function Write-AgSyncFinding {
    # Logs one decision. Planned SQL is never stored: it can contain password hashes.
    param($Ctx, [int] $RunId, $Finding, [string] $Action, [string] $Note)
    $cs = $Ctx.Control
    Invoke-DbaQuery @cs -EnableException -Query @"
INSERT agsync.DriftFinding (RunId, ObjectType, ObjectName, SourceReplica, TargetReplica, DriftType, Detail, Action, ActionAt)
VALUES (@run, @type, @name, @src, @tgt, @drift, @detail, @action,
        CASE WHEN @action IN ('Applied', 'Failed') THEN SYSUTCDATETIME() END);
"@ -SqlParameter @{ run = $RunId; type = $Finding.ObjectType; name = $Finding.ObjectName
                    src = $Finding.SourceReplica; tgt = $Finding.TargetReplica; drift = $Finding.DriftType
                    detail = $Note; action = $Action }
}

function Complete-AgSyncRun {
    param($Ctx, [int] $RunId, [string] $Status, [int] $Count, [string] $ErrorMessage)
    $err = if ($ErrorMessage) { $ErrorMessage } else { [DBNull]::Value }
    $cs = $Ctx.Control
    Invoke-DbaQuery @cs -EnableException -Query @"
UPDATE agsync.SyncRun
SET EndedAt = SYSUTCDATETIME(), Status = @status, FindingCount = @cnt, ErrorMessage = @err
WHERE RunId = @run;
"@ -SqlParameter @{ status = $Status; cnt = $Count; err = $err; run = $RunId }
}

function Invoke-AgSyncPlan {
    param($Ctx, $Finding, $Plan)
    # A plan can name its own instance (e.g. adding a database runs on the primary); otherwise the target replica
    $target = if ($Plan.PSObject.Properties['Instance'] -and $Plan.Instance) { $Plan.Instance }
              else { $Ctx.ByName[$Finding.TargetReplica] }
    switch ($Plan.Kind) {
        'Sql' {
            Invoke-DbaQuery -SqlInstance $target -SqlCredential $Ctx.SqlCredential -Query $Plan.Text -EnableException
        }
        'CopyJob' {
            $copy = Copy-DbaAgentJob -Source $Ctx.Primary.Instance -SourceSqlCredential $Ctx.SqlCredential `
                                     -Destination $target -DestinationSqlCredential $Ctx.SqlCredential `
                                     -Job $Finding.ObjectName -Force -EnableException
            # Copy-DbaAgentJob can return extra objects without a Status: judge only the migration results
            $status = @($copy | Where-Object { $_.Status })
            $failed = @($status | Where-Object Status -eq 'Failed')
            if ($failed.Count -or -not @($status | Where-Object Status -eq 'Successful').Count) {
                throw "Copy-DbaAgentJob status=$(($status.Status) -join ',') $(($failed.Notes) -join ' ')"
            }
        }
    }
}

#endregion

#region Public functions ------------------------------------------------------

function Get-AgSyncDrift {
    <#
    .SYNOPSIS
        Reports drift of server-level objects between the AG primary and its secondaries. Changes nothing.
    .EXAMPLE
        $ag = @{ Replica = 'localhost,14341','localhost,14342','localhost,14343'; AgName = 'aglab_ag'
                 SqlCredential = $sa; ControlInstance = 'CHIEF_LUI\SQL01' }
        Get-AgSyncDrift @ag | Format-Table
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]     $Replica,
        [Parameter(Mandatory)] [string]       $AgName,
        [Parameter(Mandatory)] [pscredential] $SqlCredential,
        [ValidateSet('Login', 'AgentJob', 'Database')] [string[]] $ObjectType = @('Login', 'AgentJob', 'Database'),
        [string] $ControlInstance = 'localhost',
        [string] $ControlDatabase = 'AgSyncControl',
        [pscredential] $ControlCredential
    )
    $ctx = New-AgSyncContext $Replica $AgName $SqlCredential $ControlInstance $ControlDatabase $ControlCredential
    if ('Login'    -in $ObjectType) { Get-AgSyncLoginFinding $ctx }
    if ('AgentJob' -in $ObjectType) { Get-AgSyncJobFinding   $ctx }
    if ('Database' -in $ObjectType) { Get-AgSyncDatabaseFinding $ctx }
}

function Invoke-AgSync {
    <#
    .SYNOPSIS
        Detect: builds and logs the sync plan.  Apply: executes it and logs every outcome.
    .EXAMPLE
        Invoke-AgSync @ag -Mode Detect | Format-Table
        Invoke-AgSync @ag -Mode Apply  | Format-Table
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]     $Replica,
        [Parameter(Mandatory)] [string]       $AgName,
        [Parameter(Mandatory)] [pscredential] $SqlCredential,
        [ValidateSet('Login', 'AgentJob', 'Database')] [string[]] $ObjectType = @('Login', 'AgentJob', 'Database'),
        [ValidateSet('Detect', 'Apply')]   [string]   $Mode = 'Detect',
        [string] $ControlInstance = 'localhost',
        [string] $ControlDatabase = 'AgSyncControl',
        [pscredential] $ControlCredential
    )

    $ctx   = New-AgSyncContext $Replica $AgName $SqlCredential $ControlInstance $ControlDatabase $ControlCredential

    # Fail fast, before anything is logged or changed
    if ($Mode -eq 'Apply' -and -not $ctx.CanApply) {
        throw "Apply refused: the account is not sysadmin on $($ctx.NoApplyOn -join ', '). Use the apply account, or run -Mode Detect."
    }

    $runId = Start-AgSyncRun $ctx $Mode
    $results = @()

    try {
        $findings = @()
        if ('Login'    -in $ObjectType) { $findings += @(Get-AgSyncLoginFinding $ctx) }
        if ('AgentJob' -in $ObjectType) { $findings += @(Get-AgSyncJobFinding   $ctx) }
        if ('Database' -in $ObjectType) { $findings += @(Get-AgSyncDatabaseFinding $ctx) }

        $blockedJobs = @($findings | Where-Object { $_.ObjectType -eq 'AgentJob' -and $_.DriftType -eq 'NotRoleAware' } |
                         ForEach-Object ObjectName)

        $results = foreach ($f in $findings) {
            $plan = switch ($f.ObjectType) {
                'Login'    { Get-AgSyncLoginPlan $ctx $f }
                'AgentJob' { Get-AgSyncJobPlan   $ctx $f $blockedJobs }
                'Database' { Get-AgSyncDatabasePlan $ctx $f }
            }

            if ($Mode -eq 'Apply' -and $plan.Kind) {
                try {
                    Invoke-AgSyncPlan $ctx $f $plan
                    $plan.Action = 'Applied'
                } catch {
                    $plan.Action = 'Failed'
                    $plan.Note  += "; error: $($_.Exception.Message)"
                }
            }

            Write-AgSyncFinding $ctx $runId $f $plan.Action $plan.Note

            [pscustomobject]@{
                PSTypeName    = 'AgSync.Result'
                RunId         = $runId
                ObjectType    = $f.ObjectType
                ObjectName    = $f.ObjectName
                TargetReplica = $f.TargetReplica
                DriftType     = $f.DriftType
                Action        = $plan.Action
                Note          = $plan.Note
                Planned       = $plan.Text
            }
        }

        $status = if (@($results | Where-Object Action -eq 'Failed').Count) { 'Failed' } else { 'Succeeded' }
        Complete-AgSyncRun $ctx $runId $status @($results).Count $null
    }
    catch {
        Complete-AgSyncRun $ctx $runId 'Failed' @($results).Count $_.Exception.Message
        throw
    }

    $results
}

#endregion

Export-ModuleMember -Function Get-AgSyncDrift, Invoke-AgSync
