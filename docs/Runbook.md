# Runbook: hard match for on-prem users to Entra ID

Hard match = set each cloud user's `ImmutableId` to the Base64 of the on-prem anchor, so Entra Connect
links the AD object to the existing cloud object instead of creating a duplicate.

**Stamping does nothing by itself.** A user only becomes "Synced from on-premises" when their AD object
is inside Connect's scope and Connect exports it. Scope is the rollout control.

## 0. Prerequisites
- PowerShell 5.1+ (7 works for the Graph scripts). Modules: `Microsoft.Graph` (Users, Groups, Identity.DirectoryManagement); `ActiveDirectory` (RSAT) for scripts 01 and 04.
- Entra role able to update users (e.g. User Administrator) and consent to the Graph scopes the scripts request.
- UPN suffixes verified in the tenant, and **Managed** (not Federated). Check: `(Get-MgDomain -DomainId contoso.com).AuthenticationType`.
- Run IdFix; fix duplicate `proxyAddresses`/`mail` and UPN problems.
- Exchange hybrid? Confirm remote-mailbox attributes on-prem before users enter scope.

## 1. Backup (read-only)
```powershell
.\scripts\01-Backup-AD.ps1
.\scripts\02-Backup-Entra.ps1 -UseDeviceCode
```
Outputs go to `backups\AD_<time>\` and `backups\Entra_<time>\` with a `manifest.txt` (row counts, SHA256).
On the Connect server, optionally export its configuration: `Get-ADSyncServerConfiguration -Path <folder>`.

## 2. Build and review the stamp list
```powershell
.\scripts\03-Build-StampList.ps1 -AdCsv .\backups\AD_<time>\ad_users.csv -CloudCsv .\backups\Entra_<time>\cloud_users.csv
```
Review `data\review_needed.csv` and `data\ad_not_in_entra.csv`. Optionally fill the `Wave` column in `data\stamp_list.csv`.
**AD-only users must stay out of Connect scope until decided.** In scope but unstamped, they either soft-match (UPN / primary SMTP) or become new cloud objects. Both are uncontrolled.

## 3. Configure Entra Connect (fresh install)
- **Custom** installation (not Express).
- Source anchor: **Let Azure manage the source anchor** (`ms-DS-ConsistencyGuid`). This is effectively permanent.
- **Domain/OU filtering:** tick ONLY the pilot OU (never the domain root or a parent OU).
- **Filter users and devices:** choose **Synchronize all users and devices**. Group-based filtering is a pilot-only feature, only direct members count, and it can't be re-enabled once turned off. It also hides users with `cloudFiltered = True`.
- Optional features: Password Hash Sync (users will sign in with their AD password after sync).
- Keep groups out of the pilot OU. Groups sync with everything else in scope.
- Pause while configuring: `Set-ADSyncScheduler -SyncCycleEnabled $false`.

## 4. Pilot
```powershell
.\scripts\04-Set-ImmutableId-Pilot.ps1 -UPN pilot.user@contoso.com                  # dry run
.\scripts\04-Set-ImmutableId-Pilot.ps1 -UPN pilot.user@contoso.com -Apply -UseDeviceCode
```
Then on the Connect server:
1. Check the pilot OU contains only stamped users: `Get-ADObject -SearchBase "<pilot OU DN>" -Filter * | Group-Object ObjectClass`.
2. Synchronization Service Manager: run Full Import then Full Synchronization on the AD connector.
3. AAD connector, Search Connector Space, Pending Export. Expect one **Update** per pilot user. An **Add** means the match failed: stop.
4. Run Export on the AAD connector, then `Set-ADSyncScheduler -SyncCycleEnabled $true`.
5. Verify: `.\scripts\06-Test-SyncStatus.ps1 -UPN pilot.user@contoso.com` should report `SYNCED`.
6. Check mailbox, OneDrive, Teams, licence and sign-in (AD password). Soak 48 to 72 hours.

## 5. Stamp everyone else (safe while scope is still the pilot OU only)
```powershell
.\scripts\05-Set-ImmutableId-Bulk.ps1                      # dry run: expect ready=N, no unexpected skips
.\scripts\05-Set-ImmutableId-Bulk.ps1 -Apply -UseDeviceCode
.\scripts\06-Test-SyncStatus.ps1                           # everyone STAMPED-NOT-SYNCED except the pilot
```
Use `-Wave <n>` to stamp wave by wave instead, and `-Limit <n>` for a trial slice.

## 6. Roll out in waves (as users/devices are ready)
For each wave:
1. Confirm every user going into scope is in `stamp_list.csv` and stamped.
2. Add the wave's OU to Connect scope (or move users into the synced OU). Use the wizard for OU changes.
3. Full Import and Sync, check Pending Export (Updates only), Export.
4. `06-Test-SyncStatus.ps1 -Wave <n>`, plus the "unexpected synced users" section of its output.
5. Spot-check users, get go/no-go, schedule the next wave outside business hours and month-end.

Communicate before each wave: the password becomes the AD password, MFA is unchanged, who to contact.

## 7. Groups (after most users are in)
Compare `backups\...\ad_groups.csv` with `cloud_groups.csv` for name/email clashes. Check whether any cloud group drives licensing, Conditional Access or Teams before syncing its on-prem twin. Synced groups become read-only in the cloud, and removing one from scope deletes it.

## 8. Closeout
Document the final mapping, logs and exceptions. Keep the backups. Re-check `BlockCloudObjectTakeoverThroughHardMatchEnabled` and `BlockSoftMatchEnabled` are set as intended. Hand over support procedures.

---

# Troubleshooting

| Symptom | Likely cause | Check / fix |
|---|---|---|
| Stamped, but Entra shows not synced | User not in scope, or Connect never exported it | Normal until the user enters scope. Otherwise see below. |
| `cloudFiltered = True` on the metaverse object | Group-based filter (user not a **direct** member), or a custom inbound rule | Switch to "Synchronize all users and devices" + OU scope, or fix the rule. Never edit default rules; clone them. |
| `OnPremisesLastSyncDateTime` empty | Entra export never ran for the user | Sync Service Manager: Operations: AAD Export row. Zero Adds/Updates = not provisioned (check cloudFiltered). |
| Pending export shows **Add** | Stamp doesn't match the anchor | Stop. Compare CSV value with the connector-space anchor (Base64). |
| `AttributeValueMustBeUnique` / quarantined | UPN or proxyAddresses collides with another cloud object | Compare `ProxyAddresses` of both objects; fix before syncing. |
| Stamp fails (script 04/05) | Federated domain, user already synced, or ImmutableId in use | Read the `Detail` column in the results CSV. Federated: switch UPN to `onmicrosoft.com`, stamp, switch back. |
| Sync commands return data but Entra shows no sync | Wrong server, or a second Connect install in staging | `Get-ADSyncScheduler` on each DC: one active, others `StagingModeEnabled = True`. |
| `Start-ADSyncSyncCycle` says Success but nothing changed | It only means the cycle ran | Use Sync Service Manager (Operations) to see the per-connector Adds/Updates/Errors. |

## Rollback
- **Before the user syncs:** `04-Set-ImmutableId-Pilot.ps1 -UPN <upn> -Rollback -Apply` clears the stamp (refuses if synced or the value differs). Verify clearing works on your tenant with a pilot user first.
- **After the user syncs:** do not clear the stamp. Removing a user from scope soft-deletes the cloud object (restorable from the Entra recycle bin for 30 days). Use the backups in `backups\` to compare licences, groups and roles after any restore.
