#Requires -Modules Microsoft.Graph.Users
<#
.SYNOPSIS
    Read-only check of stamp/sync state for the users in the stamp list.

.DESCRIPTION
    For each row reports one of:
      SYNCED               synced from on-premises and the ImmutableId matches the CSV
      STAMPED-NOT-SYNCED   stamped, waiting to enter Connect scope (expected before their wave)
      NOT-STAMPED          cloud user has no ImmutableId
      MISMATCH             cloud ImmutableId differs from the CSV (investigate before syncing)
      SYNCED-MISMATCH      synced, but with a different ImmutableId (investigate immediately)
      MISSING              CloudId not found in the tenant
    Also lists synced users that are NOT in the stamp list (unexpected objects, e.g. duplicates created
    by an in-scope user who was never stamped). Writes a report CSV to .\logs\. Makes no changes.

.EXAMPLE
    .\06-Test-SyncStatus.ps1
.EXAMPLE
    .\06-Test-SyncStatus.ps1 -UPN pilot.user@contoso.com
.EXAMPLE
    .\06-Test-SyncStatus.ps1 -Wave 1
#>
[CmdletBinding()]
param(
    [string]$CsvPath = (Join-Path $PSScriptRoot '..\data\stamp_list.csv'),
    [string]$LogDir  = (Join-Path $PSScriptRoot '..\logs'),
    [string[]]$UPN,
    [string]$Wave,
    [switch]$UseDeviceCode
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

Initialize-Run -Name 'Test-SyncStatus' -LogDir $LogDir -Mode 'RUN'
Connect-GraphSession -UseDeviceCode:$UseDeviceCode -Scopes 'User.Read.All'

$all  = Import-StampList -Path $CsvPath
$rows = $all
if ($UPN)  { $rows = @($rows | Where-Object { $UPN -contains $_.UPN }) }
if ($Wave) { $rows = @($rows | Where-Object { $_.Wave -eq $Wave }) }
if ($rows.Count -eq 0) { throw 'No rows selected.' }

Write-Log 'Loading cloud users...'
$users = @(Get-MgUser -All -Property Id, UserPrincipalName, OnPremisesSyncEnabled, OnPremisesImmutableId, OnPremisesLastSyncDateTime)
$byId  = @{}
foreach ($u in $users) { $byId[$u.Id] = $u }

$report = foreach ($r in $rows) {
    $u = $byId[$r.CloudId]
    if (-not $u) { $state = 'MISSING' }
    elseif ($u.OnPremisesSyncEnabled -and $u.OnPremisesImmutableId -ceq $r.ImmutableId) { $state = 'SYNCED' }
    elseif ($u.OnPremisesSyncEnabled)                                                    { $state = 'SYNCED-MISMATCH' }
    elseif (-not $u.OnPremisesImmutableId)                                               { $state = 'NOT-STAMPED' }
    elseif ($u.OnPremisesImmutableId -ceq $r.ImmutableId)                                { $state = 'STAMPED-NOT-SYNCED' }
    else                                                                                 { $state = 'MISMATCH' }
    [pscustomobject]@{
        UPN = $r.UPN; State = $state; CloudId = $r.CloudId
        SyncEnabled = if ($u) { $u.OnPremisesSyncEnabled } else { $null }
        LastSync    = if ($u) { $u.OnPremisesLastSyncDateTime } else { $null }
    }
}
$report = @($report)

$report | Group-Object State | Sort-Object Name | ForEach-Object {
    $lvl = if ($_.Name -in 'SYNCED', 'STAMPED-NOT-SYNCED') { 'OK' } else { 'WARN' }
    Write-Log ('{0,-20} {1}' -f $_.Name, $_.Count) $lvl
}
$report | Where-Object { $_.State -notin 'SYNCED', 'STAMPED-NOT-SYNCED' } | ForEach-Object {
    Write-Log "$($_.State): $($_.UPN)" 'WARN'
}

# unexpected synced objects (anything synced that is not in the full stamp list)
$expected = @{}
foreach ($r in $all) { $expected[$r.CloudId.ToLower()] = $true }
$unexpected = @($users | Where-Object { $_.OnPremisesSyncEnabled -and -not $expected.ContainsKey($_.Id.ToLower()) })
if ($unexpected.Count -gt 0) {
    Write-Log "$($unexpected.Count) synced user(s) are NOT in the stamp list (check for duplicates / unstamped in-scope users):" 'WARN'
    $unexpected | ForEach-Object { Write-Log "  $($_.UserPrincipalName) | $($_.Id)" 'WARN' }
}
else { Write-Log 'No unexpected synced users.' 'OK' }

$out = $script:ResultLog -replace '_results\.csv$', '_report.csv'
$report | Export-Csv -Path $out -NoTypeInformation -Encoding UTF8
Write-Log "Report: $out" 'OK'
