#Requires -Modules Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement
<#
.SYNOPSIS
    Bulk-stamp ImmutableIds from the stamp list. DRY RUN by default.

.DESCRIPTION
    Validates the whole CSV, loads the tenant once, runs the safety checks on every row, prints a plan
    summary, and only stamps when -Apply is given. Stamping is idempotent (re-runs skip finished rows).
    Stamping alone does not sync anyone: users only link when they enter Entra Connect scope.
    Every run writes a log and a results CSV to .\logs\.

.PARAMETER Wave
    Only process rows whose Wave column equals this value (optional column in the CSV).
.PARAMETER Limit
    Process only the first N rows (useful for a small trial run).
.PARAMETER NoPrompt
    Skip the "type STAMP" confirmation (it appears when more than 20 users will be changed).

.EXAMPLE
    .\05-Set-ImmutableId-Bulk.ps1                                  # dry run, whole list
.EXAMPLE
    .\05-Set-ImmutableId-Bulk.ps1 -Wave 1 -Apply -UseDeviceCode    # stamp wave 1 only
#>
[CmdletBinding()]
param(
    [string]$CsvPath = (Join-Path $PSScriptRoot '..\data\stamp_list.csv'),
    [string]$LogDir  = (Join-Path $PSScriptRoot '..\logs'),
    [string]$Wave,
    [int]$Limit = 0,
    [switch]$Apply,
    [switch]$NoPrompt,
    [switch]$UseDeviceCode
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$mode = if ($Apply) { 'APPLY' } else { 'DRYRUN' }
Initialize-Run -Name 'Set-ImmutableId-Bulk' -LogDir $LogDir -Mode $mode
if (-not $Apply) { Write-Log 'DRY RUN: no changes will be made. Add -Apply to execute.' 'WARN' }

Connect-GraphSession -UseDeviceCode:$UseDeviceCode -Scopes 'User.ReadWrite.All', 'Domain.Read.All'

# ---- load + filter the list
$rows = Import-StampList -Path $CsvPath
Write-Log "CSV valid: $($rows.Count) rows ($CsvPath)" 'OK'
if ($Wave) {
    if ('Wave' -notin $rows[0].PSObject.Properties.Name) { throw '-Wave was given but the CSV has no Wave column.' }
    $rows = @($rows | Where-Object { $_.Wave -eq $Wave })
    if ($rows.Count -eq 0) { throw "No rows with Wave = '$Wave'." }
    Write-Log "Filtered to wave '$Wave': $($rows.Count) rows"
}
if ($Limit -gt 0) { $rows = @($rows | Select-Object -First $Limit); Write-Log "Limited to first $($rows.Count) rows" }

# ---- plan
$domainAuth = Get-DomainAuthMap -Upns $rows.UPN
$snapshot   = Get-CloudSnapshot

$plan = @(foreach ($r in $rows) {
    $c = Test-StampCandidate -Row $r -Snapshot $snapshot -DomainAuth $domainAuth
    [pscustomobject]@{ Row = $r; Status = $c.Status; Detail = $c.Detail }
})

$plan | Where-Object { $_.Status -ne 'READY' } | ForEach-Object {
    $lvl = if ($_.Status -eq 'DONE') { 'INFO' } else { 'WARN' }
    Write-Log ('{0,-5} {1} | {2}' -f $_.Status, $_.Row.UPN, $_.Detail) $lvl
    Add-Result -Upn $_.Row.UPN -Action $_.Status -Detail $_.Detail -CloudId $_.Row.CloudId -ImmutableId $_.Row.ImmutableId
}
$ready = @($plan | Where-Object { $_.Status -eq 'READY' })
$done  = @($plan | Where-Object { $_.Status -eq 'DONE' }).Count
$skip  = @($plan | Where-Object { $_.Status -eq 'SKIP' }).Count
Write-Log ("PLAN | ready={0} already-done={1} skipped={2} total={3}" -f $ready.Count, $done, $skip, $plan.Count) 'OK'

# ---- dry run ends here
if (-not $Apply) {
    foreach ($p in $ready) { Add-Result -Upn $p.Row.UPN -Action 'WOULD STAMP' -Detail $p.Detail -CloudId $p.Row.CloudId -ImmutableId $p.Row.ImmutableId }
    Write-Log "Dry run complete. $($ready.Count) users would be stamped. Review the results CSV, then re-run with -Apply." 'WARN'
    return
}

# ---- confirmation gate
if ($ready.Count -gt 20 -and -not $NoPrompt) {
    $answer = Read-Host "About to stamp $($ready.Count) users in tenant $((Get-MgContext).TenantId). Type STAMP to continue"
    if ($answer -cne 'STAMP') { Write-Log 'Aborted by operator.' 'WARN'; return }
}

# ---- apply
$ok = 0; $fail = 0; $i = 0
foreach ($p in $ready) {
    $i++
    Write-Progress -Activity 'Stamping ImmutableIds' -Status $p.Row.UPN -PercentComplete (100 * $i / $ready.Count)
    try {
        $res = Set-CloudImmutableId -Row $p.Row
        Add-Result -Upn $p.Row.UPN -Action 'STAMPED' -Detail $res -CloudId $p.Row.CloudId -ImmutableId $p.Row.ImmutableId
        Write-Log "STAMPED $($p.Row.UPN) ($res)" 'OK'
        $ok++
    }
    catch {
        Add-Result -Upn $p.Row.UPN -Action 'FAIL' -Detail $_.Exception.Message -CloudId $p.Row.CloudId -ImmutableId $p.Row.ImmutableId
        Write-Log "FAILED  $($p.Row.UPN) | $($_.Exception.Message)" 'ERROR'
        $fail++
    }
}
Write-Progress -Activity 'Stamping ImmutableIds' -Completed

Write-Log ("DONE | stamped={0} failed={1} skipped={2} already-done={3}" -f $ok, $fail, $skip, $done) $(if ($fail) { 'ERROR' } else { 'OK' })
Write-Log 'Reminder: stamping does not sync anyone. Users link only when they enter Entra Connect scope. Verify with 06-Test-SyncStatus.ps1 after each sync.'
if ($fail) { exit 1 }
