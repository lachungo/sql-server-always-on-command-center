<#
.SYNOPSIS
    Schedules the AG health monitor in Windows Task Scheduler: one pass every minute, as the current user.

.DESCRIPTION
    Writes the monitor's configuration (no secrets: only the names of secrets saved with Save-AgHealthSecret)
    and registers a task that runs ops/Invoke-AgHealthMonitor.ps1 with it.

    - Runs as you: the saved secrets are encrypted for your Windows profile, so the task must run as the same user.
    - With -WindowsCredential it runs in the background ("whether user is logged on or not"): no window, and it
      keeps running when you lock the screen or sign out. Windows stores that sign-in, encrypted, for the task.
      Without it, the task runs only while you are signed in, and a console window briefly shows each minute.
    - A plain pwsh -File launch, without -ExecutionPolicy Bypass or a hidden console host: antivirus rightly treats
      hidden, policy-bypassing PowerShell as suspicious, so the monitor does nothing that looks like that.
    - Never overlaps: the task ignores a new start while one is running, and the runner has its own lock.

.EXAMPLE
    # Save the accounts once (the detect and control logins the lab created)
    Save-AgHealthSecret -Name AgDetect  -Credential $det
    Save-AgHealthSecret -Name AgControl -Credential $ctlCred

    ./ops/Register-AgHealthMonitor.ps1 -Replica $lab.Replica -AgName $lab.AgName -ControlInstance $lab.ControlInstance `
        -TrustServerCertificate -SlackSecret SlackWebhook -EmailSecret Gmail -EmailTo info@sql-it-techsolutions.com `
        -Brand @{ Name = 'SQL-IT-Tech Solutions'; SourceName = 'SQL-IT-TECHSOLUTIONS' } `
        -WindowsCredential (Get-Credential "$env:USERDOMAIN\$env:USERNAME") -RunNow

.EXAMPLE
    ./ops/Register-AgHealthMonitor.ps1 -AgName aglab_ag -Unregister

    Author: Louis Achungo | SQL IT Tech Solutions
#>
[CmdletBinding(DefaultParameterSetName = 'Register')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Register')] [string[]] $Replica,
    [Parameter(Mandatory)] [string] $AgName,
    [Parameter(Mandatory, ParameterSetName = 'Register')] [string] $ControlInstance,
    [Parameter(ParameterSetName = 'Register')] [string] $ControlDatabase = 'AgSyncControl',
    [Parameter(ParameterSetName = 'Register')] [string] $DetectSecret = 'AgDetect',
    [Parameter(ParameterSetName = 'Register')] [string] $ControlSecret = 'AgControl',
    [Parameter(ParameterSetName = 'Register')] [string] $SlackSecret,       # e.g. SlackWebhook; omit for no Slack
    [Parameter(ParameterSetName = 'Register')] [string] $EmailSecret,       # e.g. Gmail or Office365; omit for no email
    [Parameter(ParameterSetName = 'Register')] [string[]] $EmailTo,
    [Parameter(ParameterSetName = 'Register')] [string] $SmtpServer = 'smtp.gmail.com',
    [Parameter(ParameterSetName = 'Register')] [int] $SmtpPort = 587,
    [Parameter(ParameterSetName = 'Register')] [string] $ReplyTo,
    [Parameter(ParameterSetName = 'Register')] [hashtable] $Brand,          # New-AgHealthBrand parameters
    [Parameter(ParameterSetName = 'Register')] [switch] $TrustServerCertificate,
    [Parameter(ParameterSetName = 'Register')] [ValidateRange(1, 60)] [int] $EveryMinutes = 1,
    [Parameter(ParameterSetName = 'Register')] [pscredential] $WindowsCredential,   # your Windows sign-in: run in the background
    [Parameter(ParameterSetName = 'Register')] [switch] $RunNow,
    [Parameter(Mandatory, ParameterSetName = 'Unregister')] [switch] $Unregister
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') { throw 'Task Scheduler registration is Windows only.' }

$taskPath = '\AlwaysOnCommandCenter\'
$taskName = "AG Health Monitor - $AgName"
$appRoot  = Join-Path $env:LOCALAPPDATA 'AlwaysOnCommandCenter'
$cfgPath  = Join-Path $appRoot ("monitor-{0}.json" -f ($AgName -replace '[^A-Za-z0-9_.-]', '_'))

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false
    Write-Host "Removed '$taskName'. Its configuration stays at $cfgPath."
    return
}

# Every secret the monitor will need must exist now, not fail at 3 AM
Import-Module (Join-Path $PSScriptRoot '../AgHealth/AgHealth.psm1') -Force
$needed = @($DetectSecret, $ControlSecret, $SlackSecret, $EmailSecret) | Where-Object { $_ }
foreach ($name in $needed) { $null = Get-AgHealthSecret $name }
if ($EmailSecret -and -not $EmailTo) { throw '-EmailTo is required with -EmailSecret.' }

# Configuration: names of secrets only, never their values
$cfg = [ordered]@{
    Replica                = @($Replica)
    AgName                 = $AgName
    ControlInstance        = $ControlInstance
    ControlDatabase        = $ControlDatabase
    DetectSecret           = $DetectSecret
    ControlSecret          = $ControlSecret
    TrustServerCertificate = [bool]$TrustServerCertificate
    Brand                  = $Brand
    Slack                  = if ($SlackSecret) { @{ Secret = $SlackSecret } } else { $null }
    Email                  = if ($EmailSecret) { @{ Secret = $EmailSecret; To = @($EmailTo); SmtpServer = $SmtpServer
                                                    Port = $SmtpPort; ReplyTo = $ReplyTo } } else { $null }
    PurgeHourUtc           = 6
    KeepSnapshotDays       = 14
    KeepAlertDays          = 180
    KeepLogDays            = 14
}
$null = New-Item -ItemType Directory -Path $appRoot -Force
$cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $cfgPath -Encoding utf8

# The task: a plain pwsh -File launch, every N minutes, as you
$runner = (Resolve-Path (Join-Path $PSScriptRoot 'Invoke-AgHealthMonitor.ps1')).Path
$alias  = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'     # Store installs: the stable launcher path
$pwsh   = if (Test-Path $alias) { $alias } else { (Get-Command pwsh -ErrorAction Stop).Source }

$hidden = if ($WindowsCredential) { '' } else { '-WindowStyle Hidden ' }
$action    = New-ScheduledTaskAction -Execute $pwsh -WorkingDirectory (Split-Path $runner) -Argument (
                 "-NoProfile -NonInteractive $hidden-File `"$runner`" -ConfigPath `"$cfgPath`"")
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                 -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
                 -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$register  = @{ TaskName = $taskName; TaskPath = $taskPath; Action = $action; Trigger = $trigger; Settings = $settings; Force = $true
                Description = "Always On Command Center: health snapshot, alert evaluation and notifications for AG $AgName every $EveryMinutes minute(s)." }

if ($WindowsCredential) {
    # Background: Windows keeps the sign-in for the task (encrypted). The account must be the one that saved the secrets.
    $me = "$env:USERDOMAIN\$env:USERNAME"
    if ($WindowsCredential.UserName -notin $me, $env:USERNAME) {
        throw "-WindowsCredential must be ${me}: the saved secrets can only be read by the account that saved them."
    }
    $register.User     = $me
    $register.Password = $WindowsCredential.GetNetworkCredential().Password
    $register.RunLevel = 'Limited'
}
else {
    $register.Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
}
$null = Register-ScheduledTask @register -ErrorAction Stop      # a refused sign-in must stop here, not print "Scheduled"

if ($RunNow) { Start-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop }

$logDir = Join-Path $appRoot 'logs'
Write-Host "Scheduled '$taskName' (Task Scheduler > AlwaysOnCommandCenter), every $EveryMinutes minute(s)."
Write-Host "Config : $cfgPath"
Write-Host "Logs   : $logDir\monitor-yyyyMMdd.log"
Write-Host "Check  : Get-ScheduledTaskInfo -TaskName '$taskName' -TaskPath '$taskPath' | Select-Object LastRunTime, LastTaskResult, NextRunTime"
