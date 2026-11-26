#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    AgSync integration tests. They run against a real Availability Group (the Docker lab in /lab).

    Each scenario builds its own drift with the admin credential, runs AgSync with the
    least-privilege accounts, asserts the outcome, then cleans up after itself.
    All test objects are prefixed "pt_" / "pt - ".

    Run:
      $c = New-PesterContainer -Path .\tests\AgSync.Tests.ps1 -Data @{
               Replica = $replicas; AgName = 'aglab_ag'; ControlInstance = $ctl
               AdminCredential = $sa; ApplyCredential = $app; DetectCredential = $det }
      Invoke-Pester -Container $c -Output Detailed
#>
param(
    [Parameter(Mandatory)] [string[]]     $Replica,
    [Parameter(Mandatory)] [string]       $AgName,
    [Parameter(Mandatory)] [string]       $ControlInstance,
    [Parameter(Mandatory)] [pscredential] $AdminCredential,    # test setup and cleanup only
    [Parameter(Mandatory)] [pscredential] $ApplyCredential,
    [Parameter(Mandatory)] [pscredential] $DetectCredential,
    [string] $AgDatabase = 'SyncLab'                           # a database in the AG, used by job guards
)

BeforeAll {
    Import-Module "$PSScriptRoot/../AgSync.psm1" -Force

    $agApply  = @{ Replica = $Replica; AgName = $AgName; SqlCredential = $ApplyCredential;  ControlInstance = $ControlInstance }
    $agDetect = @{ Replica = $Replica; AgName = $AgName; SqlCredential = $DetectCredential; ControlInstance = $ControlInstance }

    function Invoke-Admin {
        param([string] $Instance, [string] $Query)
        Invoke-DbaQuery -SqlInstance $Instance -SqlCredential $AdminCredential -Query $Query -EnableException
    }
    function Invoke-AdminAll {
        param([string] $Query)
        foreach ($r in $Replica) { Invoke-Admin $r $Query }
    }
    function Get-Sid {
        param([string] $Instance, [string] $Login)
        (Invoke-Admin $Instance "SELECT ISNULL(CONVERT(varchar(100), SUSER_SID(N'$Login'), 1), '') AS s;").s
    }
    function Get-PermissionCount {
        param([string] $Instance, [string] $Login, [string] $Permission)
        (Invoke-Admin $Instance @"
SELECT COUNT(*) AS c FROM sys.server_permissions p
JOIN sys.server_principals sp ON sp.principal_id = p.grantee_principal_id
WHERE sp.name = N'$Login' AND p.permission_name = N'$Permission' AND p.state_desc = 'GRANT';
"@).c
    }
    function Test-JobExists {
        param([string] $Instance, [string] $Job)
        [bool](Invoke-Admin $Instance "SELECT COUNT(*) AS c FROM msdb.dbo.sysjobs WHERE name = N'$Job';").c
    }
    function Remove-TestLogin {
        param([string] $Name)
        Invoke-AdminAll "IF SUSER_ID(N'$Name') IS NOT NULL DROP LOGIN [$Name];"
    }
    function Remove-TestJob {
        param([string] $Name)
        Invoke-AdminAll "IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'$Name') EXEC msdb.dbo.sp_delete_job @job_name = N'$Name';"
    }
    function New-TestJob {
        param([string] $Instance, [string] $Name, [string] $Command)
        $c = $Command.Replace("'", "''")
        Invoke-Admin $Instance @"
EXEC msdb.dbo.sp_add_job         @job_name = N'$Name', @owner_login_name = N'sa', @enabled = 1;
EXEC msdb.dbo.sp_add_jobstep     @job_name = N'$Name', @step_name = N'Run', @subsystem = N'TSQL',
                                 @database_name = N'master', @command = N'$c';
EXEC msdb.dbo.sp_add_jobschedule @job_name = N'$Name', @name = N'Nightly 01:00',
                                 @freq_type = 4, @freq_interval = 1, @active_start_time = 10000;
EXEC msdb.dbo.sp_add_jobserver   @job_name = N'$Name';
"@
    }

    # Current topology, worked out the same way the tool does (never assume replica[0] is primary)
    $roles = foreach ($r in $Replica) {
        $row = Invoke-Admin $r @"
SELECT ars.role_desc FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_groups ag ON ag.group_id = ars.group_id
WHERE ars.is_local = 1 AND ag.name = N'$AgName';
"@
        [pscustomobject]@{ Instance = $r; Role = $row.role_desc }
    }
    $prim = @($roles | Where-Object Role -eq 'PRIMARY').Instance
    $secs = @($roles | Where-Object Role -eq 'SECONDARY' | ForEach-Object Instance)

    $guard = "IF ISNULL(sys.fn_hadr_is_primary_replica(N'$AgDatabase'), 0) <> 1 BEGIN PRINT 'Not primary for $AgDatabase - skipping.'; RETURN; END;`n"
    $pw    = 'Pt_Lab_2026!x'
}

Describe 'Topology' {
    It 'finds exactly one primary and at least one secondary' {
        @($prim).Count | Should -Be 1
        $secs.Count    | Should -BeGreaterThan 0
    }
}

Describe 'Login sync' {

    Context 'A login that exists only on the primary' {
        BeforeAll {
            $name = 'pt_missing'
            Remove-TestLogin $name
            Invoke-Admin $prim "CREATE LOGIN [$name] WITH PASSWORD = '$pw'; GRANT VIEW SERVER STATE TO [$name];"
        }
        AfterAll { Remove-TestLogin $name }

        It 'is detected as Missing on every secondary' {
            $d = @(Get-AgSyncDrift @agApply -ObjectType Login | Where-Object ObjectName -eq $name)
            $d.Count | Should -Be $secs.Count
            $d.DriftType | Sort-Object -Unique | Should -Be 'Missing'
        }
        It 'is applied to every secondary' {
            $r = @(Invoke-AgSync @agApply -ObjectType Login -Mode Apply | Where-Object ObjectName -eq $name)
            $r.Action | Sort-Object -Unique | Should -Be 'Applied'
        }
        It 'has the same SID on every replica' {
            $sids = foreach ($r in $Replica) { Get-Sid $r $name }
            @($sids | Sort-Object -Unique).Count | Should -Be 1
        }
        It 'carries its server-level permission' {
            foreach ($s in $secs) { Get-PermissionCount $s $name 'VIEW SERVER STATE' | Should -Be 1 }
        }
        It 'accepts the original password on every secondary' {
            $cred = New-Object pscredential $name, (ConvertTo-SecureString $pw -AsPlainText -Force)
            foreach ($s in $secs) {
                (Invoke-DbaQuery -SqlInstance $s -SqlCredential $cred -Query 'SELECT SUSER_SNAME() AS n;' -EnableException).n |
                    Should -Be $name
            }
        }
        It 'leaves no drift behind' {
            Get-AgSyncDrift @agApply -ObjectType Login | Where-Object ObjectName -eq $name | Should -BeNullOrEmpty
        }
    }

    Context 'A login with the same name but a different SID on a secondary' {
        BeforeAll {
            $name = 'pt_sid'
            Remove-TestLogin $name
            Invoke-Admin $prim    "CREATE LOGIN [$name] WITH PASSWORD = '$pw';"
            Invoke-Admin $secs[0] "CREATE LOGIN [$name] WITH PASSWORD = '$pw';"    # new SID: users would orphan
        }
        AfterAll { Remove-TestLogin $name }

        It 'is detected as Different with a SID mismatch' {
            $d = Get-AgSyncDrift @agApply -ObjectType Login |
                 Where-Object { $_.ObjectName -eq $name -and $_.DriftType -eq 'Different' }
            $d.Property | Should -Contain 'sid'
        }
        It 'is rebuilt with the primary SID' {
            Invoke-AgSync @agApply -ObjectType Login -Mode Apply | Out-Null
            Get-Sid $secs[0] $name | Should -Be (Get-Sid $prim $name)
        }
    }

    Context 'A permission revoked on one secondary' {
        BeforeAll {
            $name = 'pt_perm'
            Remove-TestLogin $name
            Invoke-Admin $prim "CREATE LOGIN [$name] WITH PASSWORD = '$pw'; GRANT VIEW ANY DEFINITION TO [$name];"
            Invoke-AgSync @agApply -ObjectType Login -Mode Apply | Out-Null
            Invoke-Admin $secs[0] "REVOKE VIEW ANY DEFINITION FROM [$name];"
        }
        AfterAll { Remove-TestLogin $name }

        It 'is detected as server_permissions drift' {
            $d = Get-AgSyncDrift @agApply -ObjectType Login |
                 Where-Object { $_.ObjectName -eq $name -and $_.DriftType -eq 'Different' }
            $d.Property | Should -Contain 'server_permissions'
        }
        It 'is granted back by Apply' {
            Invoke-AgSync @agApply -ObjectType Login -Mode Apply | Out-Null
            Get-PermissionCount $secs[0] $name 'VIEW ANY DEFINITION' | Should -Be 1
        }
    }

    Context 'A login that exists only on a secondary (possible drop)' {
        BeforeAll {
            $name = 'pt_extra'
            Remove-TestLogin $name
            Invoke-Admin $secs[-1] "CREATE LOGIN [$name] WITH PASSWORD = '$pw';"
        }
        AfterAll { Remove-TestLogin $name }

        It 'is reported as ExtraOnTarget and AlertOnly' {
            $r = Invoke-AgSync @agApply -ObjectType Login -Mode Apply | Where-Object ObjectName -eq $name
            $r.DriftType | Should -Be 'ExtraOnTarget'
            $r.Action    | Should -Be 'AlertOnly'
        }
        It 'is never dropped automatically' {
            Get-Sid $secs[-1] $name | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Agent job sync' {

    Context 'A job with a primary-replica guard' {
        BeforeAll {
            $job = 'pt - guarded'
            Remove-TestJob $job
            New-TestJob $prim $job ($guard + 'SELECT 1;')
        }
        AfterAll { Remove-TestJob $job }

        It 'is copied to every secondary' {
            Invoke-AgSync @agApply -ObjectType AgentJob -Mode Apply | Out-Null
            foreach ($s in $secs) { Test-JobExists $s $job | Should -BeTrue }
        }
        It 'runs on a secondary without doing work or failing' {
            Start-DbaAgentJob -SqlInstance $secs[0] -SqlCredential $AdminCredential -Job $job -Wait | Out-Null
            $h = Invoke-Admin $secs[0] @"
SELECT TOP (1) h.run_status, h.message FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE j.name = N'$job' AND h.step_id = 1 ORDER BY h.instance_id DESC;
"@
            $h.run_status | Should -Be 1
            $h.message    | Should -BeLike '*skipping*'
        }
    }

    Context 'A job without a guard' {
        BeforeAll {
            $job = 'pt - unguarded'
            Remove-TestJob $job
            New-TestJob $prim $job 'SELECT 1;'
        }
        AfterAll { Remove-TestJob $job }

        It 'is flagged NotRoleAware' {
            Get-AgSyncDrift @agApply -ObjectType AgentJob |
                Where-Object { $_.ObjectName -eq $job -and $_.DriftType -eq 'NotRoleAware' } | Should -Not -BeNullOrEmpty
        }
        It 'is skipped by Apply' {
            $r = @(Invoke-AgSync @agApply -ObjectType AgentJob -Mode Apply |
                   Where-Object { $_.ObjectName -eq $job -and $_.DriftType -eq 'Missing' })
            $r.Action | Sort-Object -Unique | Should -Be 'Skipped'
        }
        It 'never reaches a secondary' {
            foreach ($s in $secs) { Test-JobExists $s $job | Should -BeFalse }
        }
    }
}

Describe 'Privilege separation' {
    It 'refuses Apply with the detect account' {
        { Invoke-AgSync @agDetect -Mode Apply } | Should -Throw '*Apply refused*'
    }
    It 'warns that password hashes were not checked with the detect account' {
        $out = Get-AgSyncDrift @agDetect -ObjectType Login 3>&1
        @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -BeGreaterThan 0
    }
    It 'can read Agent job drift with the detect account (msdb grants in place)' {
        { Get-AgSyncDrift @agDetect -ObjectType AgentJob } | Should -Not -Throw
    }
}

Describe 'Audit trail' {
    It 'logs the latest run as completed' {
        $run = Invoke-DbaQuery -SqlInstance $ControlInstance -Database AgSyncControl -EnableException `
                               -Query 'SELECT TOP (1) Status, EndedAt FROM agsync.SyncRun ORDER BY RunId DESC;'
        $run.Status  | Should -Be 'Succeeded'
        $run.EndedAt | Should -Not -BeNullOrEmpty
    }
}
