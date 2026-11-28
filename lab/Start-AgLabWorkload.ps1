<#
.SYNOPSIS
    Lab only: writes synthetic rows to an AG database on whichever replica is primary, so log flows and the
    dashboard's queues, rates, RPO and log-flow dots have something real to show.

.DESCRIPTION
    Every few seconds it inserts a batch of synthetic rows (no real data) into dbo.LabWorkload and trims old
    rows so the table stays small. The primary is found again before every batch, so the workload follows a
    failover by itself. Stop it with Ctrl+C, or let -Minutes run out.

    Log written per minute is about -MBPerMinute. The transaction log of the database grows unless log
    backups run: fine in the lab, never point this at a real database.

.EXAMPLE
    ./lab/Start-AgLabWorkload.ps1 -Replica 'localhost,14341','localhost,14342','localhost,14343' -AgName aglab_ag -Database SyncLab -SqlCredential $sa
.EXAMPLE
    # A heavier burst for 3 minutes
    ./lab/Start-AgLabWorkload.ps1 -Replica 'localhost,14341','localhost,14342','localhost,14343' -AgName aglab_ag -Database SyncLab -SqlCredential $sa -MBPerMinute 120 -Minutes 3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string[]]     $Replica,
    [Parameter(Mandatory)] [string]       $AgName,
    [Parameter(Mandatory)] [string]       $Database,
    [Parameter(Mandatory)] [pscredential] $SqlCredential,
    [ValidateRange(1, 1000)] [int] $MBPerMinute = 20,
    [ValidateRange(1, 240)]  [int] $Minutes = 15,
    [ValidateRange(2, 60)]   [int] $BatchSeconds = 5
)

$ErrorActionPreference = 'Stop'

function Find-Primary {
    foreach ($r in $Replica) {
        try {
            $row = Invoke-DbaQuery -SqlInstance $r -SqlCredential $SqlCredential -EnableException -Query @"
SELECT @@SERVERNAME AS name, ars.role_desc
FROM sys.dm_hadr_availability_replica_states AS ars
JOIN sys.availability_groups AS ag ON ag.group_id = ars.group_id
WHERE ars.is_local = 1 AND ag.name = N'$AgName';
"@
            if ($row -and $row.role_desc -eq 'PRIMARY') { return [pscustomobject]@{ Instance = $r; Name = $row.name } }
        } catch { }
    }
    $null
}

$primary = Find-Primary
if (-not $primary) { throw "No primary found for $AgName." }

Invoke-DbaQuery -SqlInstance $primary.Instance -SqlCredential $SqlCredential -Database $Database -EnableException -Query @"
IF OBJECT_ID(N'dbo.LabWorkload') IS NULL
CREATE TABLE dbo.LabWorkload (
    Id        bigint IDENTITY CONSTRAINT PK_LabWorkload PRIMARY KEY,
    WrittenAt datetime2(3) NOT NULL CONSTRAINT DF_LabWorkload_WrittenAt DEFAULT SYSUTCDATETIME(),
    Payload   char(2000)   NOT NULL);
"@

# About 2.2 KB of log per row (row plus overhead): rows per batch for the requested MB per minute
$batchesPerMinute = [math]::Max(1, [int](60 / $BatchSeconds))
$rowsPerBatch     = [math]::Max(1, [int](($MBPerMinute * 1024 / 2.2) / $batchesPerMinute))
$stopAt  = (Get-Date).AddMinutes($Minutes)
$totalMb = 0.0

Write-Host ("==> Lab workload on {0}/{1}: about {2} MB of log a minute ({3} rows every {4} s) for {5} min. Ctrl+C stops it." -f
            $AgName, $Database, $MBPerMinute, $rowsPerBatch, $BatchSeconds, $Minutes) -ForegroundColor Cyan

while ((Get-Date) -lt $stopAt) {
    $started = Get-Date
    $now = Find-Primary
    if (-not $now) { Write-Host ("{0:HH:mm:ss}  no primary right now (failover in progress?): waiting" -f $started) -ForegroundColor Yellow; Start-Sleep -Seconds $BatchSeconds; continue }
    if ($now.Name -ne $primary.Name) { Write-Host ("{0:HH:mm:ss}  primary moved: {1} -> {2}, following it" -f $started, $primary.Name, $now.Name) -ForegroundColor Cyan }
    $primary = $now
    try {
        $r = Invoke-DbaQuery -SqlInstance $primary.Instance -SqlCredential $SqlCredential -Database $Database -EnableException -QueryTimeout 120 -Query @"
SET NOCOUNT ON;
INSERT dbo.LabWorkload (Payload)
SELECT TOP ($rowsPerBatch) REPLICATE(CONVERT(char(36), NEWID()), 55)
FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b;
-- Keep the table small: only the newest 50,000 rows stay
DELETE dbo.LabWorkload WHERE Id <= (SELECT MAX(Id) - 50000 FROM dbo.LabWorkload);
SELECT COUNT_BIG(*) AS rows_now FROM dbo.LabWorkload;
"@
        $totalMb += $rowsPerBatch * 2.2 / 1024
        Write-Host ("{0:HH:mm:ss}  {1}: +{2} rows, about {3:0.0} MB of log so far, {4} rows in the table" -f
                    $started, $primary.Name, $rowsPerBatch, $totalMb, $r.rows_now)
    } catch {
        Write-Host ("{0:HH:mm:ss}  batch failed on {1}: {2}" -f $started, $primary.Name, $_.Exception.Message) -ForegroundColor Yellow
    }
    $wait = $BatchSeconds - ((Get-Date) - $started).TotalSeconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]($wait * 1000)) }
}
Write-Host "==> Workload finished: about $([math]::Round($totalMb, 1)) MB of log written." -ForegroundColor Cyan
