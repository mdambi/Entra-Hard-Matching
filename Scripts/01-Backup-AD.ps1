#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Read-only backup of on-prem AD users, groups, group membership and OUs.

.DESCRIPTION
    Writes timestamped CSVs to backups\AD_<timestamp>\ plus a manifest (row counts, SHA256).
    ad_users.csv includes the computed ImmutableId (Base64 of ms-DS-ConsistencyGuid, else objectGUID),
    which is the input for 03-Build-StampList.ps1. Makes NO changes to AD.

.EXAMPLE
    .\01-Backup-AD.ps1
.EXAMPLE
    .\01-Backup-AD.ps1 -SearchBase "OU=Staff,DC=ad,DC=kefri,DC=org" -Server DC-01
#>
[CmdletBinding()]
param(
    [string]$SearchBase,                                            # default: whole domain
    [string]$Server,                                                # optional DC to query
    [string]$OutDir = (Join-Path $PSScriptRoot '..\backups')
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$dir = Join-Path $OutDir ('AD_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Initialize-Run -Name 'Backup-AD' -LogDir $dir -Mode 'RUN'

$common = @{}
if ($SearchBase) { $common.SearchBase = $SearchBase }
if ($Server)     { $common.Server     = $Server }

try {
    # ---- users
    Write-Log 'Exporting users...'
    $userProps = 'mail', 'ObjectGUID', 'ms-DS-ConsistencyGuid', 'proxyAddresses', 'Enabled', 'DisplayName',
                 'Department', 'Title', 'whenCreated', 'whenChanged', 'LastLogonDate', 'PasswordLastSet'
    $users = @(Get-ADUser -Filter * -Properties $userProps @common)

    $users | Select-Object `
        SamAccountName, UserPrincipalName, mail,
        @{ n = 'ImmutableId';  e = { Get-AdImmutableId $_ } },
        @{ n = 'AnchorSource'; e = { if ($_.'ms-DS-ConsistencyGuid') { 'ms-DS-ConsistencyGuid' } else { 'objectGUID' } } },
        Enabled, DisplayName, Department, Title, DistinguishedName,
        @{ n = 'ObjectGUID';   e = { $_.ObjectGUID.ToString() } },
        @{ n = 'ProxyAddresses'; e = { $_.proxyAddresses -join ';' } },
        whenCreated, whenChanged, LastLogonDate, PasswordLastSet |
        Export-Csv -Path (Join-Path $dir 'ad_users.csv') -NoTypeInformation -Encoding UTF8
    Write-Log "Users: $($users.Count)" 'OK'

    # ---- groups + membership (from the 'member' attribute, no per-group queries)
    Write-Log 'Exporting groups and membership...'
    $groups = @(Get-ADGroup -Filter * -Properties mail, member, whenCreated @common)

    $groups | Select-Object Name, SamAccountName, GroupCategory, GroupScope, mail,
        @{ n = 'MemberCount'; e = { @($_.member).Count } }, DistinguishedName, whenCreated |
        Export-Csv -Path (Join-Path $dir 'ad_groups.csv') -NoTypeInformation -Encoding UTF8

    $groups | ForEach-Object {
        $g = $_
        foreach ($m in @($g.member)) {
            [pscustomobject]@{ GroupName = $g.Name; GroupDN = $g.DistinguishedName; MemberDN = $m }
        }
    } | Export-Csv -Path (Join-Path $dir 'ad_group_membership.csv') -NoTypeInformation -Encoding UTF8
    Write-Log "Groups: $($groups.Count)" 'OK'

    # ---- OUs
    Write-Log 'Exporting OUs...'
    Get-ADOrganizationalUnit -Filter * @common |
        Select-Object Name, DistinguishedName, ProtectedFromAccidentalDeletion |
        Export-Csv -Path (Join-Path $dir 'ad_ous.csv') -NoTypeInformation -Encoding UTF8

    Write-Manifest -Dir $dir
    Write-Log "AD backup complete: $dir" 'OK'
    Write-Log 'Optional (run on the Connect server): Get-ADSyncServerConfiguration -Path <folder>  to export the sync configuration.'
}
catch {
    Write-Log "Backup failed: $($_.Exception.Message)" 'ERROR'
    throw
}
