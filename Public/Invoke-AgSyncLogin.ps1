function Invoke-AgSyncLogin {
    <#
    .SYNOPSIS
        Syncs server logins from the AG primary to the secondaries.
        Detect = show and record the plan.  Apply = execute it.
        ExtraOnTarget (a possible drop) is always alert-only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]     $Replica,
        [Parameter(Mandatory)] [string]       $AgName,
        [Parameter(Mandatory)] [pscredential] $SqlCredential,
        [ValidateSet('Detect', 'Apply')] [string] $Mode = 'Detect',
        [string] $ControlInstance = 'CHIEF_LUI\SQL01',
        [string] $ControlDatabase = 'AgSyncControl'
    )

    $q = { param($n) '[' + $n.Replace(']', ']]') + ']' }

    # Map replica names (@@SERVERNAME) to connection strings
    $map = @{}
    foreach ($r in $Replica) {
        $map[(Invoke-DbaQuery -SqlInstance $r -SqlCredential $SqlCredential -Query 'SELECT @@SERVERNAME AS n;').n] = $r
    }

    $findings = @(Get-AgSyncLoginDrift -Replica $Replica -AgName $AgName -SqlCredential $SqlCredential `
                    -ControlInstance $ControlInstance -ControlDatabase $ControlDatabase)
    $primaryName = if ($findings) { $findings[0].SourceReplica } else { [DBNull]::Value }

    $runId = (Invoke-DbaQuery -SqlInstance $ControlInstance -Database $ControlDatabase -Query @"
INSERT agsync.SyncRun (AgName, PrimaryReplica, Mode) OUTPUT INSERTED.RunId VALUES (@ag, @pri, @mode);
"@ -SqlParameter @{ ag = $AgName; pri = $primaryName; mode = $Mode }).RunId

    $loginQuery = @"
SELECT sp.name, sp.type_desc, sp.is_disabled, sp.default_database_name,
       CONVERT(varchar(100), sp.sid, 1) AS sid,
       CONVERT(varchar(512), CAST(LOGINPROPERTY(sp.name, 'PasswordHash') AS varbinary(256)), 1) AS password_hash,
       sl.is_policy_checked, sl.is_expiration_checked,
       ISNULL((SELECT STRING_AGG(r.name, ',') FROM sys.server_role_members m
               JOIN sys.server_principals r ON r.principal_id = m.role_principal_id
               WHERE m.member_principal_id = sp.principal_id), '') AS server_roles
FROM sys.server_principals sp
LEFT JOIN sys.sql_logins sl ON sl.principal_id = sp.principal_id
WHERE sp.name = @name;
"@

    $buildCreate = {
        param($s)
        $n = & $q $s.name
        $lines = @()
        if ($s.type_desc -eq 'SQL_LOGIN') {
            $pol = if ($s.is_policy_checked) { 'ON' } else { 'OFF' }
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

    $results = foreach ($f in $findings) {
        $tgtInst = $map[$f.TargetReplica]
        $priInst = $map[$f.SourceReplica]
        $action  = 'Pending'; $planned = $null; $note = $f.Detail

        if ($f.DriftType -eq 'ExtraOnTarget') {
            $action = 'AlertOnly'
        }
        else {
            $s = Invoke-DbaQuery -SqlInstance $priInst -SqlCredential $SqlCredential -Query $loginQuery -SqlParameter @{ name = $f.ObjectName }
            $n = & $q $s.name

            if ($f.DriftType -eq 'Missing') {
                $planned = & $buildCreate $s
            }
            else {
                $diffs = ($f.Detail -replace ' differ$', '') -split ', '
                $t = Invoke-DbaQuery -SqlInstance $tgtInst -SqlCredential $SqlCredential -Query $loginQuery -SqlParameter @{ name = $f.ObjectName }

                if ($diffs -contains 'sid') {
                    # A wrong SID can only be fixed by drop + recreate, and only if nothing depends on it
                    $deps = Invoke-DbaQuery -SqlInstance $tgtInst -SqlCredential $SqlCredential -Query @"
SELECT (SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE login_name = @name)          AS sessions,
       (SELECT COUNT(*) FROM sys.databases  WHERE owner_sid = SUSER_SID(@name))      AS owned_dbs,
       (SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE owner_sid = SUSER_SID(@name))    AS owned_jobs;
"@ -SqlParameter @{ name = $f.ObjectName }
                    if (($deps.sessions + $deps.owned_dbs + $deps.owned_jobs) -gt 0) {
                        $action = 'AlertOnly'
                        $note   = "SID mismatch but login in use on target (sessions=$($deps.sessions), dbs=$($deps.owned_dbs), jobs=$($deps.owned_jobs))"
                    } else {
                        $planned = "DROP LOGIN $n;`n" + (& $buildCreate $s)
                    }
                }
                else {
                    $lines = @()
                    if ($diffs -contains 'password_hash' -and $s.type_desc -eq 'SQL_LOGIN') {
                        $lines += "ALTER LOGIN $n WITH PASSWORD = $($s.password_hash) HASHED;"
                    }
                    if ($diffs -contains 'is_disabled') {
                        $lines += "ALTER LOGIN $n $(if ($s.is_disabled) { 'DISABLE' } else { 'ENABLE' });"
                    }
                    if ($diffs -contains 'default_database_name') {
                        $lines += "IF DB_ID('$($s.default_database_name)') IS NOT NULL EXEC('ALTER LOGIN $n WITH DEFAULT_DATABASE = [$($s.default_database_name)]');"
                    }
                    if ($diffs -contains 'server_roles') {
                        $srcRoles = "$($s.server_roles)" -split ',' | Where-Object { $_ }
                        $tgtRoles = "$($t.server_roles)" -split ',' | Where-Object { $_ }
                        foreach ($role in $srcRoles | Where-Object { $_ -notin $tgtRoles }) {
                            $lines += "ALTER SERVER ROLE [$role] ADD MEMBER $n;"
                        }
                        $extra = $tgtRoles | Where-Object { $_ -notin $srcRoles }
                        if ($extra) { $note += "; extra roles on target left in place: $($extra -join ',')" }
                    }
                    $planned = $lines -join "`n"
                }
            }
        }

        if ($Mode -eq 'Apply' -and $planned) {
            try {
                Invoke-DbaQuery -SqlInstance $tgtInst -SqlCredential $SqlCredential -Query $planned -EnableException
                $action = 'Applied'
            } catch {
                $action = 'Failed'
                $note  += "; error: $($_.Exception.Message)"
            }
        }

        Invoke-DbaQuery -SqlInstance $ControlInstance -Database $ControlDatabase -Query @"
INSERT agsync.DriftFinding (RunId, ObjectType, ObjectName, SourceReplica, TargetReplica, DriftType, Detail, Action, ActionAt)
VALUES (@run, 'Login', @name, @src, @tgt, @drift, @detail, @action,
        CASE WHEN @action IN ('Applied', 'Failed') THEN SYSUTCDATETIME() END);
"@ -SqlParameter @{ run = $runId; name = $f.ObjectName; src = $f.SourceReplica; tgt = $f.TargetReplica
                    drift = $f.DriftType; detail = $note; action = $action }

        [pscustomobject]@{ ObjectName = $f.ObjectName; TargetReplica = $f.TargetReplica; DriftType = $f.DriftType
                           Action = $action; Note = $note; PlannedSql = $planned }
    }

    $status = if ($results | Where-Object Action -eq 'Failed') { 'Failed' } else { 'Succeeded' }
    Invoke-DbaQuery -SqlInstance $ControlInstance -Database $ControlDatabase -Query @"
UPDATE agsync.SyncRun SET EndedAt = SYSUTCDATETIME(), Status = @status, FindingCount = @cnt WHERE RunId = @run;
"@ -SqlParameter @{ status = $status; cnt = @($results).Count; run = $runId }

    $results
}