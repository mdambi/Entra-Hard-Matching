#Requires -Modules Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement
<#
.SYNOPSIS
    Stamp (or roll back) the ImmutableId for one or a few named pilot users. DRY RUN by default.

.DESCRIPTION
    For each UPN: finds the row in the stamp list, re-verifies the value against LIVE AD (if the
    ActiveDirectory module is available), runs the cloud safety checks, then stamps with read-back.
    Nothing changes unless -Apply is specified. Every run writes a log and a results CSV to .\logs\.

    -Rollback clears a stamp that has NOT synced yet (refuses if the user is synced or the value differs).
    Clearing via Graph PATCH is not guaranteed on every tenant: verify in a lab or on the pilot user first.

.EXAMPLE
    .\04-Set-ImmutableId-Pilot.ps1 -UPN pilot.user@contoso.com                    # dry run
.EXAMPLE
    .\04-Set-ImmutableId-Pilot.ps1 -UPN pilot.user@contoso.com -Apply -UseDeviceCode
.EXAMPLE
    .\04-Set-ImmutableId-Pilot.ps1 -UPN pilot.user@contoso.com -Rollback -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$UPN,
    [string]$CsvPath = (Join-Path $PSScriptRoot '..\data\stamp_list.csv'),
    [string]$LogDir  = (Join-Path $PSScriptRoot '..\logs'),
    [switch]$Apply,
    [switch]$Rollback,
    [switch]$SkipAdCheck,
    [switch]$UseDeviceCode
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$mode = if ($Apply) { 'APPLY' } else { 'DRYRUN' }
$name = if ($Rollback) { 'Pilot-Rollback' } else { 'Pilot-Stamp' }
Initialize-Run -Name $name -LogDir $LogDir -Mode $mode
if (-not $Apply) { Write-Log 'DRY RUN: no changes will be made. Add -Apply to execute.' 'WARN' }

Connect-GraphSession -UseDeviceCode:$UseDeviceCode -Scopes 'User.ReadWrite.All', 'Domain.Read.All'

$rows = Import-StampList -Path $CsvPath
$selected = foreach ($u in $UPN) {
    $match = @($rows | Where-Object { $_.UPN -ieq $u.Trim() })
    if ($match.Count -ne 1) {
        Write-Log "'$u' matched $($match.Count) rows in $CsvPath (expected exactly 1)" 'ERROR'
        Add-Result -Upn $u -Action 'FAIL' -Detail "Matched $($match.Count) CSV rows"
        continue
    }
    $match[0]
}
$selected = @($selected)
if ($selected.Count -eq 0) { throw 'No valid pilot users selected.' }

$haveAd = (-not $SkipAdCheck) -and [bool](Get-Module -ListAvailable -Name ActiveDirectory)
if ($haveAd) { Write-Log 'ActiveDirectory module found: live AD verification enabled' }
else         { Write-Log 'Live AD verification NOT performed (module missing or -SkipAdCheck). Run this where RSAT is installed for the strongest check.' 'WARN' }

$domainAuth = Get-DomainAuthMap -Upns $selected.UPN
$snapshot   = Get-CloudSnapshot

$ok = 0; $fail = 0; $skip = 0
foreach ($row in $selected) {
    Write-Log "---- $($row.UPN) | CloudId=$($row.CloudId) | ImmutableId=$($row.ImmutableId)"

    # 1. Live AD verification
    if ($haveAd) {
        $adUsers = @(Get-ADUser -Filter "UserPrincipalName -eq '$($row.UPN)'" -Properties ObjectGUID, 'ms-DS-ConsistencyGuid')
        if ($adUsers.Count -ne 1) {
            Write-Log "Expected 1 AD user, found $($adUsers.Count). Skipping." 'ERROR'
            Add-Result $row.UPN 'FAIL' "AD lookup returned $($adUsers.Count) users" $row.CloudId $row.ImmutableId; $fail++; continue
        }
        $live = Get-AdImmutableId $adUsers[0]
        if ($live -cne $row.ImmutableId) {
            Write-Log "CSV ImmutableId differs from live AD ($live). Skipping." 'ERROR'
            Add-Result $row.UPN 'FAIL' "CSV value differs from live AD value $live" $row.CloudId $row.ImmutableId; $fail++; continue
        }
        Write-Log 'Live AD check passed' 'OK'
    }

    # 2a. Rollback path
    if ($Rollback) {
        $cur = $null
        if (-not $snapshot.ById.TryGetValue($row.CloudId, [ref]$cur)) { Write-Log 'CloudId not found' 'ERROR'; Add-Result $row.UPN 'FAIL' 'CloudId not found' $row.CloudId; $fail++; continue }
        if ($cur.OnPremisesSyncEnabled)        { Write-Log 'User is already synced. Refusing to clear. Use scope + recycle bin procedure instead.' 'ERROR'; Add-Result $row.UPN 'SKIP' 'Already synced' $row.CloudId; $skip++; continue }
        if (-not $cur.OnPremisesImmutableId)   { Write-Log 'Nothing to clear (no ImmutableId set)'; Add-Result $row.UPN 'SKIP' 'No ImmutableId set' $row.CloudId; $skip++; continue }
        if ($cur.OnPremisesImmutableId -cne $row.ImmutableId) { Write-Log 'Cloud value differs from CSV. Refusing to clear.' 'ERROR'; Add-Result $row.UPN 'SKIP' 'Cloud value differs from CSV' $row.CloudId; $skip++; continue }
        if (-not $Apply) { Write-Log 'WOULD CLEAR ImmutableId' 'WARN'; Add-Result $row.UPN 'WOULD CLEAR' '' $row.CloudId $row.ImmutableId; $ok++; continue }
        try {
            Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/users/$($row.CloudId)" `
                -Body (@{ onPremisesImmutableId = $null } | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop
            $after = Get-MgUser -UserId $row.CloudId -Property OnPremisesImmutableId -ErrorAction Stop
            if ($after.OnPremisesImmutableId) { throw 'Value still present after clear. Clearing may not be supported on this tenant.' }
            Write-Log 'ImmutableId cleared' 'OK'; Add-Result $row.UPN 'CLEARED' '' $row.CloudId $row.ImmutableId; $ok++
        }
        catch { Write-Log "Clear failed: $($_.Exception.Message)" 'ERROR'; Add-Result $row.UPN 'FAIL' $_.Exception.Message $row.CloudId $row.ImmutableId; $fail++ }
        continue
    }

    # 2b. Stamp path
    $check = Test-StampCandidate -Row $row -Snapshot $snapshot -DomainAuth $domainAuth
    # (if blocks, not switch: 'continue' inside a switch would not skip to the next user)
    if ($check.Status -eq 'DONE') { Write-Log $check.Detail 'OK';   Add-Result $row.UPN 'DONE' $check.Detail $row.CloudId $row.ImmutableId; $skip++; continue }
    if ($check.Status -eq 'SKIP') { Write-Log $check.Detail 'WARN'; Add-Result $row.UPN 'SKIP' $check.Detail $row.CloudId $row.ImmutableId; $skip++; continue }
    if (-not $Apply) {
        Write-Log 'WOULD STAMP (all checks passed)' 'WARN'
        Add-Result $row.UPN 'WOULD STAMP' $check.Detail $row.CloudId $row.ImmutableId; $ok++; continue
    }
    try {
        $res = Set-CloudImmutableId -Row $row
        Write-Log "Stamped and verified ($res)" 'OK'
        Add-Result $row.UPN 'STAMPED' $res $row.CloudId $row.ImmutableId; $ok++
    }
    catch {
        Write-Log "Stamp failed: $($_.Exception.Message)" 'ERROR'
        Add-Result $row.UPN 'FAIL' $_.Exception.Message $row.CloudId $row.ImmutableId; $fail++
    }
}

Write-Log ("Summary | ok/would-do={0} skipped={1} failed={2} | mode={3}" -f $ok, $skip, $fail, $mode) $(if ($fail) { 'ERROR' } else { 'OK' })

if ($Apply -and -not $Rollback -and $ok -gt 0) {
    Write-Log 'NEXT (Connect server): confirm Connect scope contains ONLY the pilot OU, then run a full import + full sync and check the pending export.'
    Write-Log 'Expect one UPDATE per pilot user (an ADD means the match failed). Then run 06-Test-SyncStatus.ps1.'
}
if ($fail) { exit 1 }
