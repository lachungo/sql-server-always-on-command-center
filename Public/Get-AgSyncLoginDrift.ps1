function Get-AgSyncLoginDrift {
    <#
    .SYNOPSIS
        Compares server logins on the AG primary against every secondary.
        Reports Missing, Different (SID, password hash, disabled, default DB, server roles)
        and ExtraOnTarget (exists on a secondary only: a possible drop on the primary).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]     $Replica,
        [Parameter(Mandatory)] [string]       $AgName,
        [Parameter(Mandatory)] [pscredential] $SqlCredential,
        [string] $ControlInstance = 'CHIEF_LUI\SQL01',
        [string] $ControlDatabase = 'AgSyncControl'
    )

    # 1. Work out which replica is primary right now (it changes after failover)
    $roleQuery = @"
SELECT @@SERVERNAME AS replica_name, ars.role_desc
FROM sys.availability_groups ag
JOIN sys.dm_hadr_availability_replica_states ars
  ON ars.group_id = ag.group_id AND ars.is_local = 1
WHERE ag.name = @ag;
"@
    $roles = foreach ($r in $Replica) {
        $row = Invoke-DbaQuery -SqlInstance $r -SqlCredential $SqlCredential -Query $roleQuery -SqlParameter @{ ag = $AgName }
        [pscustomobject]@{ Instance = $r; Name = $row.replica_name; Role = $row.role_desc }
    }
    $primary = $roles | Where-Object Role -eq 'PRIMARY'
    if (-not $primary) { throw "No primary found for AG '$AgName'." }
    $secondaries = $roles | Where-Object Role -eq 'SECONDARY'

    # 2. Exclusion patterns from the control DB (SQL LIKE syntax converted to PowerShell -like)
    $patterns = (Invoke-DbaQuery -SqlInstance $ControlInstance -Database $ControlDatabase -Query @"
SELECT ObjectNamePattern FROM agsync.ObjectExclusion WHERE ObjectType = 'Login';
"@).ObjectNamePattern | ForEach-Object { $_.Replace('%', '*').Replace('_', '?') }
    $isExcluded = { param($n) foreach ($p in $patterns) { if ($n -like $p) { return $true } }; $false }

    # 3. Login inventory query, run on every replica
    $inventoryQuery = @"
SELECT sp.name,
       CONVERT(varchar(100), sp.sid, 1) AS sid,
       sp.type_desc,
       sp.is_disabled,
       sp.default_database_name,
       CONVERT(varchar(512), CAST(LOGINPROPERTY(sp.name, 'PasswordHash') AS varbinary(256)), 1) AS password_hash,
       ISNULL((SELECT STRING_AGG(r.name, ',') WITHIN GROUP (ORDER BY r.name)
               FROM sys.server_role_members m
               JOIN sys.server_principals r ON r.principal_id = m.role_principal_id
               WHERE m.member_principal_id = sp.principal_id), '') AS server_roles
FROM sys.server_principals sp
WHERE sp.type IN ('S', 'U', 'G');
"@
    $getLogins = {
        param($instance)
        $h = @{}
        Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Query $inventoryQuery |
            Where-Object { -not (& $isExcluded $_.name) } |
            ForEach-Object { $h[$_.name] = $_ }
        $h
    }

    $source = & $getLogins $primary.Instance

    # 4. Compare the primary against each secondary
    foreach ($sec in $secondaries) {
        $target = & $getLogins $sec.Instance

        foreach ($name in $source.Keys) {
            $s = $source[$name]
            if (-not $target.ContainsKey($name)) {
                [pscustomobject]@{ ObjectType = 'Login'; ObjectName = $name; SourceReplica = $primary.Name
                                   TargetReplica = $sec.Name; DriftType = 'Missing'; Detail = "type=$($s.type_desc); roles=$($s.server_roles)" }
                continue
            }
            $t = $target[$name]
            $diffs = foreach ($prop in 'sid', 'password_hash', 'is_disabled', 'default_database_name', 'server_roles') {
                if ("$($s.$prop)" -ne "$($t.$prop)") { $prop }
            }
            if ($diffs) {
                [pscustomobject]@{ ObjectType = 'Login'; ObjectName = $name; SourceReplica = $primary.Name
                                   TargetReplica = $sec.Name; DriftType = 'Different'; Detail = ($diffs -join ', ') + ' differ' }
            }
        }

        foreach ($name in $target.Keys | Where-Object { -not $source.ContainsKey($_) }) {
            [pscustomobject]@{ ObjectType = 'Login'; ObjectName = $name; SourceReplica = $primary.Name
                               TargetReplica = $sec.Name; DriftType = 'ExtraOnTarget'; Detail = 'Not on primary: possible drop, alert only' }
        }
    }
}