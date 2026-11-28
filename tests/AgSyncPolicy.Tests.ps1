<#
    AG Sync automatic-sync policy: what may be applied without a person, and what must wait for one.
    Pure unit tests (no SQL Server needed): they certify the decision for every case the policy has to get right.

    Run:  Invoke-Pester ./tests/AgSyncPolicy.Tests.ps1 -Output Detailed

    Author: Louis Achungo | SQL IT Tech Solutions
#>
BeforeAll {
    $module = @("$PSScriptRoot/../AgSync.psm1", "$PSScriptRoot/../AgSync/AgSync.psm1") | Where-Object { Test-Path $_ } | Select-Object -First 1
    Import-Module $module -Force

    # A finding as Compare-AgSyncInventory produces it, for a login on the primary
    function New-TestLoginFinding {
        param([string] $Name = 'app_login', [string] $Roles = '', [string] $Permissions = '',
              [string] $DriftType = 'Missing', [string[]] $Property = @(), [string] $Sid = '0x01')
        [pscustomobject]@{
            ObjectType = 'Login'; ObjectName = $Name; SourceReplica = 'agsql1'; TargetReplica = 'agsql2'
            DriftType = $DriftType; Property = $Property; Detail = ''
            SourceObject = [pscustomobject]@{ name = $Name; type_desc = 'SQL_LOGIN'; sid = $Sid; server_roles = $Roles
                                              server_permissions = $Permissions; is_disabled = $false }
            TargetObject = $null
        }
    }
    function Test-Policy { param($Finding) InModuleScope AgSync -Parameters @{ F = $Finding } { param($F) Test-AgSyncAutoPolicy $F $null } }
    function Get-Fp      { param($Finding) InModuleScope AgSync -Parameters @{ F = $Finding } { param($F) Get-AgSyncFingerprint $F } }
}

Describe 'Automatic sync: copied without a person' {
    It 'an ordinary application login (no server roles, no server permissions)' {
        Test-Policy (New-TestLoginFinding) | Should -BeNullOrEmpty
    }
    It 'a login with read-only server permissions (VIEW SERVER STATE, VIEW ANY DEFINITION)' {
        Test-Policy (New-TestLoginFinding -Permissions 'GRANT VIEW ANY DEFINITION,GRANT VIEW SERVER STATE') | Should -BeNullOrEmpty
    }
    It 'a login in the built-in read-only server roles' {
        Test-Policy (New-TestLoginFinding -Roles '##MS_ServerStateReader##,##MS_DefinitionReader##') | Should -BeNullOrEmpty
    }
    It 'a login whose only server permission is a DENY (it only restricts)' {
        Test-Policy (New-TestLoginFinding -Permissions 'DENY VIEW ANY DATABASE') | Should -BeNullOrEmpty
    }
    It 'a password, disabled-state or default-database change on an ordinary login' {
        Test-Policy (New-TestLoginFinding -DriftType Different -Property 'password_hash', 'is_disabled') | Should -BeNullOrEmpty
    }
}

Describe 'Automatic sync: waits for DBA approval' {
    It 'sysadmin' {
        Test-Policy (New-TestLoginFinding -Roles 'sysadmin') | Should -BeLike 'elevated login (sysadmin)'
    }
    It 'securityadmin' {
        Test-Policy (New-TestLoginFinding -Roles 'securityadmin') | Should -BeLike 'elevated login*securityadmin*'
    }
    It 'CONTROL SERVER granted directly' {
        Test-Policy (New-TestLoginFinding -Permissions 'GRANT CONTROL SERVER') | Should -BeLike '*CONTROL SERVER*'
    }
    It 'a custom server role (could hold CONTROL SERVER: unknown roles are treated as elevated)' {
        Test-Policy (New-TestLoginFinding -Roles 'app_ops_role') | Should -BeLike '*app_ops_role*'
    }
    It 'any permission granted WITH GRANT OPTION' {
        Test-Policy (New-TestLoginFinding -Permissions 'GRANT_WITH_GRANT_OPTION VIEW SERVER STATE') | Should -BeLike 'elevated login*'
    }
    It 'any other server permission not on the read-only list (e.g. ALTER ANY LOGIN)' {
        Test-Policy (New-TestLoginFinding -Permissions 'GRANT ALTER ANY LOGIN') | Should -BeLike '*ALTER ANY LOGIN*'
    }
    It 'the same login name with a different SID (fixing it drops and recreates the login)' {
        Test-Policy (New-TestLoginFinding -DriftType Different -Property 'sid') | Should -BeLike 'SID differs*'
    }
    It 'an Agent job (it runs as its owner, often sa)' {
        $job = [pscustomobject]@{ ObjectType = 'AgentJob'; ObjectName = 'Nightly ETL'; DriftType = 'Missing'; Property = @()
                                  SourceObject = [pscustomobject]@{ name = 'Nightly ETL'; owner_name = 'sa' } }
        Test-Policy $job | Should -BeLike 'Agent jobs run as their owner*'
    }
    It 'adding a database to the AG' {
        $db = [pscustomobject]@{ ObjectType = 'Database'; ObjectName = 'NewDb'; DriftType = 'NotInAg'; Property = @()
                                 SourceObject = [pscustomobject]@{ name = 'NewDb'; recovery_model_desc = 'FULL' } }
        Test-Policy $db | Should -BeLike 'adding a database*'
    }
}

Describe 'Approvals are bound to exactly what was reviewed' {
    It 'the same definition always gives the same fingerprint' {
        Get-Fp (New-TestLoginFinding -Roles 'sysadmin') | Should -Be (Get-Fp (New-TestLoginFinding -Roles 'sysadmin'))
    }
    It 'gaining a server role after approval changes the fingerprint (the approval no longer applies)' {
        Get-Fp (New-TestLoginFinding -Roles 'sysadmin') | Should -Not -Be (Get-Fp (New-TestLoginFinding -Roles 'securityadmin,sysadmin'))
    }
    It 'a different SID changes the fingerprint' {
        Get-Fp (New-TestLoginFinding -Sid '0x01') | Should -Not -Be (Get-Fp (New-TestLoginFinding -Sid '0x02'))
    }
    It 'a new server permission changes the fingerprint' {
        Get-Fp (New-TestLoginFinding) | Should -Not -Be (Get-Fp (New-TestLoginFinding -Permissions 'GRANT CONTROL SERVER'))
    }
    It 'is a SHA-256 value' {
        Get-Fp (New-TestLoginFinding) | Should -Match '^0x[0-9A-F]{64}$'
    }
}
