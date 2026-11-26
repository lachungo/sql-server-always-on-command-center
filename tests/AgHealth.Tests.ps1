#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    AgHealth integration tests (Module 2: health collector and alerts). They run against a real
    Availability Group (the Docker lab in /lab) and break it on purpose: a secondary is suspended,
    alerts must open, hold without duplicates, and resolve when it recovers.

    The collector runs with the least-privilege accounts (detect on the replicas, control on the
    controller). The admin credential is used only to break things, inspect state and clean up.
    Test rules and rows are prefixed "pt_".

    Takes the same parameters as AgSync.Tests.ps1, so one Pester container can run both files.
    Run:
      $c = New-PesterContainer -Path .\tests\AgHealth.Tests.ps1 -Data @{
               Replica = $lab.Replica; AgName = $lab.AgName; ControlInstance = $lab.ControlInstance
               AdminCredential = $sa; ApplyCredential = $app; DetectCredential = $det
               ControlCredential = $ctlCred }
      Invoke-Pester -Container $c -Output Detailed
#>
param(
    [Parameter(Mandatory)] [string[]]     $Replica,
    [Parameter(Mandatory)] [string]       $AgName,
    [Parameter(Mandatory)] [string]       $ControlInstance,
    [Parameter(Mandatory)] [pscredential] $AdminCredential,    # breaking things, inspecting, cleanup
    [pscredential] $ApplyCredential,                           # not used here; accepted for a shared container
    [Parameter(Mandatory)] [pscredential] $DetectCredential,   # the collector's replica account
    [pscredential] $ControlCredential,                         # the collector's controller account
    [string] $AgDatabase = 'SyncLab'                           # a database in the AG
)

BeforeAll {
    Import-Module "$PSScriptRoot/../AgHealth/AgHealth.psm1" -Force

    $collect = @{ Replica = $Replica; AgName = $AgName; SqlCredential = $DetectCredential; ControlInstance = $ControlInstance }
    $writer  = @{ SqlInstance = $ControlInstance; Database = 'AgSyncControl' }
    if ($ControlCredential) { $collect.ControlCredential = $ControlCredential; $writer.SqlCredential = $ControlCredential }
    $adminCtl = @{ SqlInstance = $ControlInstance; Database = 'AgSyncControl'; SqlCredential = $AdminCredential }

    function Invoke-Admin {
        param([string] $Instance, [string] $Query)
        Invoke-DbaQuery -SqlInstance $Instance -SqlCredential $AdminCredential -Query $Query -EnableException
    }
    function Invoke-Ctl {
        param([string] $Query, [hashtable] $Param = @{})
        Invoke-DbaQuery @adminCtl -Query $Query -SqlParameter $Param -EnableException
    }
    function Invoke-Collect {
        param([hashtable] $Override = @{})
        $p = $collect.Clone()
        foreach ($k in $Override.Keys) { $p[$k] = $Override[$k] }
        Invoke-AgHealthCollection @p
    }
    function Get-OpenAlertCount {
        param([string] $ReplicaName = '%', [string] $Rule = '%')
        (Invoke-Ctl @"
SELECT COUNT(*) AS c FROM aghealth.Alert a JOIN aghealth.AlertRule r ON r.RuleId = a.RuleId
WHERE a.State = 'Open' AND a.AgName = @ag AND a.ReplicaServerName LIKE @rep AND r.RuleName LIKE @rule;
"@ @{ ag = $AgName; rep = $ReplicaName; rule = $Rule }).c
    }

    # Ground truth, read as admin: replica name -> connection string, the primary, the async secondary
    $byName = @{}
    $primaryName = $null
    foreach ($r in $Replica) {
        $row = Invoke-Admin $r "SELECT @@SERVERNAME AS n, ISNULL(sys.fn_hadr_is_primary_replica(N'$AgDatabase'), 0) AS p;"
        $byName[$row.n] = $r
        if ($row.p -eq 1) { $primaryName = $row.n }
    }
    $asyncName = (Invoke-Admin $byName[$primaryName] @"
SELECT ar.replica_server_name AS n
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
WHERE ag.name = N'$AgName' AND ar.availability_mode_desc = 'ASYNCHRONOUS_COMMIT'
  AND ar.replica_server_name <> @@SERVERNAME;
"@ | Select-Object -First 1).n
    $agDbCount = (Invoke-Admin $byName[$primaryName] @"
SELECT COUNT(*) AS c FROM sys.availability_databases_cluster adc
JOIN sys.availability_groups ag ON ag.group_id = adc.group_id WHERE ag.name = N'$AgName';
"@).c
}

Describe 'Health schema' {
    It 'ships the 11 default alert rules' {
        (Invoke-Ctl "SELECT COUNT(*) AS c FROM aghealth.AlertRule WHERE RuleName NOT LIKE 'pt[_]%';").c | Should -Be 11
    }

    Context 'Re-running the schema script' {
        BeforeAll {
            Invoke-Ctl "UPDATE aghealth.AlertRule SET WarnThreshold = 12345 WHERE RuleName = 'LogSendQueueHigh';"
            Invoke-DbaQuery -SqlInstance $ControlInstance -SqlCredential $AdminCredential `
                            -File "$PSScriptRoot/../sql/HealthSchema.sql" -EnableException
        }
        AfterAll { Invoke-Ctl "UPDATE aghealth.AlertRule SET WarnThreshold = 102400 WHERE RuleName = 'LogSendQueueHigh';" }

        It 'keeps a tuned threshold (rules are data, not overwritten by a redeploy)' {
            (Invoke-Ctl "SELECT WarnThreshold AS w FROM aghealth.AlertRule WHERE RuleName = 'LogSendQueueHigh';").w |
                Should -Be 12345
        }
        It 'does not duplicate the default rules' {
            (Invoke-Ctl "SELECT COUNT(*) AS c FROM aghealth.AlertRule WHERE RuleName NOT LIKE 'pt[_]%';").c | Should -Be 11
        }
    }
}

Describe 'Collector: healthy AG' {
    BeforeAll { $s = Invoke-Collect }

    It 'succeeds and finds the real primary' {
        $s.Status         | Should -Be 'Succeeded'
        $s.PrimaryReplica | Should -Be $primaryName
    }
    It 'records every replica as reachable' {
        $s.Replicas.Count | Should -Be $Replica.Count
        @($s.Replicas | Where-Object { -not $_.IsReachable }).Count | Should -Be 0
    }
    It 'records every AG database on every replica' {
        $s.Databases.Count | Should -Be ($agDbCount * $Replica.Count)
    }
    It 'reports zero data loss and recovery time on the primary' {
        $p = $s.Databases | Where-Object ReplicaServerName -eq $primaryName
        $p | ForEach-Object { $_.EstimatedDataLossSec | Should -Be 0; $_.EstimatedRecoverySec | Should -Be 0 }
    }
    It 'stores exactly what it returned, in one snapshot' {
        $row = Invoke-Ctl @"
SELECT s.Status,
       (SELECT COUNT(*) FROM aghealth.ReplicaState  r WHERE r.SnapshotId = s.SnapshotId) AS replicas,
       (SELECT COUNT(*) FROM aghealth.DatabaseState d WHERE d.SnapshotId = s.SnapshotId) AS databases
FROM aghealth.Snapshot s WHERE s.SnapshotId = @id;
"@ @{ id = $s.SnapshotId }
        $row.Status    | Should -Be 'Succeeded'
        $row.replicas  | Should -Be $s.Replicas.Count
        $row.databases | Should -Be $s.Databases.Count
    }
    It 'raises no alerts on a healthy AG' {
        @($s.Alerts | Where-Object Change -in 'Opened', 'Escalated').Count | Should -Be 0
    }
}

Describe 'Collector: failure modes' {
    It 'records an unreachable instance quickly instead of hanging' {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $s = Invoke-Collect @{ Replica = @($Replica) + 'localhost,1'; ConnectTimeout = 2 }
        $clock.Stop()
        $s.Status   | Should -Be 'Succeeded'          # the AG itself is fine
        $s.Message  | Should -Match 'Unreachable: localhost,1'
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 30
    }

    It 'fails the snapshot, but keeps what it saw, when no replica reports PRIMARY' {
        $secondaries = @($byName.Keys | Where-Object { $_ -ne $primaryName } | ForEach-Object { $byName[$_] })
        $s = Invoke-Collect @{ Replica = $secondaries }
        $s.Status         | Should -Be 'Failed'
        $s.Message        | Should -Match 'No reachable replica reports PRIMARY'
        $s.PrimaryReplica | Should -BeNullOrEmpty
        $s.Replicas.Count | Should -Be $secondaries.Count
        (Invoke-Ctl "SELECT Status FROM aghealth.Snapshot WHERE SnapshotId = @id;" @{ id = $s.SnapshotId }).Status |
            Should -Be 'Failed'
    }
}

Describe 'Alerts: lifecycle on a really suspended secondary' {
    BeforeAll {
        $asyncInstance = $byName[$asyncName]
        # Start from a healthy snapshot, so streaks are counted from here
        $null = Invoke-Collect

        Invoke-Admin $asyncInstance "ALTER DATABASE [$AgDatabase] SET HADR SUSPEND;"
        $s1 = Invoke-Collect
        $s2 = Invoke-Collect
        $s3 = Invoke-Collect

        Invoke-Admin $asyncInstance "ALTER DATABASE [$AgDatabase] SET HADR RESUME;"
        # Collect until the replica has caught up and its alerts have cleared (up to ~60 s)
        $resolved = @()
        foreach ($i in 1..12) {
            Start-Sleep -Seconds 5
            $s = Invoke-Collect
            $resolved += @($s.Alerts | Where-Object Change -eq 'Resolved')
            if ((Get-OpenAlertCount -ReplicaName $asyncName) -eq 0) { break }
        }
    }
    AfterAll {
        # Never leave the lab suspended, whatever happened above
        try { Invoke-Admin $byName[$asyncName] "ALTER DATABASE [$AgDatabase] SET HADR RESUME;" } catch { }
    }

    It 'reads the suspension from the secondary itself' {
        $db = $s1.Databases | Where-Object { $_.ReplicaServerName -eq $asyncName -and $_.DatabaseName -eq $AgDatabase }
        $db.IsSuspended   | Should -BeTrue
        $db.SuspendReason | Should -Be 'SUSPEND_FROM_USER'
    }
    It 'opens DatabaseSuspended as Critical on the first snapshot' {
        $a = $s1.Alerts | Where-Object { $_.RuleName -eq 'DatabaseSuspended' -and $_.ReplicaServerName -eq $asyncName }
        $a.Change   | Should -Be 'Opened'
        $a.Severity | Should -Be 'Critical'
    }
    It 'waits for two snapshots in a row before opening AsyncSecondaryNotMoving' {
        @($s1.Alerts | Where-Object { $_.RuleName -eq 'AsyncSecondaryNotMoving' -and $_.Change -eq 'Opened' }).Count |
            Should -Be 0
        ($s2.Alerts | Where-Object { $_.RuleName -eq 'AsyncSecondaryNotMoving' -and $_.ReplicaServerName -eq $asyncName }).Change |
            Should -Be 'Opened'
    }
    It 'keeps one open alert per problem while it lasts (no duplicates, no re-alerting)' {
        @($s3.Alerts | Where-Object Change -eq 'Opened').Count | Should -Be 0
        @($s3.Alerts | Where-Object { $_.RuleName -eq 'DatabaseSuspended' -and $_.Change -eq 'Ongoing' }).Count | Should -Be 1
    }
    It 'resolves every alert once the secondary has recovered' {
        $resolved.RuleName | Should -Contain 'DatabaseSuspended'
        $resolved.RuleName | Should -Contain 'AsyncSecondaryNotMoving'
        Get-OpenAlertCount -ReplicaName $asyncName | Should -Be 0
    }
}

Describe 'Alerts: rules are data' {
    BeforeAll {
        # A rule that always breaches: every snapshot takes more than -2 ms
        Invoke-Ctl @"
INSERT aghealth.AlertRule (RuleName, Scope, Metric, Operator, WarnThreshold, CritThreshold, ConsecutiveSnapshots, Description)
VALUES ('pt_SnapshotDuration', 'Ag', 'DurationMs', '>', -2, 1000000, 1, N'Test rule');
"@
    }
    AfterAll {
        Invoke-Ctl @"
DELETE a FROM aghealth.Alert a JOIN aghealth.AlertRule r ON r.RuleId = a.RuleId WHERE r.RuleName = 'pt_SnapshotDuration';
DELETE aghealth.AlertRule WHERE RuleName = 'pt_SnapshotDuration';
"@
    }

    It 'opens an alert from a rule added with an INSERT (no redeploy)' {
        $a = (Invoke-Collect).Alerts | Where-Object RuleName -eq 'pt_SnapshotDuration'
        $a.Change   | Should -Be 'Opened'
        $a.Severity | Should -Be 'Warning'
    }
    It 'escalates to Critical and queues a new notification when the threshold is lowered' {
        # Pretend the notifier already sent the Warning
        Invoke-Ctl @"
UPDATE a SET NotifiedAt = SYSUTCDATETIME()
FROM aghealth.Alert a JOIN aghealth.AlertRule r ON r.RuleId = a.RuleId
WHERE r.RuleName = 'pt_SnapshotDuration' AND a.State = 'Open';
UPDATE aghealth.AlertRule SET CritThreshold = -1 WHERE RuleName = 'pt_SnapshotDuration';
"@
        $a = (Invoke-Collect).Alerts | Where-Object RuleName -eq 'pt_SnapshotDuration'
        $a.Change   | Should -Be 'Escalated'
        $a.Severity | Should -Be 'Critical'
        (Invoke-Ctl "SELECT COUNT(*) AS c FROM aghealth.Alert WHERE AlertId = @id AND NotifiedAt IS NULL;" @{ id = $a.AlertId }).c |
            Should -Be 1
    }
    It 'resolves the alert when the rule is disabled' {
        Invoke-Ctl "UPDATE aghealth.AlertRule SET IsEnabled = 0 WHERE RuleName = 'pt_SnapshotDuration';"
        ((Invoke-Collect).Alerts | Where-Object RuleName -eq 'pt_SnapshotDuration').Change | Should -Be 'Resolved'
    }
}

Describe 'Retention' {
    BeforeAll {
        $old  = (Invoke-Collect).SnapshotId
        $kept = (Invoke-Collect).SnapshotId
        # An open alert pointing at the second snapshot, then age both past the 14-day window
        Invoke-Ctl @"
INSERT aghealth.Alert (RuleId, AgName, ReplicaServerName, Severity, FirstSeenAt, LastSeenAt, OpenSnapshotId, LastSnapshotId, Message)
SELECT TOP (1) RuleId, @ag, 'pt_purge', 'Warning', SYSUTCDATETIME(), SYSUTCDATETIME(), @kept, @kept, N'pt_ retention test'
FROM aghealth.AlertRule ORDER BY RuleId;
UPDATE aghealth.Snapshot SET CollectedAt = DATEADD(DAY, -30, CollectedAt) WHERE SnapshotId IN (@old, @kept);
"@ @{ ag = $AgName; old = $old; kept = $kept }

        # Run as the collector's own account: proves the writer role can purge
        Invoke-DbaQuery @writer -Query 'EXEC aghealth.usp_PurgeHistory;' -EnableException
    }
    AfterAll { Invoke-Ctl "DELETE aghealth.Alert WHERE ReplicaServerName = 'pt_purge';" }

    It 'purges an old snapshot together with its replica and database state' {
        $row = Invoke-Ctl @"
SELECT (SELECT COUNT(*) FROM aghealth.Snapshot      WHERE SnapshotId = @id) AS s,
       (SELECT COUNT(*) FROM aghealth.ReplicaState  WHERE SnapshotId = @id) AS r,
       (SELECT COUNT(*) FROM aghealth.DatabaseState WHERE SnapshotId = @id) AS d;
"@ @{ id = $old }
        $row.s + $row.r + $row.d | Should -Be 0
    }
    It 'keeps an old snapshot that an open alert still points at' {
        (Invoke-Ctl "SELECT COUNT(*) AS c FROM aghealth.Snapshot WHERE SnapshotId = @id;" @{ id = $kept }).c | Should -Be 1
    }
}
