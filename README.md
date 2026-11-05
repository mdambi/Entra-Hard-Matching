# Entra-hard-match

Toolkit for hard-matching on-prem Active Directory users to existing Entra ID users with Entra Connect Sync,
in controlled waves. Every script that can change something is **dry-run by default** and **logs every action**.

## Repo layout
```
scripts/
  01-Backup-AD.ps1              read-only AD export (users, groups, membership, OUs) + manifest
  02-Backup-Entra.ps1           read-only Entra export (users, licences, groups, roles, domains) + manifest
  03-Build-StampList.ps1        offline join of both exports -> stamp_list.csv + exception reports
  04-Set-ImmutableId-Pilot.ps1  stamp / roll back named pilot users (dry run, live AD check)
  05-Set-ImmutableId-Bulk.ps1   bulk stamp from the CSV (dry run, waves, confirmation gate)
  06-Test-SyncStatus.ps1        read-only status report + unexpected-synced-user check
  lib/Common.ps1                shared logging, CSV validation and safety checks
docs/
  CSV-FORMAT.md                 the stamp_list.csv spec and all file formats
  RUNBOOK.md                    step-by-step process, Connect settings, troubleshooting, rollback
samples/                        fake example CSVs
data/                           your real stamp_list.csv etc. (git-ignored)
```

## Quick start
```powershell
# 1. Backups (read-only)
.\scripts\01-Backup-AD.ps1
.\scripts\02-Backup-Entra.ps1 -UseDeviceCode

# 2. Build and review the stamp list
.\scripts\03-Build-StampList.ps1 -AdCsv .\backups\AD_<time>\ad_users.csv -CloudCsv .\backups\Entra_<time>\cloud_users.csv

# 3. Pilot: dry run first, then apply
.\scripts\04-Set-ImmutableId-Pilot.ps1 -UPN pilot.user@contoso.com
.\scripts\04-Set-ImmutableId-Pilot.ps1 -UPN pilot.user@contoso.com -Apply

# 4. Sync the pilot OU in Entra Connect (see docs\RUNBOOK.md), then verify
.\scripts\06-Test-SyncStatus.ps1 -UPN pilot.user@contoso.com

# 5. Everyone else: dry run, then apply (optionally per wave)
.\scripts\05-Set-ImmutableId-Bulk.ps1
.\scripts\05-Set-ImmutableId-Bulk.ps1 -Apply
```

## Key rules
1. **Stamping is not syncing.** The ImmutableId only links when the AD object enters Connect scope. Scope is your rollout control.
2. **Only stamped users go into scope.** An in-scope user without a stamp either soft-matches or becomes a new cloud object.
3. **Scope by OU** with "Synchronize all users and devices". Don't use group filtering beyond a throwaway pilot.
4. **Always dry run first**, and read the results CSV in `logs\`.
5. **Check the Connect pending export before exporting**: Updates are good, Adds mean the match failed.
6. Federated UPN domains can't be stamped. Switch the UPN to `onmicrosoft.com` temporarily.

## Safety features
- CSV validated on every run (columns, formats, duplicates) before anything connects.
- Per-row checks: federated domain, CloudId exists, UPN agrees, not already synced, no conflicting ImmutableId, ImmutableId not held by someone else.
- Live re-check immediately before each stamp, and a read-back verification after it.
- Idempotent: re-running skips users that are already done.
- Confirmation gate (`type STAMP`) when stamping more than 20 users.
- Pilot script re-verifies the value against live AD before stamping.
- `.gitignore` keeps `data\`, `backups\` and `logs\` out of the repo.

## Status of testing
These scripts have not been executed in your tenant or linted with PowerShell tooling yet.
Run them in dry-run mode first, and test the pilot script on one user before using the bulk script.
