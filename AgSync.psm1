#Requires -Modules dbatools
<#
    AgSync - keeps server-level objects consistent across Always On AG replicas.

    An Availability Group replicates databases, not the instance. Logins, SQL Agent jobs,
    linked servers and credentials live in master/msdb and stay behind on failover.

    Rules
      - Creates and changes are synced from the current primary to every secondary.
      - Objects found only on a secondary (ExtraOnTarget = possible drop) are alert-only.
      - Agent jobs without a primary-replica guard in step 1 are never synced.
      - Every run and every decision is logged to the control database.

    Author: Louis Achungo | SQL IT Tech Solutions
#>

#region Queries ---------------------------------------------------------------

$script:RoleQuery = @"
SELECT @@SERVERNAME AS replica_name, ars.role_desc
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
               WHERE m.member_principal_id = sp.principal_id), '') AS server_roles
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

function New-AgSyncContext {
    # Resolves the current topology once per call: who is primary, who are secondaries,
    # and how replica names (@@SERVERNAME) map to connection strings.
    param([string[]] $Replica, [string] $AgName, [pscredential] $SqlCredential,
          [string] $ControlInstance, [string] $ControlDatabase)

    $roles = foreach ($r in $Replica) {
        $row = Invoke-DbaQuery -SqlInstance $r -SqlCredential $SqlCredential -Query $script:RoleQuery `
                               -SqlParameter @{ ag = $AgName } -EnableException
        if (-not $row) { Write-Warning "$r is not a replica of AG '$AgName' - ignored."; continue }
        [pscustomobject]@{ Instance = $r; Name = $row.replica_name; Role = $row.role_desc }
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
        Primary         = $primary[0]
        Secondaries     = @($roles | Where-Object Role -eq 'SECONDARY')
        ByName          = $byName
    }
}

#endregion


#region Shared building blocks ------------------------------------------------

function Get-AgSyncExclusion {
    # SQL LIKE patterns from the control DB, converted to PowerShell -like wildcards
    param($Ctx, [string] $ObjectType)
    $rows = Invoke-DbaQuery -SqlInstance $Ctx.ControlInstance -Database $Ctx.ControlDatabase -EnableException `
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
    $source  = Get-AgSyncInventory $Ctx $Ctx.Primary.Instance $script:LoginQuery $pattern
    foreach ($sec in $Ctx.Secondaries) {
        $target = Get-AgSyncInventory $Ctx $sec.Instance $script:LoginQuery $pattern
        Compare-AgSyncInventory -ObjectType 'Login' -Source $source -Target $target `
            -SourceName $Ctx.Primary.Name -TargetName $sec.Name `
            -CompareProperty 'sid', 'password_hash', 'is_disabled', 'default_database_name', 'server_roles' `
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
    if ($s.is_disabled) { $lines += "ALTER LOGIN $n DISABLE;" }
    $lines -join "`n"
}

function Get-AgSyncLoginPlan {
    param($Ctx, $Finding)
    $f = $Finding; $s = $f.SourceObject; $t = $f.TargetObject
    $plan = [pscustomobject]@{ Action = 'Pending'; Kind = $null; Text = $null; Note = $f.Detail }

    if ($f.DriftType -eq 'ExtraOnTarget') { $plan.Action = 'AlertOnly'; return $plan }

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


#region Run logging and execution ---------------------------------------------

function Start-AgSyncRun {
    param($Ctx, [string] $Mode)
    (Invoke-DbaQuery -SqlInstance $Ctx.ControlInstance -Database $Ctx.ControlDatabase -EnableException -Query @"
INSERT agsync.SyncRun (AgName, PrimaryReplica, Mode) OUTPUT INSERTED.RunId VALUES (@ag, @pri, @mode);
"@ -SqlParameter @{ ag = $Ctx.AgName; pri = $Ctx.Primary.Name; mode = $Mode }).RunId
}

function Write-AgSyncFinding {
    # Logs one decision. Planned SQL is never stored: it can contain password hashes.
    param($Ctx, [int] $RunId, $Finding, [string] $Action, [string] $Note)
    Invoke-DbaQuery -SqlInstance $Ctx.ControlInstance -Database $Ctx.ControlDatabase -EnableException -Query @"
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
    Invoke-DbaQuery -SqlInstance $Ctx.ControlInstance -Database $Ctx.ControlDatabase -EnableException -Query @"
UPDATE agsync.SyncRun
SET EndedAt = SYSUTCDATETIME(), Status = @status, FindingCount = @cnt, ErrorMessage = @err
WHERE RunId = @run;
"@ -SqlParameter @{ status = $Status; cnt = $Count; err = $err; run = $RunId }
}

function Invoke-AgSyncPlan {
    # The only function that changes a replica
    param($Ctx, $Finding, $Plan)
    $target = $Ctx.ByName[$Finding.TargetReplica]
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


#region Public commands -------------------------------------------------------

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
        [ValidateSet('Login', 'AgentJob')] [string[]] $ObjectType = @('Login', 'AgentJob'),
        [string] $ControlInstance = 'localhost',
        [string] $ControlDatabase = 'AgSyncControl'
    )
    $ctx = New-AgSyncContext $Replica $AgName $SqlCredential $ControlInstance $ControlDatabase
    if ('Login'    -in $ObjectType) { Get-AgSyncLoginFinding $ctx }
    if ('AgentJob' -in $ObjectType) { Get-AgSyncJobFinding   $ctx }
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
        [ValidateSet('Login', 'AgentJob')] [string[]] $ObjectType = @('Login', 'AgentJob'),
        [ValidateSet('Detect', 'Apply')]   [string]   $Mode = 'Detect',
        [string] $ControlInstance = 'localhost',
        [string] $ControlDatabase = 'AgSyncControl'
    )

    $ctx     = New-AgSyncContext $Replica $AgName $SqlCredential $ControlInstance $ControlDatabase
    $runId   = Start-AgSyncRun $ctx $Mode
    $results = @()

    try {
        $findings = @()
        if ('Login'    -in $ObjectType) { $findings += @(Get-AgSyncLoginFinding $ctx) }
        if ('AgentJob' -in $ObjectType) { $findings += @(Get-AgSyncJobFinding   $ctx) }

        $blockedJobs = @($findings | Where-Object { $_.ObjectType -eq 'AgentJob' -and $_.DriftType -eq 'NotRoleAware' } |
                         ForEach-Object ObjectName)

        $results = foreach ($f in $findings) {
            $plan = switch ($f.ObjectType) {
                'Login'    { Get-AgSyncLoginPlan $ctx $f }
                'AgentJob' { Get-AgSyncJobPlan   $ctx $f $blockedJobs }
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