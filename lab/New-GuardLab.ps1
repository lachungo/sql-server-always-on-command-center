<#
.SYNOPSIS
    Lab data for the Object Guard drills: a synthetic trade ledger and an application login that is NOT
    approved for DDL, so drops, deletes and schema changes have a realistic "who".

.DESCRIPTION
    On the primary, in the AG database (it replicates to every replica):
      dbo.TradeLedger      300,000 synthetic trades (no real data: generated accounts, symbols and prices)
      dbo.SettlementRun    a small table, for the DROP drill
    On the primary only (AG Sync copies logins to the secondaries):
      app_user             a SQL login with db_owner in the AG database: it can delete and drop, like a careless app

    Safe to re-run: existing objects and the login are left as they are; missing rows are not re-added.

.EXAMPLE
    ./lab/New-GuardLab.ps1 -Primary 'localhost,14341' -SqlCredential $sa -AppCredential (Get-Credential app_user)

    Author: Louis Achungo | SQL IT Tech Solutions
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Primary,
    [Parameter(Mandatory)] [pscredential] $SqlCredential,      # administrator (sa in the lab)
    [Parameter(Mandatory)] [pscredential] $AppCredential,      # user name app_user; avoid $ # ' " and backtick in the password
    [string] $Database = 'SyncLab'
)
$ErrorActionPreference = 'Stop'
Import-Module dbatools
$q = @{ SqlInstance = $Primary; SqlCredential = $SqlCredential; EnableException = $true }

Invoke-DbaQuery @q -Database $Database -Query @"
IF OBJECT_ID(N'dbo.TradeLedger') IS NULL
CREATE TABLE dbo.TradeLedger (
    TradeId   int IDENTITY CONSTRAINT PK_TradeLedger PRIMARY KEY,
    TradeDate date          NOT NULL,
    Account   varchar(12)   NOT NULL,
    Symbol    varchar(8)    NOT NULL,
    Side      char(1)       NOT NULL CONSTRAINT CK_TradeLedger_Side CHECK (Side IN ('B', 'S')),
    Quantity  int           NOT NULL,
    Price     decimal(12,4) NOT NULL,
    Amount    AS CONVERT(decimal(19,4), Quantity * Price) PERSISTED,
    CreatedAt datetime2(3)  NOT NULL CONSTRAINT DF_TradeLedger_CreatedAt DEFAULT SYSUTCDATETIME());

IF OBJECT_ID(N'dbo.SettlementRun') IS NULL
CREATE TABLE dbo.SettlementRun (
    RunId     int IDENTITY CONSTRAINT PK_SettlementRun PRIMARY KEY,
    RunDate   date        NOT NULL,
    Status    varchar(10) NOT NULL,
    TradeRows int         NOT NULL);
"@

Invoke-DbaQuery @q -Database $Database -Query @"
IF NOT EXISTS (SELECT 1 FROM dbo.TradeLedger)
INSERT dbo.TradeLedger (TradeDate, Account, Symbol, Side, Quantity, Price)
SELECT DATEADD(DAY, -CONVERT(int, n.i % 365), CONVERT(date, SYSUTCDATETIME())),
       CONCAT('ACC', RIGHT(CONCAT('00000', n.i % 5000), 5)),
       CHOOSE(CONVERT(int, n.i % 6) + 1, 'MSFT', 'AAPL', 'NVDA', 'JPM', 'XOM', 'KO'),
       CHOOSE(CONVERT(int, n.i % 2) + 1, 'B', 'S'),
       CONVERT(int, n.i % 500) + 1,
       CONVERT(decimal(12,4), 50 + (n.i % 400) + (n.i % 97) / 100.0)
FROM (SELECT TOP (300000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
      FROM sys.all_columns a CROSS JOIN sys.all_columns b) n;

IF NOT EXISTS (SELECT 1 FROM dbo.SettlementRun)
INSERT dbo.SettlementRun (RunDate, Status, TradeRows)
SELECT DATEADD(DAY, -v.n, CONVERT(date, SYSUTCDATETIME())), 'Settled', 800 + v.n
FROM (VALUES (1), (2), (3), (4), (5), (6), (7)) v(n);
"@ -QueryTimeout 300

$login = $AppCredential.UserName
Invoke-DbaQuery @q -Database master -Query @"
IF SUSER_ID(@login) IS NULL
BEGIN
    DECLARE @sql nvarchar(600) = N'CREATE LOGIN ' + QUOTENAME(@login) + N' WITH PASSWORD = '
                               + QUOTENAME(@pwd, '''') + N', CHECK_POLICY = OFF, DEFAULT_DATABASE = ' + QUOTENAME(@db) + N';';
    EXEC (@sql);
END;
"@ -SqlParameter @{ login = $login; pwd = $AppCredential.GetNetworkCredential().Password; db = $Database }

Invoke-DbaQuery @q -Database $Database -Query @"
IF USER_ID(@login) IS NULL
BEGIN
    DECLARE @sql nvarchar(400) = N'CREATE USER ' + QUOTENAME(@login) + N' FOR LOGIN ' + QUOTENAME(@login) + N';';
    EXEC (@sql);
END;
IF IS_ROLEMEMBER('db_owner', @login) = 0
BEGIN
    DECLARE @add nvarchar(400) = N'ALTER ROLE db_owner ADD MEMBER ' + QUOTENAME(@login) + N';';
    EXEC (@add);
END;
"@ -SqlParameter @{ login = $login }

Invoke-DbaQuery @q -Database $Database -Query @"
SELECT 'dbo.TradeLedger' AS [Table], COUNT_BIG(*) AS [Rows] FROM dbo.TradeLedger
UNION ALL SELECT 'dbo.SettlementRun', COUNT_BIG(*) FROM dbo.SettlementRun;
"@ | Format-Table -AutoSize
Write-Host "$login can now change $Database on $Primary. It is not in aghealth.GuardApprovedLogin, so its DDL raises alerts."
