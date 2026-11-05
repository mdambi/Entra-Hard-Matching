<#
.SYNOPSIS
    Joins the AD and Entra backups into a verified stamp list plus exception reports (offline, no connections).

.DESCRIPTION
    Matches AD users to cloud users on UPN (case-insensitive) and only emits clean 1:1 rows.
    Output (default .\data\):
      stamp_list.csv        UPN,CloudId,ImmutableId,SamAccountName,Wave,Notes   <- input for scripts 04/05
      review_needed.csv     matched but unsafe (mail mismatch, already synced, different ImmutableId, duplicates...)
      ad_not_in_entra.csv   AD users with no cloud account (would become NEW cloud objects if synced)
      entra_not_in_ad.csv   cloud users with no AD account (shared mailboxes, service accounts, ex-staff...)

.EXAMPLE
    .\03-Build-StampList.ps1 -AdCsv .\backups\AD_20261104_1000\ad_users.csv -CloudCsv .\backups\Entra_20261104_1005\cloud_users.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AdCsv,
    [Parameter(Mandatory)][string]$CloudCsv,
    [string]$OutDir = (Join-Path $PSScriptRoot '..\data'),
    [switch]$AllowMailMismatch
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
Initialize-Run -Name 'Build-StampList' -LogDir (Join-Path $OutDir 'logs') -Mode 'RUN'

$ad    = @(Import-Csv $AdCsv)
$cloud = @(Import-Csv $CloudCsv)
foreach ($need in @(@{ N = 'AD'; R = $ad; C = 'SamAccountName', 'UserPrincipalName', 'mail', 'ImmutableId' },
                    @{ N = 'Cloud'; R = $cloud; C = 'Id', 'UserPrincipalName', 'Mail', 'OnPremisesSyncEnabled', 'OnPremisesImmutableId' })) {
    if ($need.R.Count -eq 0) { throw "$($need.N) CSV has no rows" }
    $missing = $need.C | Where-Object { $_ -notin $need.R[0].PSObject.Properties.Name }
    if ($missing) { throw "$($need.N) CSV is missing column(s): $($missing -join ', ')" }
}
Write-Log "AD rows: $($ad.Count) | Cloud rows: $($cloud.Count)"

# ---- cloud lookup (skip guests)
$cloudMap = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
$guests = 0
foreach ($c in $cloud) {
    $u = "$($c.UserPrincipalName)".Trim()
    if ($u -like '*#EXT#*') { $guests++; continue }
    if ($u -and -not $cloudMap.ContainsKey($u)) { $cloudMap[$u] = $c }
}
Write-Log "Cloud users considered: $($cloudMap.Count) (skipped $guests #EXT# guests)"

# ---- AD duplicates
$adWithUpn = @($ad | Where-Object { "$($_.UserPrincipalName)".Trim() })
$noUpn     = $ad.Count - $adWithUpn.Count
$dupUpn = @($adWithUpn | Group-Object { $_.UserPrincipalName.Trim().ToLower() } | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
$dupImm = @($adWithUpn | Group-Object -Property ImmutableId -CaseSensitive | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
Write-Log "AD accounts without UPN (Administrator, Guest, krbtgt etc.) skipped: $noUpn"

$stamp = New-Object System.Collections.Generic.List[object]
$review = New-Object System.Collections.Generic.List[object]
$adOnly = New-Object System.Collections.Generic.List[object]
$adUpnSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

foreach ($a in $adWithUpn) {
    $upn = $a.UserPrincipalName.Trim()
    [void]$adUpnSet.Add($upn)

    $reason = $null
    $c = $null
    if (-not $cloudMap.TryGetValue($upn, [ref]$c)) {
        $adOnly.Add([pscustomobject]@{ SamAccountName = $a.SamAccountName; UPN = $upn; Mail = $a.mail; ImmutableId = $a.ImmutableId })
        continue
    }
    if (-not "$($a.ImmutableId)".Trim())                      { $reason = 'AD ImmutableId is empty' }
    elseif ($dupUpn -contains $upn.ToLower())                 { $reason = 'Duplicate UPN in AD' }
    elseif ($dupImm -ccontains $a.ImmutableId)                { $reason = 'Duplicate ImmutableId in AD' }
    elseif ($c.OnPremisesSyncEnabled -eq 'True')              { $reason = 'Cloud user is already synced' }
    elseif ($c.OnPremisesImmutableId -and $c.OnPremisesImmutableId -ceq $a.ImmutableId) { $reason = 'Already stamped with this value (no action needed)' }
    elseif ($c.OnPremisesImmutableId)                         { $reason = "Cloud user already has a different ImmutableId ($($c.OnPremisesImmutableId))" }
    elseif (-not $AllowMailMismatch -and $a.mail -and $c.Mail -and ($a.mail -ne $c.Mail)) {
        $reason = "Mail differs (AD: $($a.mail) | Cloud: $($c.Mail))"
    }

    if ($reason) {
        $review.Add([pscustomobject]@{ UPN = $upn; SamAccountName = $a.SamAccountName; CloudId = $c.Id; ImmutableId = $a.ImmutableId; Reason = $reason })
    }
    else {
        $stamp.Add([pscustomobject]@{
            UPN = $upn; CloudId = $c.Id; ImmutableId = $a.ImmutableId
            SamAccountName = $a.SamAccountName; Wave = ''; Notes = ''
        })
    }
}

$cloudOnly = @($cloudMap.Keys | Where-Object { -not $adUpnSet.Contains($_) } | ForEach-Object {
    $c = $cloudMap[$_]
    [pscustomobject]@{ Id = $c.Id; UPN = $c.UserPrincipalName; Mail = $c.Mail }
})

function Save-Csv($Items, $Name) {
    $path = Join-Path $OutDir $Name
    if (@($Items).Count -gt 0) { $Items | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8 }
    elseif (Test-Path $path)   { Remove-Item $path }
}
Save-Csv $stamp     'stamp_list.csv'
Save-Csv $review    'review_needed.csv'
Save-Csv $adOnly    'ad_not_in_entra.csv'
Save-Csv $cloudOnly 'entra_not_in_ad.csv'

Write-Log ('Stamp list (clean 1:1)   : {0}' -f $stamp.Count) 'OK'
Write-Log ('Review needed            : {0}' -f $review.Count) $(if ($review.Count) { 'WARN' } else { 'INFO' })
Write-Log ('AD only (no cloud match) : {0}  -> would be NEW cloud objects if synced' -f $adOnly.Count) $(if ($adOnly.Count) { 'WARN' } else { 'INFO' })
Write-Log ('Cloud only (no AD match) : {0}' -f $cloudOnly.Count)
Write-Log "Files written to: $OutDir"
Write-Log 'Next: review review_needed.csv and ad_not_in_entra.csv, optionally fill the Wave column, then run 04 (pilot) and 05 (bulk) in dry-run mode.'
