# Shared helpers for the hard-match toolkit.
# Dot-source from each script:   . (Join-Path $PSScriptRoot 'lib\Common.ps1')

$script:RunLog    = $null
$script:ResultLog = $null

# ---------------------------------------------------------------- logging
function Initialize-Run {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$LogDir,
        [string]$Mode = 'RUN'
    )
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:RunLog    = Join-Path $LogDir "${Name}_${Mode}_${stamp}.log"
    $script:ResultLog = Join-Path $LogDir "${Name}_${Mode}_${stamp}_results.csv"
    Write-Log "=== $Name started | mode=$Mode | operator=$env:USERNAME | host=$env:COMPUTERNAME ==="
    Write-Log "Run log   : $script:RunLog"
    Write-Log "Result CSV: $script:ResultLog"
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $line  = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'OK' { 'Green' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
    if ($script:RunLog) { Add-Content -Path $script:RunLog -Value $line }
}

function Add-Result {
    param(
        [string]$Upn,
        [Parameter(Mandatory)][string]$Action,
        [string]$Detail = '',
        [string]$CloudId = '',
        [string]$ImmutableId = ''
    )
    if (-not $script:ResultLog) { return }
    [pscustomobject]@{
        Timestamp   = (Get-Date -Format 'o')
        UPN         = $Upn
        CloudId     = $CloudId
        ImmutableId = $ImmutableId
        Action      = $Action
        Detail      = $Detail
    } | Export-Csv -Path $script:ResultLog -Append -NoTypeInformation
}

function Write-Manifest {
    # Row counts + SHA256 for every CSV in a backup folder.
    param([Parameter(Mandatory)][string]$Dir)
    $lines = Get-ChildItem -Path $Dir -Filter *.csv -File | ForEach-Object {
        '{0}  rows={1}  sha256={2}' -f $_.Name, @(Import-Csv $_.FullName).Count, (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    }
    $lines | Set-Content -Path (Join-Path $Dir 'manifest.txt')
    $lines | ForEach-Object { Write-Log $_ }
}

# ------------------------------------------------------------ Graph session
function Connect-GraphSession {
    param(
        [Parameter(Mandatory)][string[]]$Scopes,
        [switch]$UseDeviceCode
    )
    $ctx = Get-MgContext
    $missing = if ($ctx) { @($Scopes | Where-Object { $_ -notin $ctx.Scopes }) } else { $Scopes }
    if ($missing.Count -gt 0) {
        if ($UseDeviceCode) { Connect-MgGraph -Scopes $Scopes -UseDeviceCode -NoWelcome }
        else                { Connect-MgGraph -Scopes $Scopes -NoWelcome }
    }
    $ctx = Get-MgContext
    Write-Log "Graph connected | tenant=$($ctx.TenantId) | account=$($ctx.Account)"
}

# ------------------------------------------------------------ AD ImmutableId
function Get-AdImmutableId {
    # AdUser must be loaded with ObjectGUID and 'ms-DS-ConsistencyGuid'.
    # Entra Connect uses ms-DS-ConsistencyGuid when populated, otherwise objectGUID.
    param([Parameter(Mandatory)]$AdUser)
    $cg = $AdUser.'ms-DS-ConsistencyGuid'
    if ($cg) { return [Convert]::ToBase64String([byte[]]$cg) }
    return [Convert]::ToBase64String($AdUser.ObjectGUID.ToByteArray())
}

# ------------------------------------------------------------ stamp list CSV
function Import-StampList {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { throw "CSV not found: $Path" }
    $rows = @(Import-Csv -Path $Path)
    if ($rows.Count -eq 0) { throw "CSV has no data rows: $Path" }

    $cols    = $rows[0].PSObject.Properties.Name
    $missing = @('UPN', 'CloudId', 'ImmutableId') | Where-Object { $_ -notin $cols }
    if ($missing) { throw "CSV is missing required column(s): $($missing -join ', ')" }

    foreach ($r in $rows) {
        $r.UPN         = "$($r.UPN)".Trim()
        $r.CloudId     = "$($r.CloudId)".Trim()
        $r.ImmutableId = "$($r.ImmutableId)".Trim()
    }

    $guid = [guid]::Empty
    $bad = @(foreach ($r in $rows) {
        $p = @()
        if ($r.UPN -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$')               { $p += 'UPN invalid' }
        if (-not [guid]::TryParse($r.CloudId, [ref]$guid))               { $p += 'CloudId is not a GUID' }
        if ($r.ImmutableId -cnotmatch '^[A-Za-z0-9+/]{22}==$')           { $p += 'ImmutableId is not the 24-char Base64 of a 16-byte GUID' }
        if ($p) { '{0}: {1}' -f $r.UPN, ($p -join '; ') }
    })
    if ($bad.Count -gt 0) { throw "CSV validation failed:`n  $($bad -join "`n  ")" }

    $dupUpn = @($rows | Group-Object { $_.UPN.ToLower() } | Where-Object { $_.Count -gt 1 })
    $dupImm = @($rows | Group-Object -Property ImmutableId -CaseSensitive | Where-Object { $_.Count -gt 1 })
    $dupCid = @($rows | Group-Object -Property CloudId | Where-Object { $_.Count -gt 1 })
    if ($dupUpn.Count -or $dupImm.Count -or $dupCid.Count) {
        throw ("CSV has duplicates (UPN: {0}, ImmutableId: {1}, CloudId: {2}). Fix before running." -f $dupUpn.Count, $dupImm.Count, $dupCid.Count)
    }
    return $rows
}

# ------------------------------------------------------------ tenant lookups
function Get-DomainAuthMap {
    # Returns domain -> Managed | Federated | Unknown. Stamping fails on federated domains.
    param([Parameter(Mandatory)][string[]]$Upns)
    $map = @{}
    foreach ($d in ($Upns | ForEach-Object { $_.Split('@')[1].ToLower() } | Sort-Object -Unique)) {
        try   { $map[$d] = (Get-MgDomain -DomainId $d -ErrorAction Stop).AuthenticationType }
        catch { $map[$d] = 'Unknown'; Write-Log "Could not read domain '$d' (not verified in tenant?): $($_.Exception.Message)" 'WARN' }
        Write-Log "Domain $d => $($map[$d])"
    }
    return $map
}

function Get-CloudSnapshot {
    # One bulk read; per-row checks then run in memory.
    Write-Log 'Loading all cloud users from Microsoft Graph...'
    $users = @(Get-MgUser -All -Property Id, UserPrincipalName, OnPremisesSyncEnabled, OnPremisesImmutableId)
    $byId  = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $byImm = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($u in $users) {
        $byId[$u.Id] = $u
        if ($u.OnPremisesImmutableId) { $byImm[$u.OnPremisesImmutableId] = $u }
    }
    Write-Log "Loaded $($users.Count) cloud users"
    return [pscustomobject]@{ ById = $byId; ByImmutableId = $byImm }
}

# ------------------------------------------------------------ safety checks
function Test-StampCandidate {
    # Status: READY (safe to stamp) | DONE (already stamped with this value) | SKIP (do not touch)
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][hashtable]$DomainAuth
    )
    $domain = $Row.UPN.Split('@')[1].ToLower()
    if ($DomainAuth[$domain] -eq 'Federated') {
        return [pscustomobject]@{ Status = 'SKIP'; Detail = "Domain $domain is Federated. Switch UPN to onmicrosoft.com, stamp, then switch back." }
    }

    $cur = $null
    if (-not $Snapshot.ById.TryGetValue($Row.CloudId, [ref]$cur)) {
        return [pscustomobject]@{ Status = 'SKIP'; Detail = 'CloudId not found in tenant' }
    }
    if ($cur.UserPrincipalName -ne $Row.UPN) {
        return [pscustomobject]@{ Status = 'SKIP'; Detail = "Cloud UPN is '$($cur.UserPrincipalName)', CSV says '$($Row.UPN)'" }
    }
    if ($cur.OnPremisesSyncEnabled) {
        return [pscustomobject]@{ Status = 'SKIP'; Detail = 'Already synced from on-premises' }
    }
    if ($cur.OnPremisesImmutableId -ceq $Row.ImmutableId) {
        return [pscustomobject]@{ Status = 'DONE'; Detail = 'Already stamped with this ImmutableId' }
    }
    if ($cur.OnPremisesImmutableId) {
        return [pscustomobject]@{ Status = 'SKIP'; Detail = "Cloud user already has a different ImmutableId ($($cur.OnPremisesImmutableId))" }
    }
    $holder = $null
    if ($Snapshot.ByImmutableId.TryGetValue($Row.ImmutableId, [ref]$holder) -and $holder.Id -ne $Row.CloudId) {
        return [pscustomobject]@{ Status = 'SKIP'; Detail = "ImmutableId already used by $($holder.UserPrincipalName)" }
    }
    return [pscustomobject]@{ Status = 'READY'; Detail = 'All checks passed' }
}

function Set-CloudImmutableId {
    # Live re-check, stamp, read back. Throws on any problem. Returns 'OK' or 'DONE'.
    param([Parameter(Mandatory)]$Row)
    $live = Get-MgUser -UserId $Row.CloudId -Property Id, UserPrincipalName, OnPremisesSyncEnabled, OnPremisesImmutableId -ErrorAction Stop
    if ($live.OnPremisesImmutableId -ceq $Row.ImmutableId) { return 'DONE' }
    if ($live.OnPremisesSyncEnabled -or $live.OnPremisesImmutableId) {
        throw 'Live re-check failed: user is synced or already has an ImmutableId'
    }
    Update-MgUser -UserId $Row.CloudId -OnPremisesImmutableId $Row.ImmutableId -ErrorAction Stop
    $after = Get-MgUser -UserId $Row.CloudId -Property OnPremisesImmutableId -ErrorAction Stop
    if ($after.OnPremisesImmutableId -cne $Row.ImmutableId) { throw 'Read-back verification failed' }
    return 'OK'
}
