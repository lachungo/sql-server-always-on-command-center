# Always On Command Center

**Sync, live health, alerts and root-cause analysis for SQL Server Always On Availability Groups.**

[![Integration tests](https://github.com/lachungo/sql-server-always-on-command-center/actions/workflows/ci.yml/badge.svg)](https://github.com/lachungo/sql-server-always-on-command-center/actions/workflows/ci.yml)

> 🚧 **Active work in progress.** Module 1 (AG Sync) is complete and tested on every push against a real
> 3-replica Availability Group. The live dashboard, alerting and RCA modules are being built on the same foundation.

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
| **AG Sync** | Detects and fixes drift in logins and Agent jobs across replicas, safely, with a full audit trail | ✅ Complete, 22 integration tests |
| **Health collector & alerts** | Snapshots roles, sync state, send/redo queues and lag; alerts on state changes, RPO breaches and disconnects | 🔨 Next |
| **Live dashboard** | Interactive AG topology with animated data flow, lag, health assessment and sync status | 🔨 Planned |
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

| Drift found | What AgSync does |
|---|---|
| Missing on a secondary | Creates it |
| Different on a secondary | Rebuilds or alters it (a SID mismatch only if nothing on the target depends on it) |
| Only on a secondary (possible drop) | **Alert only**. Never dropped automatically |
| Job without a primary-replica guard | **Blocked** until the guard is added |
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
  | `agsync_detect` | `VIEW SERVER STATE`, `VIEW ANY DEFINITION`, `SELECT` on msdb job tables | Scheduled drift detection |
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

## Tests

22 integration tests run against a **real Availability Group**, not mocks. Each scenario builds its own drift,
runs AgSync with the least-privilege accounts, asserts the outcome, and cleans up.

On every push, [GitHub Actions](.github/workflows/ci.yml) builds the full 3-replica AG in Docker with throwaway
passwords and runs the suite. No secrets are stored in the repository.

| Platform | Status |
|---|---|
| SQL Server 2025 on Ubuntu 22.04 and 24.04 runners | **Required** on every push |
| SQL Server 2022 CU26 on GitHub-hosted runners | **Required** on every push |
| SQL Server 2022 CU27 (latest), locally (Docker on Windows) | Passing: all 22 tests |
| SQL Server 2022 CU27 (latest) on GitHub-hosted runners | **Known issue**, tracked as experimental (see below) |

**Known issue, found and bisected by this CI.** On GitHub-hosted runners, the SQL Server 2022 **CU27** container image
(build 16.0.4305.5 when tested) spins at 100% CPU when another replica connects to its AG endpoint, so the replica
never joins (error 47106, then timeouts). A parallel run of every 2022 cumulative update showed **CU17 through CU26
pass** on the same runners, as does SQL Server 2025, which isolates the change to **CU27**. The same CU27 image passes
on an Intel desktop, which points to an interaction between that image and the runners' hardware or kernel rather
than to AgSync. The experimental job keeps tracking it on every push.

```powershell
$c = New-PesterContainer -Path ./tests/AgSync.Tests.ps1 -Data @{
         Replica = $lab.Replica; AgName = $lab.AgName; ControlInstance = $lab.ControlInstance
         AdminCredential = $sa; ApplyCredential = $app; DetectCredential = $det; ControlCredential = $ctlCred }
Invoke-Pester -Container $c -Output Detailed
```

## Repository layout

```
AgSync.psm1              the module: Get-AgSyncDrift, Invoke-AgSync
sql/ControlDb.sql        control database schema (run on the controller)
sql/AgSyncAccounts.sql   msdb permissions for the detect account (run on every replica)
lab/New-AgLab.ps1        one-command lab: containers, certificates, endpoints, AG, seeding, accounts
lab/docker-compose.yml   3 replicas + controller
tests/AgSync.Tests.ps1   Pester integration suite
.github/workflows/ci.yml CI: build the AG, run the tests, on every push
```

## Roadmap (AG Sync and platform)

- [x] Logins: SID, hash, roles, server permissions
- [x] Agent jobs: step and schedule hashing, role-aware gate
- [x] Privilege separation, audit trail, one-command lab, CI
- [ ] New databases joining the AG automatically
- [ ] Failover drills: sync follows the new primary
- [ ] Scale test: 1,000 logins and 500 jobs, timed
- [ ] Linked servers and credentials
- [ ] Health collector and alert engine
- [ ] Live dashboard: topology, data flow, lag, alerts and sync status
- [ ] RCA toolkit and MCP tools

---

**Louis Achungo** · Senior SQL Server DBA and Architect · [LinkedIn](https://www.linkedin.com/in/louis-achungo) · [SQL IT Tech Solutions](https://sql-it-techsolutions.com/)
