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
    BeforeAll {
        # The rules HealthSchema.sql ships: 11 AG health rules and 2 replica-drift rules.
        # (Object Guard adds its own three when it is installed; the CI lab does not install it.)
        $script:DefaultRules = @('CollectionFailed', 'ReplicaUnreachable', 'ReplicaDisconnected', 'ReplicaNotHealthy',
            'DatabaseSuspended', 'SyncSecondaryNotSynced', 'AsyncSecondaryNotMoving', 'LogSendQueueHigh', 'RedoQueueHigh',
            'EstimatedDataLossHigh', 'EstimatedRecoveryHigh', 'MissingOnSecondary', 'OnlyOnSecondary')
        function Get-DefaultRuleCount {
            (Invoke-Ctl "SELECT COUNT(*) AS c FROM aghealth.AlertRule WHERE RuleName IN ($(($script:DefaultRules | ForEach-Object { "'$_'" }) -join ', '));").c
        }
    }
    It 'ships the 13 default alert rules' {
        Get-DefaultRuleCount | Should -Be 13
    }
    It 'closes alerts only after 2 healthy snapshots by default' {
        (Invoke-Ctl "SELECT COUNT(*) AS c FROM aghealth.AlertRule WHERE RuleName NOT LIKE 'pt[_]%' AND ResolveAfterSnapshots <> 2;").c | Should -Be 0
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
            Get-DefaultRuleCount | Should -Be 13
            (Invoke-Ctl "SELECT COUNT(*) AS c FROM (SELECT RuleName FROM aghealth.AlertRule GROUP BY RuleName HAVING COUNT(*) > 1) d;").c |
                Should -Be 0
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

Describe 'Notifications: exactly once per channel, retried when a channel fails' {
    BeforeAll {
        # A rule that always breaches, so this block controls its own alert from open to resolved
        Invoke-Ctl @"
INSERT aghealth.AlertRule (RuleName, Scope, Metric, Operator, WarnThreshold, CritThreshold, ConsecutiveSnapshots, Description)
VALUES ('pt_Notify', 'Ag', 'DurationMs', '>', -2, 1000000, 1, N'Notification test rule');
"@
        $notify = @{ ControlInstance = $ControlInstance; AgName = $AgName }
        if ($ControlCredential) { $notify.ControlCredential = $ControlCredential }

        function Get-Mine {
            # Events for the test rule only, from a channel's in-memory outbox.
            # The leading comma returns the array as-is: PowerShell would otherwise unroll a single row,
            # and [0] on a bare DataRow reads its first column instead of the first row.
            param($Ch)
            , @($Ch.Sent | ForEach-Object { $_ } | Where-Object RuleName -eq 'pt_Notify')
        }
        function Get-TestAlert {
            Invoke-Ctl @"
SELECT TOP (1) a.AlertId, a.State, a.Severity, a.NotifiedAt, a.ResolvedNotifiedAt
FROM aghealth.Alert a JOIN aghealth.AlertRule r ON r.RuleId = a.RuleId
WHERE r.RuleName = 'pt_Notify' ORDER BY a.AlertId DESC;
"@
        }

        $null = Invoke-Collect                                              # alert opens (Warning)
        $slack1 = New-AgHealthTestChannel -Name pt_Slack -Mode PerEvent
        $email1 = New-AgHealthTestChannel -Name pt_Email -Mode Digest -FailWith 'SMTP is down'
        $run1   = @(Send-AgHealthNotification @notify -Channel $slack1, $email1)
    }
    AfterAll {
        Invoke-Ctl @"
DELETE a FROM aghealth.Alert a JOIN aghealth.AlertRule r ON r.RuleId = a.RuleId WHERE r.RuleName = 'pt_Notify';
DELETE aghealth.AlertRule WHERE RuleName = 'pt_Notify';
"@
    }

    It 'announces a new alert as Opened on the channel that works' {
        $e = Get-Mine $slack1
        $e.Count    | Should -Be 1
        $e[0].Event | Should -Be 'Opened'
        ($run1 | Where-Object { $_.RuleName -eq 'pt_Notify' -and $_.Channel -eq 'pt_Slack' }).Status | Should -Be 'Sent'
    }
    It 'renders a real event as a Slack card with a severity colour bar' {
        $msg = $slack1.Rendered[0].Slack[0] | ConvertFrom-Json
        $msg.attachments[0].color          | Should -Be '#dc6803'          # warning
        $msg.attachments[0].blocks[0].text.text | Should -Match 'WARNING'
        $msg.attachments[0].blocks[0].text.text | Should -Match 'pt_Notify'
        $msg.text                          | Should -Match "WARNING: pt_Notify on $AgName"
    }
    It 'logs the failed channel and keeps the alert pending' {
        $f = $run1 | Where-Object { $_.RuleName -eq 'pt_Notify' -and $_.Channel -eq 'pt_Email' }
        $f.Status | Should -Be 'Failed'
        $f.Error  | Should -Be 'SMTP is down'
        (Get-TestAlert).NotifiedAt | Should -BeOfType [DBNull]
    }
    It 'retries only the failed channel: no duplicate on the one that already succeeded' {
        $slack2 = New-AgHealthTestChannel -Name pt_Slack -Mode PerEvent
        $email2 = New-AgHealthTestChannel -Name pt_Email -Mode Digest
        $null = Send-AgHealthNotification @notify -Channel $slack2, $email2
        (Get-Mine $slack2).Count | Should -Be 0
        (Get-Mine $email2).Count | Should -Be 1
        (Get-TestAlert).NotifiedAt | Should -Not -BeOfType [DBNull]
        (Invoke-Ctl @"
SELECT n.Attempts FROM aghealth.Notification n
WHERE n.AlertId = @id AND n.Channel = 'pt_Email' AND n.EventKey = 'Open:Warning';
"@ @{ id = (Get-TestAlert).AlertId }).Attempts | Should -Be 2
    }
    It 'announces an escalation to Critical on every channel' {
        Invoke-Ctl "UPDATE aghealth.AlertRule SET CritThreshold = -1 WHERE RuleName = 'pt_Notify';"
        $null = Invoke-Collect
        $slack3 = New-AgHealthTestChannel -Name pt_Slack -Mode PerEvent
        $email3 = New-AgHealthTestChannel -Name pt_Email -Mode Digest
        $null = Send-AgHealthNotification @notify -Channel $slack3, $email3
        foreach ($ch in $slack3, $email3) {
            $e = Get-Mine $ch
            $e.Count       | Should -Be 1
            $e[0].Event    | Should -Be 'Escalated'
            $e[0].Severity | Should -Be 'Critical'
        }
    }
    It 'announces the resolution on every channel, then has nothing left to send' {
        Invoke-Ctl "UPDATE aghealth.AlertRule SET IsEnabled = 0 WHERE RuleName = 'pt_Notify';"
        $null = Invoke-Collect
        $slack4 = New-AgHealthTestChannel -Name pt_Slack -Mode PerEvent
        $email4 = New-AgHealthTestChannel -Name pt_Email -Mode Digest
        $null = Send-AgHealthNotification @notify -Channel $slack4, $email4
        (Get-Mine $slack4)[0].Event | Should -Be 'Resolved'
        (Get-Mine $email4)[0].Event | Should -Be 'Resolved'
        (Get-TestAlert).ResolvedNotifiedAt | Should -Not -BeOfType [DBNull]

        $slack5 = New-AgHealthTestChannel -Name pt_Slack -Mode PerEvent
        $null = Send-AgHealthNotification @notify -Channel $slack5, (New-AgHealthTestChannel -Name pt_Email -Mode Digest)
        (Get-Mine $slack5).Count | Should -Be 0
    }

    It 'renders every default rule for Slack and email (no rule breaks the formatter)' {
        $rules  = Invoke-Ctl "SELECT RuleName, Metric, Operator, ExpectedValue, WarnThreshold, CritThreshold, Description, Runbook FROM aghealth.AlertRule WHERE RuleName NOT LIKE 'pt[_]%';"
        $now    = [datetime]::UtcNow
        $events = foreach ($r in $rules) {
            [pscustomobject]@{ AlertId = 1; AgName = $AgName; ReplicaServerName = 'replica'; DatabaseName = 'db'
                               Severity = 'Critical'; State = 'Open'; RuleName = $r.RuleName; LastValue = '5'; Message = 'm'
                               FirstSeenAt = $now.AddMinutes(-3); LastSeenAt = $now; ResolvedAt = [DBNull]::Value
                               Metric = $r.Metric; Operator = $r.Operator; ExpectedValue = $r.ExpectedValue
                               WarnThreshold = $r.WarnThreshold; CritThreshold = $r.CritThreshold
                               Description = $r.Description; Runbook = $r.Runbook; EventKey = 'Open:Critical'; Event = 'Opened' }
        }
        $brand   = New-AgHealthBrand -Name 'pt Brand' -Tagline 'pt tagline' -Url https://example.com -Contact ops@example.com
        $preview = New-AgHealthTestChannel -Mode Digest -Brand $brand
        InModuleScope -ModuleName AgHealth -Parameters @{ Ch = $preview; Ev = @($events) } -ScriptBlock {
            param($Ch, $Ev) Send-AgHealthChannelMessage $Ch $Ev
        }
        $r = $preview.Rendered[0]
        $n = @($rules).Count
        $n | Should -BeGreaterOrEqual 13
        $r.Slack.Count | Should -Be $n
        foreach ($json in $r.Slack) { @(($json | ConvertFrom-Json).attachments[0].blocks).Count | Should -BeGreaterThan 2 }
        $r.Email.Subject | Should -Be "[AG $AgName] $n Critical"
        $r.Email.Body    | Should -Match 'What to check'
        $r.Email.Body    | Should -Match "$n Critical"
        $r.Email.Body    | Should -Match 'pt Brand'                   # company in the header and footer
        $r.Email.Body    | Should -Match 'ops@example.com'
        ($r.Slack[0] | ConvertFrom-Json).attachments[0].blocks[-1].elements[0].text | Should -Match 'pt Brand'
    }
}

Describe 'Notifications: one broken channel never blocks or mislabels another' {
    BeforeAll {
        Invoke-Ctl @"
INSERT aghealth.AlertRule (RuleName, Scope, Metric, Operator, WarnThreshold, CritThreshold, ConsecutiveSnapshots, Description)
VALUES ('pt_Outage', 'Ag', 'DurationMs', '>', -2, 1000000, 1, N'Channel outage test rule');
"@
        $notify = @{ ControlInstance = $ControlInstance; AgName = $AgName }
        if ($ControlCredential) { $notify.ControlCredential = $ControlCredential }
        function Get-Outage { param($Rows) @($Rows | Where-Object RuleName -eq 'pt_Outage') }

        $null = Invoke-Collect                                                     # opens
        $run1 = Get-Outage (Send-AgHealthNotification @notify -Channel (New-AgHealthTestChannel -Name pt_Slack), (New-AgHealthTestChannel -Name pt_Email -Mode Digest -FailWith 'SMTP AUTH disabled'))
        $run2 = Get-Outage (Send-AgHealthNotification @notify -Channel (New-AgHealthTestChannel -Name pt_Slack), (New-AgHealthTestChannel -Name pt_Email -Mode Digest -FailWith 'SMTP AUTH disabled'))

        Invoke-Ctl "UPDATE aghealth.AlertRule SET IsEnabled = 0 WHERE RuleName = 'pt_Outage';"
        $null = Invoke-Collect                                                     # resolves
        $slack3 = New-AgHealthTestChannel -Name pt_Slack
        $email3 = New-AgHealthTestChannel -Name pt_Email -Mode Digest              # email works again
        $run3 = Get-Outage (Send-AgHealthNotification @notify -Channel $slack3, $email3)
    }
    AfterAll {
        Invoke-Ctl @"
DELETE a FROM aghealth.Alert a JOIN aghealth.AlertRule r ON r.RuleId = a.RuleId WHERE r.RuleName = 'pt_Outage';
DELETE aghealth.AlertRule WHERE RuleName = 'pt_Outage';
"@
    }

    It 'labels a retry on the broken channel as Opened, not Escalated' {
        ($run2 | Where-Object Channel -eq 'pt_Email').Event  | Should -Be 'Opened'
        ($run2 | Where-Object Channel -eq 'pt_Email').Status | Should -Be 'Failed'
        @($run2 | Where-Object Channel -eq 'pt_Slack').Count | Should -Be 0      # no duplicate on the working channel
    }
    It 'still delivers the resolution to the channel that announced the alert' {
        ($run3 | Where-Object Channel -eq 'pt_Slack').Event  | Should -Be 'Resolved'
        ($run3 | Where-Object Channel -eq 'pt_Slack').Status | Should -Be 'Sent'
    }
    It 'sends no resolution to a channel that never announced the alert' {
        @($run3 | Where-Object Channel -eq 'pt_Email').Count | Should -Be 0
        @($email3.Sent).Count | Should -Be 0
    }
}

Describe 'Reminders: an alert that stays open is announced again, on schedule, then stops' {
    BeforeAll {
        # Always breaches; reminders every 60 minutes, at most 2 (a per-rule override of the severity policy)
        Invoke-Ctl @"
INSERT aghealth.AlertRule (RuleName, Scope, Metric, Operator, WarnThreshold, CritThreshold, ConsecutiveSnapshots, RepeatMinutes, MaxRepeats, Description)
VALUES ('pt_Remind', 'Ag', 'DurationMs', '>', -2, 1000000, 1, 60, 2, N'Reminder test rule');
"@
        $notify = @{ ControlInstance = $ControlInstance; AgName = $AgName }
        if ($ControlCredential) { $notify.ControlCredential = $ControlCredential }

        function Send-Test {
            # One notifier run on a fresh pair of channels; returns this rule's events and the email render
            $slack = New-AgHealthTestChannel -Name pt_RSlack
            $email = New-AgHealthTestChannel -Name pt_REmail -Mode Digest
            $rows  = @(Send-AgHealthNotification @notify -Channel $slack, $email | Where-Object RuleName -eq 'pt_Remind')
            [pscustomobject]@{ Rows = $rows; Slack = $slack; Email = $email }
        }
        function Move-ClockBack {
            # Pretend the last notice (and last reminder) happened 61 minutes ago
            Invoke-Ctl @"
UPDATE a SET NotifiedAt = DATEADD(MINUTE, -61, NotifiedAt),
             LastRemindedAt = DATEADD(MINUTE, -61, LastRemindedAt)
FROM aghealth.Alert a JOIN aghealth.AlertRule r ON r.RuleId = a.RuleId
WHERE r.RuleName = 'pt_Remind' AND a.State = 'Open';
"@
        }

        $null    = Invoke-Collect                     # opens (Warning)
        $opened  = Send-Test
        $tooSoon = Send-Test                          # nothing due yet
        Move-ClockBack
        $first   = Send-Test                          # reminder 1 of 2
        $again   = Send-Test                          # not due again yet
        Move-ClockBack
        $second  = Send-Test                          # reminder 2 of 2
        Move-ClockBack
        $capped  = Send-Test                          # the cap holds: nothing

        Invoke-Ctl "UPDATE aghealth.AlertRule SET IsEnabled = 0 WHERE RuleName = 'pt_Remind';"
        $null     = Invoke-Collect                    # resolves
        $resolved = Send-Test
    }
    AfterAll {
        Invoke-Ctl @"
DELETE a FROM aghealth.Alert a JOIN aghealth.AlertRule r ON r.RuleId = a.RuleId WHERE r.RuleName = 'pt_Remind';
DELETE aghealth.AlertRule WHERE RuleName = 'pt_Remind';
"@
    }

    It 'announces the alert once, then stays quiet until a reminder is due' {
        @($opened.Rows | Where-Object Event -eq 'Opened').Count | Should -Be 2     # Slack and email
        $tooSoon.Rows.Count | Should -Be 0
    }
    It 'sends reminder 1 on every channel once the interval has passed' {
        @($first.Rows | Where-Object { $_.Event -eq 'Reminder' -and $_.Status -eq 'Sent' }).Count | Should -Be 2
        $again.Rows.Count | Should -Be 0
    }
    It 'labels a reminder clearly in Slack and email' {
        $card = $first.Slack.Rendered[0].Slack[0] | ConvertFrom-Json
        $card.attachments[0].blocks[0].text.text | Should -Match 'REMINDER'
        $card.attachments[0].blocks[1].fields[3].text | Should -Match 'Reminder 1 of 2'
        $first.Email.Rendered[0].Email.Subject | Should -Be "[AG $AgName] Still open: 1 Warning"
    }
    It 'sends reminder 2, then stops at the cap' {
        @($second.Rows | Where-Object Event -eq 'Reminder').Count | Should -Be 2
        $second.Slack.Rendered[0].Slack[0] | Should -Match 'Reminder 2 of 2'
        $capped.Rows.Count | Should -Be 0
    }
    It 'still announces the resolution after the reminders' {
        @($resolved.Rows | Where-Object { $_.Event -eq 'Resolved' -and $_.Status -eq 'Sent' }).Count | Should -Be 2
    }
}

Describe 'Monitor runner (the scheduled pass)' {
    BeforeAll {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('aghealth-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $tmp
        $cfgPath = Join-Path $tmp 'monitor.json'
        # No channels in this config: the runner test must not consume the lab's real pending notifications
        @{ Replica = @($Replica); AgName = $AgName; ControlInstance = $ControlInstance; TrustServerCertificate = $true } |
            ConvertTo-Json | Set-Content -Path $cfgPath
        $runner  = "$PSScriptRoot/../ops/Invoke-AgHealthMonitor.ps1"
        $runArgs = @{ ConfigPath = $cfgPath; LogDirectory = $tmp; DetectCredential = $DetectCredential }
        if ($ControlCredential) { $runArgs.ControlCredential = $ControlCredential }
        function Get-MaxSnapshot { (Invoke-Ctl 'SELECT ISNULL(MAX(SnapshotId), 0) AS m FROM aghealth.Snapshot;').m }
        function Get-RunLog { Get-Content -Path (Get-ChildItem $tmp -Filter 'monitor-*.log' | Select-Object -First 1).FullName }

        $before = Get-MaxSnapshot
        & $runner @runArgs
        $firstExit = $LASTEXITCODE
        $after = Get-MaxSnapshot
    }
    AfterAll { Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'takes and stores a snapshot, and exits 0' {
        $firstExit | Should -Be 0
        $after     | Should -BeGreaterThan $before
    }
    It 'logs the run' {
        (Get-RunLog) -join "`n" | Should -Match "${AgName}: snapshot \d+ Succeeded"
    }
    It 'skips instead of overlapping while a run is still active' {
        $agTag = $AgName -replace '[^A-Za-z0-9_.-]', '_'
        $held  = [IO.File]::Open((Join-Path $tmp "$agTag.lock"), 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            $mark = Get-MaxSnapshot
            & $runner @runArgs
            $LASTEXITCODE        | Should -Be 0
            Get-MaxSnapshot      | Should -Be $mark            # nothing collected
            (Get-RunLog) -join "`n" | Should -Match 'still active; skipped'
        }
        finally { $held.Dispose() }
    }
    It 'reports a broken configuration with exit code 3' {
        $bad = Join-Path $tmp 'bad.json'
        @{ Replica = @($Replica) } | ConvertTo-Json | Set-Content -Path $bad
        & $runner -ConfigPath $bad -LogDirectory $tmp
        $LASTEXITCODE | Should -Be 3
        (Get-RunLog) -join "`n" | Should -Match "'AgName' is missing"
    }
}

Describe 'Secrets: machine store for no-password background tasks' -Skip:(-not $IsWindows) {
    BeforeAll {
        $name = 'pt_Secret_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $cred = [pscredential]::new('pt_user@example.com', (ConvertTo-SecureString 'Pt-S3cret!value' -AsPlainText -Force))
        Save-AgHealthSecret -Name $name -Credential $cred -Scope Machine
        $path = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "AlwaysOnCommandCenter\secrets\machine\$name.json"
    }
    AfterAll { Remove-Item -Path $path -Force -ErrorAction SilentlyContinue }

    It 'reads back the same user name and password' {
        $back = Get-AgHealthSecret $name -Scope Machine
        $back.UserName | Should -Be 'pt_user@example.com'
        $back.GetNetworkCredential().Password | Should -Be 'Pt-S3cret!value'
    }
    It 'never writes the password in plain text' {
        Get-Content -Path $path -Raw | Should -Not -Match 'Pt-S3cret'
    }
    It 'restricts the file to the current account, with no inherited permissions' {
        $acl = Get-Acl -Path $path
        $acl.AreAccessRulesProtected | Should -BeTrue
        @($acl.Access).Count | Should -Be 1
        @($acl.Access)[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value |
            Should -Be ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    }
}
