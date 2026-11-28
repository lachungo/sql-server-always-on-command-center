# Always On Command Center

**Sync, live health, guarded runbooks, Object Guard and measured incident closure for SQL Server Always On Availability Groups.**

[![Integration tests](https://github.com/lachungo/sql-server-always-on-command-center/actions/workflows/ci.yml/badge.svg)](https://github.com/lachungo/sql-server-always-on-command-center/actions/workflows/ci.yml)

> 🚧 **Active work in progress, built and proven in a lab.** Every capability below was exercised against a real
> 3-replica Availability Group (Docker, synthetic data only): a suspended secondary resolved by its own runbook,
> a DR replica frozen for 11 minutes under load, planned failovers with measured downtime, and a mass delete
> recovered from a standby restore. It is not yet a supported product.

## Why

**An Availability Group replicates databases, not the instance.** Logins, SQL Agent jobs, linked servers and
credentials live in `master` and `msdb`, and they stay behind when the AG fails over. The failover takes
seconds; the application then can't log in, and the nightly jobs either don't exist on the new primary or
run on every replica at once.

And when something does break at 3 AM, most monitoring answers *"is the replica healthy?"*. The on-call DBA
needs more: **can I trust the business to this replica right now, what exactly is wrong, and which query do I
run?** The Command Center answers those with evidence, scripts and measured numbers, and says plainly when a
number is an estimate or was not reported at all.

## Modules

| Module | What it does | Status |
|---|---|---|
| **AG Sync** | Keeps logins, Agent jobs and new databases consistent across replicas. Two-way drift detection, a deny-by-default auto-sync policy, scoped one-time approvals | ✅ Complete: integration tests incl. a failover drill, 19 policy unit tests |
| **Health collector & alerts** | Snapshots every replica and database each minute; rules stored as data; alerts that open, escalate and close **only on measured recovery** | ✅ Complete, with scheduled monitoring and email / Slack notifications |
| **Guarded runbooks** | Every AG health alert carries evidence from the moment it opened, plus Diagnose / Fix / Verify scripts filled in for that replica and database | ✅ Complete, proven on a real suspension |
| **Object Guard** | Detects dropped objects, unapproved DDL and mass deletes, with who / when / from where, and a standby-restore recovery plan | ✅ Complete, proven on a 300,000-row delete |
| **Live dashboard** | AG topology with animated log flow, per-replica failover verdict, separate HA and DR recovery paths, trends, incidents with their evidence and scripts | ✅ Complete (static page, no server) |
| **Incident correlation** | One parent incident per root cause, with every symptom's evidence kept | 🔨 Next |
| **RCA toolkit & MCP tools** | Incident timelines; AI agents asking "is this AG healthy?", "what happened at 2:14 AM?" within policy | 🔨 Planned |

---

# Module 1: AG Sync

AG Sync detects drift between the primary and every secondary **in both directions** and fixes it **safely**:
it plans before it applies, never drops anything on its own, refuses to copy a job that would run on every replica,
and logs every decision.

## What it syncs

| Object | Compared on | Fixed by Apply |
|---|---|---|
| **Logins** | SID, password hash, enabled state, default database, server roles, **server-level permissions** | Created or rebuilt with the **same SID and password hash**, so database users never orphan after failover |
| **Agent jobs** | SHA-256 of every step and schedule, enabled state, owner, category | Copied from the primary, **only if step 1 checks `sys.fn_hadr_is_primary_replica`**, and only with approval |
| **New databases** | User databases on the primary that are in no AG: recovery model, full-backup history, state | Added to the AG with **automatic seeding**, **only if ready** and approved |

| Drift found | What AG Sync does |
|---|---|
| Missing on a secondary | Ordinary logins are copied **immediately** (`-Mode Auto`); anything elevated waits for approval |
| Different on a secondary | Rebuilt or altered (a SID mismatch only with approval, and only if nothing on the target depends on it) |
| **Only on a secondary** (a reporting replica where people "meddle", or a drop on the primary) | **Alert only, never dropped.** Can be approved as an exception with a reason and a review date |
| Job without a primary-replica guard | **Blocked** until the guard is added |
| New database not ready to join | **Alert only**, with the exact fix |

## Auto-sync is deny-by-default

`-Mode Auto` runs every minute and copies **only** what the policy explicitly allows:

- **Copied automatically:** ordinary logins; logins whose only server roles are `public` and the built-in
  `##MS_*Reader##` roles; read-only server permissions (`VIEW SERVER STATE`, `VIEW ANY DEFINITION`, `VIEW ANY DATABASE`,
  `VIEW ANY ERROR LOG` and their performance variants). DENY permissions are always fine.
- **Waits for a DBA:** any other role or permission, `WITH GRANT OPTION`, SID mismatches, Agent jobs, new AG databases.
- **Approvals are scoped:** `agsync.usp_ApproveSync` approves one object, for one replica, bound to a **SHA-256
  fingerprint** of exactly what was reviewed. It is used once and expires after 24 hours; if the object changes after
  approval, the fingerprint no longer matches and it waits again.
- **Approved exceptions** (`aghealth.DriftException`) record who approved what and why, have a 90-day review date, and
  are **put on hold automatically when the primary changes**: an exception approved against agsql1 is re-checked after
  a failover to agsql2.

## Design principles

- **Plan, then apply.** `-Mode Detect` shows the exact T-SQL and logs the plan. `-Mode Apply` runs it.
- **Topology is resolved on every run.** AG Sync never assumes which replica is primary, so it keeps working after a failover.
- **The controller lives outside the AG.** History, alerts and approvals survive the very failover they protect.
- **Privilege separation.**

  | Account | Permissions | Used for |
  |---|---|---|
  | `agsync_detect` | `VIEW SERVER STATE`, `VIEW ANY DEFINITION`, `SELECT` on msdb job and backup-history tables | Drift detection, health collection |
  | `agsync_apply` | `sysadmin` (creating jobs owned by other logins requires it) | Apply and Auto runs only |
  | `agsync_control` | `SELECT, INSERT, UPDATE` on the controller schemas, `EXECUTE` on their procedures | Audit trail, snapshots, alerts |

- **Secrets are never stored in the repository or in config files.** Credentials come from a DPAPI-protected secret
  store on the monitoring host. Planned SQL that can contain password hashes is shown, never logged.

---

# Module 2: Health collector, alerts and guarded runbooks

The collector takes a **snapshot** of each Availability Group every minute and stores it on the controller; the
alert engine turns snapshots into alerts; the notifier sends them by email or Slack.

## What a snapshot holds

| Level | Collected |
|---|---|
| **AG** | Primary replica, collection status, duration |
| **Replica** | Role, commit mode, connected state, synchronization health, **reachable from the collector**, last connect error |
| **Database, per replica** | Sync state, suspended and why, log send queue and rate, redo queue and rate, last hardened LSN, last commit |
| **Derived** | Data-loss exposure and estimated redo time (see *Honest numbers* below) |

## Honest numbers

The drills taught these, and the dashboard and alerts now say them explicitly:

- **A redo backlog is not data loss.** A synchronous replica that is SYNCHRONIZED has hardened every commit before the
  primary acknowledged it, so its data loss is **0** even while redo is behind. Its `last_commit_time` follows redo, so
  comparing commit times would report a redo delay as data loss.
- **For an asynchronous replica, commit-time lag is an estimate of exposure**, labelled as such, not verified data loss.
- **Unknown is not zero.** The primary does not report a send queue for a disconnected replica; the dashboard draws a
  gap and says how many snapshots were not reported, instead of drawing 0.
- **"Last reported" rates are labelled.** SQL Server's send and redo rates can describe a burst that is already over;
  alerts add the movement actually observed between two snapshots.
- **Estimated redo time is not a measured RTO.** The lab failover script measures the real one.

## Alert rules are data

Default rules ship in `aghealth.AlertRule`. Tuning one is an `UPDATE`, adding one is an `INSERT`; re-running the schema
script never overwrites a tuned threshold.

| Rule | Fires when | Severity | In a row |
|---|---|---|---|
| CollectionFailed | The collector could not complete a snapshot | Critical | 2 |
| ReplicaUnreachable | The collector cannot connect to a replica | Critical | 2 |
| ReplicaDisconnected | The primary reports a replica disconnected | Critical | 2 |
| ReplicaNotHealthy | Replica synchronization health is not HEALTHY | Warning | 2 |
| DatabaseSuspended | Data movement is suspended | Critical | 1 |
| SyncSecondaryNotSynced | A **synchronous** secondary is not SYNCHRONIZED | Critical | 2 |
| AsyncSecondaryNotMoving | An **asynchronous** secondary is not SYNCHRONIZING | Warning | 2 |
| LogSendQueueHigh | Log not yet sent > 100 MB / 1 GB | Warning / Critical | 3 |
| RedoQueueHigh | Log not yet redone > 500 MB / 2 GB | Warning / Critical | 3 |
| EstimatedDataLossHigh | An async secondary's commit-time lag > 60 s / 300 s | Warning / Critical | 3 |
| EstimatedRecoveryHigh | Estimated redo time > 300 s / 900 s | Warning / Critical | 3 |
| MissingOnSecondary / OnlyOnSecondary | Two-way drift of logins, jobs and AG databases | Warning | 1 |
| ObjectDropped / UnapprovedDDL / MassDataLoss | Object Guard (Module 3) | Warning / Critical | 1 |

## Alert lifecycle

- **Opens** only after the rule breaches for its number of snapshots **in a row**.
- **One open alert per problem**, held while it lasts; **escalates** from Warning to Critical and notifies again.
- **Closes only on measured recovery, for 2 healthy snapshots in a row** (`ResolveAfterSnapshots`), and records how:
  *"Measured: ConnectedState = CONNECTED (expected CONNECTED) on agsql3, healthy in 2 consecutive snapshots. Open for 11 min."*
  An object the collector could not see is never "resolved"; a disabled rule's alerts say so instead of claiming a recovery.

## Guarded runbooks: no hunting for a query at 4 AM

When an AG health alert opens, the collector records **evidence as it was at that moment** (suspend reason, primary log
use and why it can or cannot truncate, queues, last reported rates and observed movement, data-loss exposure, blocking
sessions, endpoint and certificate state) and generates scripts filled in for that AG, replica and database:

| Stage | Example |
|---|---|
| **Diagnose** | Suspend reason as the secondary reports it; the error log around it (SQL Server 2022+: `VIEW ANY ERROR LOG`; earlier: securityadmin or sysadmin) |
| **Fix** | Starts with **guards**: `THROW` if run on the wrong server, do nothing if the problem has already cleared, an *Authorized by* line to fill in. Then the `RESUME`, endpoint start, and so on |
| **Danger** | e.g. `KILL` of a session blocking redo, guarded so it only runs while that session still blocks. Never automated |
| **Verify** | **Three readings, 10 seconds apart**: healthy means moving every time with the send queue not growing |

Nothing is executed automatically. A person runs the steps, or later an agent within the approval policy.

---

# Module 3: Object Guard

Detects what AG monitoring usually misses: a table dropped on the primary is dropped everywhere within seconds.

- **What it watches:** an inventory diff every minute (objects and row counts) plus an Extended Events session on every
  replica capturing object create / alter / drop, `TRUNCATE`, and `DELETE` statements touching many rows.
- **Rules:** ObjectDropped, UnapprovedDDL, MassDataLoss (thresholds as data).
- **Evidence:** the account (and whether it is a DBA or application account), when, from which host and program, the
  statement, rows affected, the transaction and the **recovery point**.
- **The business decides.** A mass delete can be legitimate. The alert asks the DBA to confirm with the business;
  `aghealth.usp_RecordDecision` records *Intended* (closes the alert with who confirmed it) or *Recover*.
- **Recovery plan, never over production:** the backup chain from msdb on every replica (full, differential, contiguous
  logs), a `STOPAT` one second before the change into a **standby copy** (`<db>_Recover_<timestamp>`), a key-level
  comparison with **SHA-256 per row and a table digest**, copy back only after a *Recover* decision, verify the digests
  match, clean up.

---

# The live dashboard

`Export-AgDashboardData` writes `data.js` next to `dashboard/index.html` every minute; the page reloads it every 15
seconds and redraws only when it changed. No web server, no database connection from the browser.

- **Failover verdict per replica:** *"agsql2 can become PRIMARY with no data loss"*, or exactly why not, including logins
  or jobs that would be missing there after a failover.
- **Recovery paths kept apart:** HA path (synchronous and synchronized: expected data loss 0 s), DR path (commit-time lag,
  labelled as an estimate), estimated redo time, and the preferred failover target.
- **Topology with animated log flow**, per-database queues, trend charts with honest scales and gaps for unreported values.
- **Open incidents** with their evidence and copy-ready scripts; **Object Guard** timeline; **two-way drift** per replica;
  **resolved in the last 24 hours** with how each one closed.

---

# Proven in the lab

| Drill | Result |
|---|---|
| Suspend data movement on the async secondary | DatabaseSuspended (Critical) opened with evidence and guarded scripts; the runbook's Fix resumed it; every related alert closed by measurement |
| `docker pause` the DR replica for 11 minutes under a 40 MB/min workload | Critical alerts within 2 minutes; DR lag climbed to 11 min while the **HA path stayed at 0 s**; send queue shown as *not reported*; after unpause the ~400 MB backlog was sent and all 5 alerts closed after 2 healthy snapshots each |
| Planned failover agsql2 → agsql1 (`lab/Invoke-AgLabFailover.ps1`) | Every secondary synchronized at the primary's LSN first; **writes unavailable 2.3 s, every replica moving data again after 6.1 s, no data loss**. The dashboard followed the new primary on its own |
| Approved exception across failovers | Put on hold when agsql2 became primary, valid again when agsql1 returned |
| Mass delete of 300,000 rows | Evidence (account, host, program, statement, rows); standby restore to one second before; key-level SHA-256 comparison; copy back; digests identical; alert closed with the business decision recorded |

Timings are from a single host running Docker; a real network between sites is slower.

---

# Quick start (lab)

Requirements: Docker, PowerShell 7, [dbatools](https://dbatools.io), and [Pester 5+](https://pester.dev) for the tests.

```powershell
# 1. Build the lab: a 3-replica AG (sync + sync + async "DR") plus a controller, from nothing
$sa      = Get-Credential sa
$app     = Get-Credential agsync_apply
$det     = Get-Credential agsync_detect
$ctlCred = Get-Credential agsync_control
$lab = ./lab/New-AgLab.ps1 -SaCredential $sa -ApplyCredential $app -DetectCredential $det -ControlCredential $ctlCred -Reset

# 2. Object Guard schema, XE sessions and permissions
./ops/Install-AgGuard.ps1 -Replica $lab.Replica -AgName $lab.AgName -ControlInstance $lab.ControlInstance -SqlCredential $sa

# 3. Save the monitor's accounts once (DPAPI secret store), then schedule it every minute:
#    collect, guard, drift, notify, dashboard. Add -EmailSecret / -SlackSecret for notifications.
Import-Module ./AgHealth/AgHealth.psm1
Save-AgHealthSecret -Name AgDetect  -Credential $det
Save-AgHealthSecret -Name AgControl -Credential $ctlCred
./ops/Register-AgHealthMonitor.ps1 -Replica $lab.Replica -AgName $lab.AgName -ControlInstance $lab.ControlInstance -TrustServerCertificate -RunNow

# 4. Make things happen
./lab/Start-AgLabWorkload.ps1 -Replica $lab.Replica -AgName $lab.AgName -Database SyncLab -SqlCredential $sa
./lab/Invoke-AgLabFailover.ps1 -Replica $lab.Replica -AgName $lab.AgName -Target 'localhost,14342' -SqlCredential $sa
```

The dashboard is written to `%LOCALAPPDATA%\AlwaysOnCommandCenter\dashboard\index.html`.

---

# Tests

**Integration tests** run against a **real Availability Group**, not mocks: each scenario builds its own problem, runs the
tools with the least-privilege accounts, asserts the outcome, and cleans up. They include a failover drill (the synced
login connects to the new primary with its original password; the role-aware job runs only there) and a suspended
secondary (alerts open, hold without duplicates, and close on recovery). **Unit tests** cover the auto-sync policy:
what is copied, what waits, and that a scoped approval is used once, for one replica, and only for what was reviewed.

On every push, [GitHub Actions](.github/workflows/ci.yml) builds the full 3-replica AG in Docker with throwaway
passwords and runs the suites. No secrets are stored in the repository.

| Platform | Status |
|---|---|
| SQL Server 2025 on Ubuntu 22.04 and 24.04 runners | **Required** on every push |
| SQL Server 2022 CU26 on GitHub-hosted runners | **Required** on every push |
| SQL Server 2022 CU27, locally (Docker on Windows) | Passing |
| SQL Server 2022 CU27 on GitHub-hosted runners | **Known issue**, tracked as experimental (see below) |

**Known issue, found and bisected by this CI.** On GitHub-hosted runners, the SQL Server 2022 **CU27** container image
(build 16.0.4305.5 when tested) spins at 100% CPU when another replica connects to its AG endpoint, so the replica
never joins (error 47106, then timeouts). CU17 through CU26 and SQL Server 2025 pass on the same runners; the same CU27
image passes on an Intel desktop. The experimental job keeps tracking it.

```powershell
$c = New-PesterContainer -Path ./tests/AgSync.Tests.ps1, ./tests/AgHealth.Tests.ps1 -Data @{
         Replica = $lab.Replica; AgName = $lab.AgName; ControlInstance = $lab.ControlInstance
         AdminCredential = $sa; ApplyCredential = $app; DetectCredential = $det; ControlCredential = $ctlCred }
Invoke-Pester -Container $c -Output Detailed
Invoke-Pester ./tests/AgSyncPolicy.Tests.ps1 -Output Detailed      # unit tests, no lab needed
```

## Repository layout

```
AgSync.psm1                    Module 1: Get-AgSyncDrift, Invoke-AgSync (Detect, Apply, Auto)
AgHealth/AgHealth.psm1         Modules 2-3 and the dashboard: collection, guard, runbooks, notifications, export
dashboard/index.html           the live dashboard (one static page)
sql/ControlDb.sql              controller database, AG Sync audit, scoped approvals
sql/HealthSchema.sql           snapshots, alert rules and engine, evidence and scripts, drift alerts and exceptions, retention
sql/ObjectGuard.sql            Object Guard inventory, events, rules and evaluation
sql/AgSyncAccounts.sql         msdb permissions for the detect account (every replica)
ops/Invoke-AgHealthMonitor.ps1 the scheduled run: collect, guard, drift, notify, dashboard, purge
ops/Register-AgHealthMonitor.ps1  registers it as a scheduled task
ops/Install-AgGuard.ps1        Object Guard install on the controller and every replica
lab/New-AgLab.ps1              one-command lab: containers, certificates, endpoints, AG, seeding, accounts
lab/docker-compose.yml         3 replicas + controller
lab/New-GuardLab.ps1           synthetic tables for the Object Guard drills
lab/Start-AgLabWorkload.ps1    synthetic write load that follows the primary
lab/Invoke-AgLabFailover.ps1   planned, lossless failover for CLUSTER_TYPE = NONE, with measured downtime
tests/AgSync.Tests.ps1         integration suite, AG Sync
tests/AgHealth.Tests.ps1       integration suite, health and alerts
tests/AgSyncPolicy.Tests.ps1   unit tests, auto-sync policy and approvals
.github/workflows/ci.yml       CI: build the AG, run the suites, on every push
```

## Roadmap

- [x] Logins, Agent jobs and new databases kept consistent; failover drill
- [x] Two-way drift, deny-by-default auto-sync, scoped fingerprint-bound approvals, approved exceptions re-checked after failover
- [x] Health collector and alert engine; scheduled monitoring; email and Slack notifications
- [x] Guarded runbooks with evidence at the moment of failure; sustained verification
- [x] Closing only on measured recovery, with the measurement recorded
- [x] Object Guard with standby-restore recovery and SHA-256 verification
- [x] Live dashboard with per-replica verdicts and separate HA / DR recovery paths
- [x] Measured failover downtime; lag drill under load
- [ ] Parent-child incident correlation (one root cause, one incident)
- [ ] Estimating unsent log while a replica is disconnected
- [ ] Mass UPDATE detection; bulk-load awareness
- [ ] Scale test: 1,000 logins and 500 jobs, timed
- [ ] Linked servers and credentials
- [ ] RCA toolkit and MCP tools for AI agents, within the approval policy

---

**Louis Achungo**, Senior SQL Server DBA and Architect · [LinkedIn](https://www.linkedin.com/in/louis-achungo) ·
**SQL-IT-Tech Solutions**, "Enterprise SQL Architecture. Simplified." · [sql-it-techsolutions.com](https://sql-it-techsolutions.com/)
