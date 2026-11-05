#Requires -Modules Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement
<#
.SYNOPSIS
    Read-only backup of Entra ID users, licences, groups, membership, directory roles and domains.

.DESCRIPTION
    Writes timestamped CSVs to backups\Entra_<timestamp>\ plus a manifest (row counts, SHA256).
    cloud_users.csv is the input for 03-Build-StampList.ps1. Take this BEFORE any stamping or sync
    so licences, groups and role assignments can be compared or restored afterwards.
    Makes NO changes to the tenant.

.EXAMPLE
    .\02-Backup-Entra.ps1 -UseDeviceCode
.EXAMPLE
    .\02-Backup-Entra.ps1 -SkipGroupMembers      # faster; users, groups, roles and domains only
#>
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\backups'),
    [switch]$SkipGroupMembers,
    [switch]$UseDeviceCode
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$dir = Join-Path $OutDir ('Entra_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Initialize-Run -Name 'Backup-Entra' -LogDir $dir -Mode 'RUN'

Connect-GraphSession -UseDeviceCode:$UseDeviceCode -Scopes `
    'User.Read.All', 'Group.Read.All', 'GroupMember.Read.All', 'Directory.Read.All', 'Domain.Read.All'

try {
    # ---- users
    Write-Log 'Exporting users...'
    $props = 'Id', 'UserPrincipalName', 'DisplayName', 'Mail', 'MailNickname', 'AccountEnabled', 'UserType',
             'CreatedDateTime', 'OnPremisesSyncEnabled', 'OnPremisesImmutableId', 'OnPremisesLastSyncDateTime',
             'ProxyAddresses', 'AssignedLicenses', 'Department', 'JobTitle'
    $users = @(Get-MgUser -All -Property $props)

    $users | Select-Object `
        Id, UserPrincipalName, Mail, OnPremisesSyncEnabled, OnPremisesImmutableId,
        DisplayName, MailNickname, AccountEnabled, UserType, Department, JobTitle, CreatedDateTime,
        OnPremisesLastSyncDateTime,
        @{ n = 'ProxyAddresses'; e = { $_.ProxyAddresses -join ';' } },
        @{ n = 'LicenseSkuIds';  e = { @($_.AssignedLicenses | ForEach-Object { $_.SkuId }) -join ';' } } |
        Export-Csv -Path (Join-Path $dir 'cloud_users.csv') -NoTypeInformation -Encoding UTF8
    Write-Log "Users: $($users.Count)" 'OK'

    # ---- licence SKUs (maps SkuId -> name)
    Get-MgSubscribedSku | Select-Object SkuId, SkuPartNumber, ConsumedUnits,
        @{ n = 'EnabledUnits'; e = { $_.PrepaidUnits.Enabled } } |
        Export-Csv -Path (Join-Path $dir 'cloud_skus.csv') -NoTypeInformation -Encoding UTF8

    # ---- domains (shows Managed vs Federated)
    Get-MgDomain | Select-Object Id, AuthenticationType, IsDefault, IsVerified |
        Export-Csv -Path (Join-Path $dir 'cloud_domains.csv') -NoTypeInformation -Encoding UTF8

    # ---- groups
    Write-Log 'Exporting groups...'
    $groups = @(Get-MgGroup -All -Property Id, DisplayName, Mail, MailEnabled, SecurityEnabled, GroupTypes,
                                         OnPremisesSyncEnabled, MembershipRule, CreatedDateTime)
    $groups | Select-Object Id, DisplayName, Mail, MailEnabled, SecurityEnabled, OnPremisesSyncEnabled,
        MembershipRule, CreatedDateTime, @{ n = 'GroupTypes'; e = { $_.GroupTypes -join ';' } } |
        Export-Csv -Path (Join-Path $dir 'cloud_groups.csv') -NoTypeInformation -Encoding UTF8
    Write-Log "Groups: $($groups.Count)" 'OK'

    if (-not $SkipGroupMembers) {
        Write-Log 'Exporting group membership (one call per group)...'
        $i = 0
        $groups | ForEach-Object {
            $g = $_
            $i++
            Write-Progress -Activity 'Group membership' -Status $g.DisplayName -PercentComplete (100 * $i / [Math]::Max($groups.Count, 1))
            foreach ($m in @(Get-MgGroupMember -GroupId $g.Id -All)) {
                [pscustomobject]@{
                    GroupId    = $g.Id
                    GroupName  = $g.DisplayName
                    MemberId   = $m.Id
                    MemberType = $m.AdditionalProperties['@odata.type']
                    MemberUPN  = $m.AdditionalProperties['userPrincipalName']
                }
            }
        } | Export-Csv -Path (Join-Path $dir 'cloud_group_members.csv') -NoTypeInformation -Encoding UTF8
        Write-Progress -Activity 'Group membership' -Completed
    }

    # ---- directory role assignments
    Write-Log 'Exporting directory role members...'
    Get-MgDirectoryRole -All | ForEach-Object {
        $role = $_
        foreach ($m in @(Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All)) {
            [pscustomobject]@{
                Role      = $role.DisplayName
                MemberId  = $m.Id
                MemberUPN = $m.AdditionalProperties['userPrincipalName']
            }
        }
    } | Export-Csv -Path (Join-Path $dir 'cloud_role_members.csv') -NoTypeInformation -Encoding UTF8

    Write-Manifest -Dir $dir
    Write-Log "Entra backup complete: $dir" 'OK'
}
catch {
    Write-Log "Backup failed: $($_.Exception.Message)" 'ERROR'
    throw
}
