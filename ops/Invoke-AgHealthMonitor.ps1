<#
.SYNOPSIS
    One monitoring pass for one Availability Group: collect a health snapshot, evaluate alerts,
    send notifications, and do the daily upkeep.

.DESCRIPTION
    Built to run every minute from Task Scheduler (see Register-AgHealthMonitor.ps1) or any other scheduler.

    - One run at a time per AG: a lock file makes an overlapping run skip instead of piling up.
    - Never silent: every run writes to a daily log, and a failure sets a non-zero exit code.
    - Secrets never live in the config file: it only names secrets saved with Save-AgHealthSecret.
    - Daily upkeep: snapshot retention (aghealth.usp_PurgeHistory) once a day, and old logs removed.

    Exit codes: 0 ok or skipped, 1 collection failed, 2 a notification channel failed, 3 configuration error.

.EXAMPLE
    ./ops/Invoke-AgHealthMonitor.ps1 -ConfigPath "$env:LOCALAPPDATA\AlwaysOnCommandCenter\monitor-aglab_ag.json"

    Author: Louis Achungo | SQL IT Tech Solutions
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ConfigPath,
    [string] $LogDirectory,
    # Overrides, for tests and other schedulers. Normally everything comes from the config and saved secrets.
    [pscredential] $DetectCredential,
    [pscredential] $ControlCredential,
    [object[]] $Channel
)

$ErrorActionPreference = 'Stop'
$appRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AlwaysOnCommandCenter'
if (-not $LogDirectory) { $LogDirectory = Join-Path $appRoot 'logs' }
$null = New-Item -ItemType Directory -Path $LogDirectory -Force
$logFile = Join-Path $LogDirectory ('monitor-{0:yyyyMMdd}.log' -f [datetime]::UtcNow)

function Write-MonitorLog {
    param([string] $Level, [string] $Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss}Z {1,-5} {2}' -f [datetime]::UtcNow, $Level, $Message
    Add-Content -Path $logFile -Value $line
    Write-Verbose $line
}

# ---- Configuration -------------------------------------------------------------------------------
try {
    $cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    foreach ($key in 'Replica', 'AgName', 'ControlInstance') {
        if (-not $cfg.$key) { throw "'$key' is missing." }
    }
}
catch {
    Write-MonitorLog ERROR "Configuration $ConfigPath is not usable: $($_.Exception.Message)"
    exit 3
}
$agTag = $cfg.AgName -replace '[^A-Za-z0-9_.-]', '_'

# ---- One run at a time ---------------------------------------------------------------------------
$lockPath = Join-Path $LogDirectory "$agTag.lock"
try   { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
catch [IO.IOException] {
    Write-MonitorLog INFO "$($cfg.AgName): previous run still active; skipped."
    exit 0
}

$exitCode = 0
try {
    Import-Module dbatools
    Import-Module (Join-Path $PSScriptRoot '../AgHealth/AgHealth.psm1') -Force
    if ($cfg.TrustServerCertificate) { $null = Set-DbatoolsInsecureConnection -SessionOnly }

    $controlDb = if ($cfg.ControlDatabase) { $cfg.ControlDatabase } else { 'AgSyncControl' }
    $det = if ($DetectCredential) { $DetectCredential } elseif ($cfg.DetectSecret) { Get-AgHealthSecret $cfg.DetectSecret } else { $null }
    $ctl = if ($ControlCredential) { $ControlCredential } elseif ($cfg.ControlSecret) { Get-AgHealthSecret $cfg.ControlSecret } else { $null }
    $control = @{ SqlInstance = $cfg.ControlInstance; Database = $controlDb }
    if ($ctl) { $control.SqlCredential = $ctl }

    # Channels from the config, unless given directly
    if (-not $PSBoundParameters.ContainsKey('Channel')) {
        $brandArgs = @{}
        if ($cfg.Brand) { foreach ($p in $cfg.Brand.PSObject.Properties) { if ($p.Value) { $brandArgs[$p.Name] = $p.Value } } }
        $brand   = New-AgHealthBrand @brandArgs
        $Channel = @()
        if ($cfg.Slack) {
            $Channel += New-AgHealthSlackChannel -WebhookCredential (Get-AgHealthSecret $cfg.Slack.Secret) -Brand $brand
        }
        if ($cfg.Email) {
            $mail = @{ Credential = Get-AgHealthSecret $cfg.Email.Secret; To = @($cfg.Email.To); Brand = $brand }
            foreach ($k in 'SmtpServer', 'Port', 'From', 'FromName', 'ReplyTo') { if ($cfg.Email.$k) { $mail[$k] = $cfg.Email.$k } }
            $Channel += New-AgHealthEmailChannel @mail
        }
    }

    # ---- Collect and evaluate --------------------------------------------------------------------
    $collect = @{ Replica = @($cfg.Replica); AgName = $cfg.AgName; ControlInstance = $cfg.ControlInstance; ControlDatabase = $controlDb }
    if ($det) { $collect.SqlCredential = $det }
    if ($ctl) { $collect.ControlCredential = $ctl }
    try {
        $s = Invoke-AgHealthCollection @collect
        $changes = @($s.Alerts | Where-Object { $_.Change -ne 'Ongoing' })
        $open    = @($s.Alerts | Where-Object { $_.Change -in 'Opened', 'Escalated', 'Downgraded', 'Ongoing' })
        Write-MonitorLog INFO ("{0}: snapshot {1} {2}, primary {3}, {4} ms, {5} open alert(s)." -f
            $cfg.AgName, $s.SnapshotId, $s.Status, $s.PrimaryReplica, $s.DurationMs, $open.Count)
        if ($s.Message) { Write-MonitorLog WARN "$($cfg.AgName): $($s.Message)" }
        foreach ($a in $changes) {
            $where = (@($a.ReplicaServerName, $a.DatabaseName) | Where-Object { $_ -and -not ($_ -is [DBNull]) }) -join '/'
            Write-MonitorLog ALERT ("{0}: {1} {2} {3} {4}" -f $cfg.AgName, $a.Change, $a.Severity, $a.RuleName, $where)
        }
        if ($s.Status -ne 'Succeeded') { $exitCode = 1 }
    }
    catch {
        Write-MonitorLog ERROR "$($cfg.AgName): collection failed: $($_.Exception.Message)"
        $exitCode = 1
    }

    # ---- Notify (also after a failed collection: CollectionFailed is an alert too) ---------------
    if (@($Channel).Count) {
        try {
            $sent = @(Send-AgHealthNotification -ControlInstance $cfg.ControlInstance -ControlDatabase $controlDb `
                        -ControlCredential $ctl -Channel $Channel -AgName $cfg.AgName)
            foreach ($n in $sent) {
                $level = if ($n.Status -eq 'Sent') { 'INFO' } else { 'WARN' }
                $err   = if ($n.Error) { ": $($n.Error)" } else { '' }
                Write-MonitorLog $level ("{0}: notify {1} {2} {3} via {4}: {5}{6}" -f
                    $cfg.AgName, $n.Event, $n.Severity, $n.RuleName, $n.Channel, $n.Status, $err)
            }
            if (@($sent | Where-Object Status -ne 'Sent').Count -and $exitCode -eq 0) { $exitCode = 2 }
        }
        catch {
            Write-MonitorLog ERROR "$($cfg.AgName): notification failed: $($_.Exception.Message)"
            if ($exitCode -eq 0) { $exitCode = 2 }
        }
    }

    # ---- Daily upkeep ----------------------------------------------------------------------------
    $now        = [datetime]::UtcNow
    $purgeHour  = if ($null -ne $cfg.PurgeHourUtc) { [int]$cfg.PurgeHourUtc } else { 6 }
    $marker     = Join-Path $LogDirectory "$agTag.lastpurge"
    $lastPurge  = if (Test-Path $marker) { (Get-Content $marker -Raw).Trim() } else { '' }
    if ($now.Hour -ge $purgeHour -and $lastPurge -ne $now.ToString('yyyy-MM-dd')) {
        try {
            $keepSnap  = if ($cfg.KeepSnapshotDays) { [int]$cfg.KeepSnapshotDays } else { 14 }
            $keepAlert = if ($cfg.KeepAlertDays)    { [int]$cfg.KeepAlertDays }    else { 180 }
            Invoke-DbaQuery @control -EnableException -Query 'EXEC aghealth.usp_PurgeHistory @KeepSnapshotDays = @s, @KeepAlertDays = @a;' `
                            -SqlParameter @{ s = $keepSnap; a = $keepAlert }
            Set-Content -Path $marker -Value $now.ToString('yyyy-MM-dd')
            Write-MonitorLog INFO "$($cfg.AgName): retention done (snapshots $keepSnap days, resolved alerts $keepAlert days)."
        }
        catch { Write-MonitorLog WARN "$($cfg.AgName): retention failed: $($_.Exception.Message)" }

        $keepLogs = if ($cfg.KeepLogDays) { [int]$cfg.KeepLogDays } else { 14 }
        Get-ChildItem -Path $LogDirectory -Filter 'monitor-*.log' |
            Where-Object LastWriteTimeUtc -lt $now.AddDays(-$keepLogs) | Remove-Item -Force
    }
}
catch {
    Write-MonitorLog ERROR "$($cfg.AgName): run failed: $($_.Exception.Message)"
    if ($exitCode -eq 0) { $exitCode = 3 }
}
finally {
    $lock.Dispose()
}
exit $exitCode
