# Always On Command Center

**Sync, live health, alerts and root-cause analysis for SQL Server Always On Availability Groups.**

[![Integration tests](https://github.com/lachungo/sql-server-always-on-command-center/actions/workflows/ci.yml/badge.svg)](https://github.com/lachungo/sql-server-always-on-command-center/actions/workflows/ci.yml)

> 🚧 **Active work in progress.** AG Sync (Module 1) and the health collector and alert engine (Module 2) are
> tested on every push against a real 3-replica Availability Group: 57 integration tests, including a failover drill
> and a deliberately suspended secondary. The live dashboard and RCA modules are being built on the same foundation.

## Why

**An Availability Group replicates databases, not the instance.** Logins, SQL Agent jobs, linked servers and
credentials live in `master` and `msdb`, and they stay behind when the AG fails over. The failover takes
seconds; the application then can't log in, and the nightly jobs either don't exist on the new primary or
run on every replica at once. Meanwhile most teams only find out the AG is unhealthy when the alert fires,
with no picture of where the data is flowing, how far behind each replica is, or why.

The Command Center brings that into one place: keep the replicas consistent, see the topology and data flow
live, alert on what matters, and turn incidents into evidence-backed RCAs.

## Modules

| Module | What it does | Status |
|---|---|---|
| **AG Sync** | Keeps logins, Agent jobs and new databases consistent across replicas, safely, with a full audit trail | ✅ Complete, 36 integration tests incl. a failover drill |
| **Health collector & alerts** | Snapshots every replica and database (sync state, send/redo queues, estimated data loss and recovery time); rules stored as data; alerts that open, escalate and resolve without flapping | ✅ Collector and alert engine, 21 integration tests. 🔨 Scheduling and notifications next |
| **Live dashboard** | Interactive AG topology with animated data flow, lag, health assessment and sync status | 🔨 Next |
| **RCA toolkit** | Builds incident timelines from AlwaysOn_health events, snapshots and sync history | 🔨 Planned |
| **MCP tools** | Exposes the Command Center to AI agents: "is this AG healthy?", "what drifted?", "what happened at 2:14 AM?" | 🔨 Planned |

---

# Module 1: AG Sync

AG Sync detects drift between the primary and every secondary and fixes it **safely**: it plans before it
applies, never drops anything on its own, refuses to copy a job that would run on every replica, and logs
every decision.

## What it syncs today

| Object | Compared on | Fixed by Apply |
|---|---|---|
| **Logins** | SID, password hash, enabled state, default database, server roles, **server-level permissions** | Created or rebuilt with the **same SID and password hash**, so database users never orphan after failover |
| **Agent jobs** | SHA-256 of every step and schedule, enabled state, owner, category | Copied from the primary, **only if step 1 checks `sys.fn_hadr_is_primary_replica`** |
| **New databases** | User databases on the primary that are in no AG: recovery model, full-backup history, state | Added to the AG with **automatic seeding**, **only if ready** (FULL recovery and a full backup) |

| Drift found | What AgSync does |
|---|---|
| Missing on a secondary | Creates it |
| Different on a secondary | Rebuilds or alters it (a SID mismatch only if nothing on the target depends on it) |
| Only on a secondary (possible drop) | **Alert only**. Never dropped automatically |
| Job without a primary-replica guard | **Blocked** until the guard is added |
| New database not ready to join | **Alert only**, with the exact fix. AgSync never changes a recovery model or takes a backup on its own |
| Extra roles or permissions on a secondary | Reported, never revoked automatically |

## Design principles

- **Plan, then apply.** `-Mode Detect` shows the exact T-SQL it would run and logs the plan. `-Mode Apply` runs it.
  One function in the module changes a replica; everything else only reads.
- **Topology is resolved on every run.** AgSync never assumes which replica is primary, so it keeps working after a failover.
- **The controller lives outside the AG.** Sync history and pending alerts are stored on a separate instance,
  so they survive the very failover they're meant to protect.
- **Privilege separation.**

  | Account | Permissions | Used for |
  |---|---|---|
  | `agsync_detect` | `VIEW SERVER STATE`, `VIEW ANY DEFINITION`, `SELECT` on msdb job and backup-history tables | Scheduled drift detection |
  | `agsync_apply` | `sysadmin` (creating jobs owned by other logins requires it) | Apply runs only |
  | `agsync_control` | `SELECT, INSERT, UPDATE` on the `agsync` schema | Writing the audit trail |

  Reading a password hash requires `CONTROL SERVER`, so the detect account cannot see password drift.
  AgSync says so in a warning instead of silently reporting "no drift".
- **Secrets are never stored.** The planned SQL (which can contain password hashes) is shown, never logged.

## Quick start

Requirements: Docker, PowerShell 7, [dbatools](https://dbatools.io), and [Pester 5+](https://pester.dev) for the tests.

```powershell
# 1. Build the lab: a 3-replica AG (sync + sync + async "DR") plus a controller, from nothing
$sa      = Get-Credential sa
$app     = Get-Credential agsync_apply
$det     = Get-Credential agsync_detect
$ctlCred = Get-Credential agsync_control
$lab = ./lab/New-AgLab.ps1 -SaCredential $sa -ApplyCredential $app -DetectCredential $det -ControlCredential $ctlCred -Reset

# 2. Use it
Import-Module ./AgSync.psm1
Get-AgSyncDrift @lab -SqlCredential $det -ControlCredential $ctlCred | Format-Table             # report only
Invoke-AgSync   @lab -SqlCredential $app -ControlCredential $ctlCred -Mode Detect | Format-Table # plan + log
Invoke-AgSync   @lab -SqlCredential $app -ControlCredential $ctlCred -Mode Apply  | Format-Table # apply + log
```

---

# Module 2: Health collector and alerts

The collector takes a **snapshot** of an Availability Group and stores it on the controller; the alert engine turns
snapshots into alerts. Snapshots are the history the dashboard draws and the RCA toolkit reads.

## What a snapshot holds

| Level | Collected | Why it matters |
|---|---|---|
| **AG** | Primary replica, collection status, duration | A failed collection is itself an alert: no data is a finding |
| **Replica** | Role, commit mode, connected state, synchronization health, **reachable from the collector**, last connect error | The primary's view and the collector's own connection test can disagree; both are kept |
| **Database, per replica** | Sync state, suspended and why, log send queue and rate, redo queue and rate, last hardened LSN, last commit | The raw evidence for every alert |
| **Derived** | **Estimated data loss** (seconds behind the primary's last commit: RPO) and **estimated recovery time** (redo queue ÷ redo rate: RTO) | What a failover would cost right now |

## How it behaves when things go wrong

- **Every replica is probed separately**, with a short connect timeout. A dead replica is recorded as unreachable;
  it can't hang the run or silently disappear from the snapshot.
- **No primary, or two primaries, fails the snapshot but keeps the evidence.** On `CLUSTER_TYPE = NONE` two replicas
  reporting PRIMARY after a forced failover is split brain, and the snapshot says so.
- **Suspension is read from the secondary itself.** The primary cannot see `SUSPEND_FROM_PARTNER`.
- **A snapshot is written in one transaction**, so a reader never sees half of one.

## Alert rules are data

Eleven default rules ship in `aghealth.AlertRule`. Tuning one is an `UPDATE`, adding one is an `INSERT`; no redeploy,
and re-running the schema script never overwrites a tuned threshold.

| Rule | Fires when | Severity | In a row |
|---|---|---|---|
| CollectionFailed | The collector could not complete a snapshot | Critical | 2 |
| ReplicaUnreachable | The collector cannot connect to a replica | Critical | 2 |
| ReplicaDisconnected | The primary reports a replica disconnected | Critical | 2 |
| ReplicaNotHealthy | Replica synchronization health is not HEALTHY | Warning | 2 |
| DatabaseSuspended | Data movement is suspended (the primary's log will grow) | Critical | 1 |
| SyncSecondaryNotSynced | A **synchronous** secondary is not SYNCHRONIZED | Critical | 2 |
| AsyncSecondaryNotMoving | An **asynchronous** secondary is not SYNCHRONIZING | Warning | 2 |
| LogSendQueueHigh | Log not yet sent > 100 MB / 1 GB | Warning / Critical | 3 |
| RedoQueueHigh | Log not yet redone > 500 MB / 2 GB | Warning / Critical | 3 |
| EstimatedDataLossHigh | An async secondary is > 60 s / 300 s behind (RPO) | Warning / Critical | 3 |
| EstimatedRecoveryHigh | Redo would take > 300 s / 900 s (RTO) | Warning / Critical | 3 |

Rules know the commit mode: "not SYNCHRONIZED" is an outage on a synchronous secondary and normal on an asynchronous one.

## Alert lifecycle

- **Opens** only after the rule breaches for its number of snapshots **in a row**: one bad reading doesn't page anyone.
- **Stays open, once**, while the breach lasts. A unique index allows one open alert per rule and object, so there are
  no duplicates and no re-alerting every minute.
- **Escalates** from Warning to Critical, and queues a fresh notification when it does.
- **Resolves only on a measured recovery.** An object the collector could not see this time is never "resolved".
  Disabling a rule resolves its open alerts.
- **Retention** purges old snapshots in batches, but never one an open alert still points at.

## Least privilege

| Account | Permissions | Used for |
|---|---|---|
| `agsync_detect` | On the replicas: `VIEW SERVER STATE`, `VIEW ANY DEFINITION` | Reading health: the collector never changes a replica |
| `aghealth_writer` role (`agsync_control`) | On the controller: `SELECT, INSERT, UPDATE` on `aghealth`, `EXECUTE` on its procedures | Writing snapshots and alerts |
| `aghealth_reader` role | On the controller: `SELECT` on `aghealth` | The dashboard |

## Use it

```powershell
Import-Module ./AgHealth/AgHealth.psm1
$s = Invoke-AgHealthCollection @lab -SqlCredential $det -ControlCredential $ctlCred
$s.Databases | Format-Table ReplicaServerName, DatabaseName, SynchronizationState, LogSendQueueKb, RedoQueueKb, EstimatedDataLossSec, EstimatedRecoverySec
$s.Alerts    | Format-Table Change, Severity, RuleName, ReplicaServerName, DatabaseName, LastValue
```

`$s.Alerts` lists every alert the snapshot touched: Opened, Escalated, Downgraded, Resolved or Ongoing.

---

# Tests (both modules)

**57 integration tests** (36 for AG Sync, 21 for health and alerts) run against a **real Availability Group**, not mocks. Each scenario builds its own problem,
runs the tools with the least-privilege accounts, asserts the outcome, and cleans up.

The **failover drill** fails the AG over to a secondary and proves the point of the whole module: the application
login connects to the new primary with its original password, the role-aware job does real work there and skips on
the old primary, and AgSync follows the new primary with no configuration change. It then always fails back.

The **suspended-secondary scenario** breaks the AG for real: it suspends data movement on the async secondary, then
proves the alerts open (DatabaseSuspended on the first snapshot, AsyncSecondaryNotMoving only on the second in a row),
hold without duplicates, and resolve once the replica catches up.

On every push, [GitHub Actions](.github/workflows/ci.yml) builds the full 3-replica AG in Docker with throwaway
passwords and runs the suite. No secrets are stored in the repository.

| Platform | Status |
|---|---|
| SQL Server 2025 on Ubuntu 22.04 and 24.04 runners | **Required** on every push |
| SQL Server 2022 CU26 on GitHub-hosted runners | **Required** on every push |
| SQL Server 2022 CU27 (latest), locally (Docker on Windows) | Passing: all tests |
| SQL Server 2022 CU27 (latest) on GitHub-hosted runners | **Known issue**, tracked as experimental (see below) |

**Known issue, found and bisected by this CI.** On GitHub-hosted runners, the SQL Server 2022 **CU27** container image
(build 16.0.4305.5 when tested) spins at 100% CPU when another replica connects to its AG endpoint, so the replica
never joins (error 47106, then timeouts). A parallel run of every 2022 cumulative update showed **CU17 through CU26
pass** on the same runners, as does SQL Server 2025, which isolates the change to **CU27**. The same CU27 image passes
on an Intel desktop, which points to an interaction between that image and the runners' hardware or kernel rather
than to AgSync. The experimental job keeps tracking it on every push.

```powershell
$c = New-PesterContainer -Path ./tests/AgSync.Tests.ps1, ./tests/AgHealth.Tests.ps1 -Data @{
         Replica = $lab.Replica; AgName = $lab.AgName; ControlInstance = $lab.ControlInstance
         AdminCredential = $sa; ApplyCredential = $app; DetectCredential = $det; ControlCredential = $ctlCred }
Invoke-Pester -Container $c -Output Detailed
```

## Repository layout

```
AgSync.psm1              Module 1: Get-AgSyncDrift, Invoke-AgSync
AgHealth/AgHealth.psm1   Module 2: Invoke-AgHealthCollection
sql/ControlDb.sql        control database and AG Sync audit schema (run on the controller)
sql/HealthSchema.sql     health snapshots, alert rules, alert engine, retention (run on the controller)
sql/AgSyncAccounts.sql   msdb permissions for the detect account (run on every replica)
lab/New-AgLab.ps1        one-command lab: containers, certificates, endpoints, AG, seeding, accounts
lab/docker-compose.yml   3 replicas + controller
lab/Invoke-AgLabFailover.ps1  planned, lossless manual failover for a CLUSTER_TYPE = NONE AG
tests/AgSync.Tests.ps1   Pester integration suite, Module 1
tests/AgHealth.Tests.ps1 Pester integration suite, Module 2
.github/workflows/ci.yml CI: build the AG, run both suites, on every push
```

## Roadmap

- [x] Logins: SID, hash, roles, server permissions
- [x] Agent jobs: step and schedule hashing, role-aware gate
- [x] Privilege separation, audit trail, one-command lab, CI
- [x] New databases joining the AG automatically (only when ready)
- [x] Failover drill: the synced logins and jobs work on the new primary, and sync follows it
- [ ] Scale test: 1,000 logins and 500 jobs, timed
- [ ] Linked servers and credentials
- [x] Health collector: replicas, databases, queues, estimated data loss and recovery time
- [x] Alert engine: rules as data, consecutive-breach opening, escalation, measured resolution, retention
- [ ] Scheduled collection and notifications (email, Teams)
- [ ] Live dashboard: topology, data flow, lag, alerts and sync status
- [ ] RCA toolkit and MCP tools

---

**Louis Achungo** · Senior SQL Server DBA and Architect · [LinkedIn](https://www.linkedin.com/in/louis-achungo) · [SQL IT Tech Solutions](https://sql-it-techsolutions.com/)
