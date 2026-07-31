<#
.SYNOPSIS
    Test-CitrixHealth.ps1 -- one health check covering every failure mode found
    during the 2026-07 Citrix investigation. Read-only by default; -Fix
    delegates to the specific repair scripts.

.DESCRIPTION
    Each check below exists because it actually broke a machine, and several
    are things that LOOK fine through the obvious lens:

      1. CWA installed, on the LTSR track (winget id Citrix.Workspace.LTSR;
         a 26.x version means the endpoint drifted onto Current Release).
      2. Core binaries present across the whole Citrix tree -- components live
         in sibling folders (SelfServicePlugin, AuthManager, Legacy, Receiver),
         so checking only ICA Client reports false MISSING results.
      3. VC++ runtime >= CWA's minimum, judged by the DLL ON DISK, not the
         redist registry key. On HCDL-BP0WCW3 the registry claimed 14.42 while
         SysWOW64\msvcp140.dll was 14.22 -- and the DLL is what the loader
         binds, so wfcrun32.exe died with 0xc0000005 while every registry
         check passed.
      4. .NET Desktop Runtime 8 >= minimum.
      5. MSI CACHE INTEGRITY. This is the check that would have saved the most
         time: a product registered with LocalPackage pointing at a file that
         no longer exists in C:\Windows\Installer cannot be repaired, upgraded
         OR uninstalled -- every attempt fails in RemoveExistingProducts with
         System Error 1612 / error 1603. Aggressive "remnant cleanup" that
         deletes Installer cache entries causes this, and it affects EVERY
         affected product, not just Citrix. Scanned machine-wide.
      6. App-local runtime shim state. A copy of msvcp140.dll next to
         wfcrun32.exe overrides the system one and is never serviced by
         Windows Update, so once the system runtime is fixed the shim becomes
         the stale copy. Flagged when it is older than the system.
      7. .ica association: present, handler exists on disk, and whether the
         ProgID is the MSI-ADVERTISED one. An advertised ProgID triggers
         Windows Installer self-repair on launch, which a non-admin cannot
         complete on a per-machine install -- the user gets an administrator
         credential prompt. Citrix documents this as corrupt "despite
         appearing intact within the Windows registry" (CTX267718).
      8. receiver:// protocol handler (what the browser actually uses).
      9. Citrix Workspace Updater policy. Default stream is Current Release,
         so an LTSR machine is offered CR, and on a per-machine install a
         non-admin cannot apply it -- another admin credential prompt.
     10. Per-user CWA installs, which conflict with the machine-wide install
         and get torn out at logon, sometimes failing half-way (1603/1730).
     11. Configured stores -- a clean reinstall wipes them; users then land on
         "Add Account" even though everything else is correct.
     12. Recent Application 1000 crashes for Citrix binaries. When CWA "does
         nothing" this is the ONLY evidence; Citrix logs nothing itself.
     13. winget usability under SYSTEM (exit -1073741515 / 0xC0000135), which
         breaks the installer-sourcing path used by Reinstall-CitrixLTSR.ps1.

    Exit codes (WS1):
      0 = healthy
      1 = healthy with warnings (cosmetic / maintenance items)
      2 = one or more FAIL results (see the remedy printed for each)

.PARAMETER Fix
    Attempt remediation by invoking the sibling scripts, in dependency order:
    prerequisites (incl. orphaned MSI registrations) -> auto-update policy ->
    .ica association. Each must be present in the same folder as this script.
    Nothing is repaired that this script did not first report as FAIL.

.PARAMETER EventHours
    How far back to look for crash events. Default 24.

.PARAMETER Quiet
    Suppress the per-check detail lines; print only the summary.

.NOTES
    Author  : MEB -- Oak Street Health / CVS Health IT Operations
    Version : 1.0.0
    Date    : 2026-07-31
    Context : NT AUTHORITY\SYSTEM (WS1 Device context) or elevated admin
    PowerShell 5.1 compatible. Logs to C:\drop\citrix.
    Per-user checks (10, and per-user parts of 7) only see users who are
    signed in; run while the affected user has a session for full coverage.
#>

[CmdletBinding()]
param(
    [switch]$Fix,
    [int]$EventHours = 24,
    [switch]$Quiet
)

$ScriptVersion     = '1.0.0'
$DestinationFolder = 'C:\drop\citrix'
$LogRetainDays     = 30

$MinVCRedist   = [version]'14.42.34433.0'
$MinDotNet     = [version]'8.0.11'
$LtsrPrefix    = '25.7.'          # CWA 2507 LTSR family
$WingetDllNotFound = -1073741515

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$script:LogFile = $null

function Initialize-Logging {
    if (-not (Test-Path -LiteralPath $DestinationFolder)) {
        New-Item -Path $DestinationFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $DestinationFolder "Citrix-Health-$stamp.log"
    Get-ChildItem -LiteralPath $DestinationFolder -Filter 'Citrix-Health-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetainDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-Log {
    param([string]$Message = '', [ValidateSet('INFO','WARNING','ERROR')][string]$Level = 'INFO')
    $line = ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    if (-not ($Quiet -and $Level -eq 'INFO')) {
        switch ($Level) {
            'ERROR'   { Write-Host $line -ForegroundColor Red }
            'WARNING' { Write-Host $line -ForegroundColor Yellow }
            default   { Write-Host $line -ForegroundColor Gray }
        }
    }
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Result collection
# ---------------------------------------------------------------------------
$script:Results = @()

function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS','WARN','FAIL','INFO')][string]$Status,
        [string]$Detail = '',
        [string]$Remedy = '',
        [string]$FixKey = ''      # which repair this maps to, for -Fix
    )
    $script:Results += [pscustomobject]@{
        Name = $Name; Status = $Status; Detail = $Detail; Remedy = $Remedy; FixKey = $FixKey
    }
    $lvl = switch ($Status) { 'FAIL' {'ERROR'} 'WARN' {'WARNING'} default {'INFO'} }
    Write-Log ("  [{0,-4}] {1}{2}" -f $Status, $Name, $(if ($Detail) { " -- $Detail" } else { '' })) $lvl
    if ($Remedy -and $Status -in @('FAIL','WARN')) { Write-Log "         remedy: $Remedy" $lvl }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Test-IsSystem { ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value -eq 'S-1-5-18' }

function ConvertTo-VersionOrNull {
    param([string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Match(($Text -replace '^v','').Trim(), '^\d+(\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    try { return [version]$m.Value } catch { return $null }
}

function Get-DefaultValue {
    param([Parameter(Mandatory)][string]$Path)
    (Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue).'(default)'
}

function Get-CitrixRoots {
    @((Join-Path ${env:ProgramFiles(x86)} 'Citrix'), (Join-Path $env:ProgramFiles 'Citrix')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) }
}

function Get-LoadedUserHives {
    Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
        ForEach-Object { Split-Path $_.Name -Leaf } |
        Where-Object { $_ -match '^S-1-5-21-' -and $_ -notmatch '_Classes$' }
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
function Test-CwaInstalled {
    $hit = $null
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem $root -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
            Where-Object { $_.DisplayName -like 'Citrix Workspace*' -and $_.Publisher -like '*Citrix*' -and $_.DisplayVersion } |
            Select-Object -First 1
        if ($hit) { break }
    }
    if (-not $hit) {
        Add-Result 'CWA installed' 'FAIL' 'no Citrix Workspace product registered' `
            'Reinstall-CitrixLTSR.ps1' 'reinstall'
        return $null
    }
    $v = $hit.DisplayVersion
    if ($v -like "$LtsrPrefix*") {
        Add-Result 'CWA installed' 'PASS' "$($hit.DisplayName) $v (LTSR track)"
    } else {
        Add-Result 'CWA release track' 'WARN' "version $v is not on the $LtsrPrefix LTSR track" `
            'Reinstall-CitrixLTSR.ps1 (installs Citrix.Workspace.LTSR)' 'reinstall'
    }
    return $v
}

function Test-CitrixBinaries {
    $roots = Get-CitrixRoots
    if (-not $roots) { Add-Result 'Citrix binaries' 'FAIL' 'no Citrix program directory' 'Reinstall-CitrixLTSR.ps1' 'reinstall'; return }
    $wanted = @('wfcrun32.exe','wfica32.exe','SelfService.exe','CDViewer.exe','AuthManSvr.exe','WebHelper.exe')
    $found = @()
    foreach ($r in $roots) {
        $found += Get-ChildItem -LiteralPath $r -Recurse -File -Filter '*.exe' -ErrorAction SilentlyContinue |
            Where-Object { $wanted -contains $_.Name } | ForEach-Object { $_.Name }
    }
    $missing = @($wanted | Where-Object { $found -notcontains $_ })
    if ($missing) {
        Add-Result 'Citrix binaries' 'FAIL' ("missing: {0}" -f ($missing -join ', ')) `
            'Reinstall-CitrixLTSR.ps1 -CleanInstall' 'reinstall'
    } else {
        Add-Result 'Citrix binaries' 'PASS' 'all core components present'
    }
}

function Test-VCRuntime {
    foreach ($a in @(@{n='x86'; dir='SysWOW64'}, @{n='x64'; dir='System32'})) {
        $dllPath = Join-Path (Join-Path $env:SystemRoot $a.dir) 'msvcp140.dll'
        $dll = if (Test-Path -LiteralPath $dllPath) { ConvertTo-VersionOrNull (Get-Item -LiteralPath $dllPath).VersionInfo.FileVersion } else { $null }
        $regPath = if ($a.n -eq 'x64') { 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' }
                   else { 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x86' }
        $reg = ConvertTo-VersionOrNull (Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue).Version

        if (-not $dll) {
            Add-Result "VC++ $($a.n) runtime" 'FAIL' "$($a.dir)\msvcp140.dll missing" `
                'Install-CitrixPrerequisites.ps1' 'prereq'
        } elseif ($dll -lt $MinVCRedist) {
            Add-Result "VC++ $($a.n) runtime" 'FAIL' "$($a.dir)\msvcp140.dll=$dll < $MinVCRedist (registry claims $reg) -- Citrix will crash 0xc0000005 on launch" `
                'Install-CitrixPrerequisites.ps1 (add -RemoveOrphanedRegistration if it reports 1612)' 'prereq'
        } elseif ($reg -and $reg -ne $dll) {
            Add-Result "VC++ $($a.n) runtime" 'WARN' "on-disk $dll meets minimum but registry claims $reg" ''
        } else {
            Add-Result "VC++ $($a.n) runtime" 'PASS' "$dll"
        }
    }
}

function Test-DotNetRuntime {
    foreach ($a in @(@{n='x86'; p=(Join-Path ${env:ProgramFiles(x86)} 'dotnet\shared\Microsoft.WindowsDesktop.App')},
                     @{n='x64'; p=(Join-Path $env:ProgramFiles 'dotnet\shared\Microsoft.WindowsDesktop.App')})) {
        $best = $null
        if ($a.p -and (Test-Path -LiteralPath $a.p)) {
            $best = Get-ChildItem -LiteralPath $a.p -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { ConvertTo-VersionOrNull $_.Name } |
                Where-Object { $_ -and $_.Major -eq 8 } | Sort-Object -Descending | Select-Object -First 1
        }
        if (-not $best) {
            Add-Result ".NET Desktop 8 $($a.n)" 'FAIL' 'not installed' 'Install-CitrixPrerequisites.ps1' 'prereq'
        } elseif ($best -lt $MinDotNet) {
            Add-Result ".NET Desktop 8 $($a.n)" 'FAIL' "$best < $MinDotNet" 'Install-CitrixPrerequisites.ps1' 'prereq'
        } else {
            Add-Result ".NET Desktop 8 $($a.n)" 'PASS' "$best"
        }
    }
}

function Test-MsiCacheIntegrity {
    # A product whose LocalPackage no longer exists cannot be repaired,
    # upgraded or uninstalled -- everything fails in RemoveExistingProducts
    # with System Error 1612. This is the condition that cost a full day.
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
    if (-not (Test-Path $root)) {
        Add-Result 'MSI cache integrity' 'WARN' 'installer product database not readable'
        return
    }
    $broken = @()
    foreach ($p in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
        $ip = Join-Path $p.PSPath 'InstallProperties'
        $props = Get-ItemProperty -LiteralPath $ip -ErrorAction SilentlyContinue
        if (-not $props -or -not $props.LocalPackage) { continue }
        if (-not (Test-Path -LiteralPath $props.LocalPackage)) {
            $broken += [pscustomobject]@{
                Name = $(if ($props.DisplayName) { $props.DisplayName } else { $p.PSChildName })
                Package = $props.LocalPackage
            }
        }
    }
    if (-not $broken) {
        Add-Result 'MSI cache integrity' 'PASS' 'every registered product has its cached package'
        return
    }
    $vc = @($broken | Where-Object { $_.Name -like '*Visual C++*' })
    $ctx = @($broken | Where-Object { $_.Name -like '*Citrix*' })
    foreach ($b in ($broken | Select-Object -First 12)) { Write-Log "         orphaned: $($b.Name)" 'WARNING' }
    if ($broken.Count -gt 12) { Write-Log "         ... and $($broken.Count - 12) more" 'WARNING' }

    if ($vc -or $ctx) {
        Add-Result 'MSI cache integrity' 'FAIL' `
            ("{0} product(s) have a missing cached package, including {1} VC++ and {2} Citrix -- these cannot be patched, repaired or uninstalled (error 1612)" -f $broken.Count, $vc.Count, $ctx.Count) `
            'Install-CitrixPrerequisites.ps1 -RemoveOrphanedRegistration (backs up before clearing)' 'prereq-orphan'
    } else {
        Add-Result 'MSI cache integrity' 'WARN' `
            ("{0} unrelated product(s) have a missing cached package; servicing for those is broken" -f $broken.Count) `
            'Investigate: cleanup scripts that delete C:\Windows\Installer entries cause this'
    }
}

function Test-AppLocalShim {
    $ica = Get-CitrixRoots | ForEach-Object { Join-Path $_ 'ICA Client' } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ 'wfcrun32.exe') } | Select-Object -First 1
    if (-not $ica) { return }
    $shim = Join-Path $ica 'msvcp140.dll'
    if (-not (Test-Path -LiteralPath $shim)) {
        Add-Result 'App-local runtime shim' 'PASS' 'not present (Citrix uses the system runtime)'
        return
    }
    $shimV = ConvertTo-VersionOrNull (Get-Item -LiteralPath $shim).VersionInfo.FileVersion
    $sysP  = Join-Path (Join-Path $env:SystemRoot 'SysWOW64') 'msvcp140.dll'
    $sysV  = if (Test-Path -LiteralPath $sysP) { ConvertTo-VersionOrNull (Get-Item -LiteralPath $sysP).VersionInfo.FileVersion } else { $null }
    if ($sysV -and $sysV -ge $MinVCRedist -and $shimV -and $shimV -lt $sysV) {
        Add-Result 'App-local runtime shim' 'WARN' `
            "shim v$shimV in ICA Client is now OLDER than the system runtime v$sysV, and app-local copies are never serviced" `
            "delete msvcp140.dll and vcruntime140.dll from $ica, then re-test the launch"
    } else {
        Add-Result 'App-local runtime shim' 'INFO' "present v$shimV (system v$sysV) -- intentional workaround"
    }
}

function Test-IcaAssociation {
    $progId = Get-DefaultValue -Path 'Registry::HKEY_CLASSES_ROOT\.ica'
    if (-not $progId) {
        Add-Result '.ica association' 'FAIL' 'no association registered' 'Repair-IcaAssociation.ps1' 'ica'
        return
    }
    $cmd = Get-DefaultValue -Path "Registry::HKEY_CLASSES_ROOT\$progId\shell\open\command"
    if (-not $cmd -or $cmd -notmatch 'wfcrun32|CDViewer') {
        Add-Result '.ica association' 'FAIL' "ProgID '$progId' does not point at a Citrix handler" 'Repair-IcaAssociation.ps1' 'ica'
        return
    }
    if ($cmd -match '([A-Za-z]:\\[^"]+\.exe)' -and -not (Test-Path -LiteralPath $Matches[1])) {
        Add-Result '.ica association' 'FAIL' "handler missing on disk: $($Matches[1])" 'Repair-IcaAssociation.ps1' 'ica'
        return
    }
    if ($progId -notmatch '\.NEW$') {
        Add-Result '.ica association' 'WARN' `
            "ProgID '$progId' is the MSI-advertised one -- launching can trigger Windows Installer self-repair, which prompts non-admins for administrator credentials (CTX267718)" `
            'Repair-IcaAssociation.ps1'  'ica'
    } else {
        Add-Result '.ica association' 'PASS' "$progId (non-advertised)"
    }
    # Per-user associations outrank the machine one.
    foreach ($sid in (Get-LoadedUserHives)) {
        $uKey = "Registry::HKEY_USERS\$sid\SOFTWARE\Classes\.ica"
        if (Test-Path -LiteralPath $uKey) {
            $uProg = Get-DefaultValue -Path $uKey
            $uCmd  = Get-DefaultValue -Path "Registry::HKEY_USERS\$sid\SOFTWARE\Classes\$uProg\shell\open\command"
            $stale = $uCmd -match '([A-Za-z]:\\[^"]+\.exe)' -and -not (Test-Path -LiteralPath $Matches[1])
            Add-Result '.ica per-user override' $(if ($stale) {'FAIL'} else {'WARN'}) `
                "$sid -> '$uProg'$(if ($stale) { ' (handler MISSING -- launches silently do nothing)' })" `
                'Repair-IcaAssociation.ps1' 'ica'
        }
        $uc = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.ica\UserChoice"
        if (Test-Path -LiteralPath $uc) {
            Add-Result '.ica UserChoice override' 'WARN' `
                "$sid -> $((Get-ItemProperty -LiteralPath $uc -ErrorAction SilentlyContinue).ProgId)" `
                'Repair-IcaAssociation.ps1' 'ica'
        }
    }
}

function Test-ReceiverProtocol {
    $cmd = Get-DefaultValue -Path 'HKLM:\SOFTWARE\Classes\receiver\shell\open\command'
    if (-not $cmd) {
        Add-Result 'receiver:// handler' 'FAIL' 'not registered -- browser launches will fall back to downloading .ica' `
            'Reinstall-CitrixLTSR.ps1' 'reinstall'
    } elseif ($cmd -match '([A-Za-z]:\\[^"]+\.exe)' -and -not (Test-Path -LiteralPath $Matches[1])) {
        Add-Result 'receiver:// handler' 'FAIL' "handler missing on disk: $($Matches[1])" 'Reinstall-CitrixLTSR.ps1' 'reinstall'
    } else {
        Add-Result 'receiver:// handler' 'PASS' 'registered'
    }
}

function Test-AutoUpdatePolicy {
    foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Citrix\ICA Client\AutoUpdate',
                     'HKLM:\SOFTWARE\Citrix\ICA Client\AutoUpdate')) {
        $p = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
        if ($p -and $p.AutoUpdateCheck) {
            if ($p.AutoUpdateCheck -ieq 'Disabled') {
                Add-Result 'Auto-update policy' 'PASS' "Disabled, stream $($p.AutoUpdateStream)"
            } elseif ($p.AutoUpdateStream -ieq 'LTSR') {
                Add-Result 'Auto-update policy' 'WARN' `
                    "checks enabled on the LTSR stream; non-admins still cannot apply an update on a per-machine install" `
                    'Set-CitrixAutoUpdate.ps1  (mode disabled)' 'autoupdate'
            } else {
                Add-Result 'Auto-update policy' 'FAIL' `
                    "AutoUpdateCheck=$($p.AutoUpdateCheck), stream=$($p.AutoUpdateStream) -- offers Current Release to an LTSR machine and prompts non-admins for admin credentials" `
                    'Set-CitrixAutoUpdate.ps1' 'autoupdate'
            }
            return
        }
    }
    Add-Result 'Auto-update policy' 'FAIL' 'not configured -- defaults to notifying on the Current Release stream' `
        'Set-CitrixAutoUpdate.ps1' 'autoupdate'
}

function Test-PerUserInstalls {
    $found = @()
    foreach ($sid in (Get-LoadedUserHives)) {
        $root = "Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -match 'Citrix') { $found += "$sid : $($p.DisplayName) $($p.DisplayVersion)" }
        }
    }
    if ($found) {
        foreach ($f in $found) { Write-Log "         $f" 'WARNING' }
        Add-Result 'Per-user Citrix installs' 'FAIL' `
            "$($found.Count) per-user install(s) alongside the machine-wide one -- these get torn out at logon and the removal often fails (1603/1730)" `
            'Remove the per-user install while that user is signed in, then re-test'
    } else {
        Add-Result 'Per-user Citrix installs' 'PASS' 'none (machine-wide install only)'
    }
}

function Test-ConfiguredStores {
    $stores = @()
    foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Citrix\Dazzle\Sites','HKLM:\SOFTWARE\Citrix\Dazzle\Sites')) {
        if (Test-Path $k) { $stores += (Get-ChildItem $k -ErrorAction SilentlyContinue).PSChildName }
    }
    foreach ($sid in (Get-LoadedUserHives)) {
        foreach ($sub in @('SOFTWARE\Citrix\Dazzle\Sites','SOFTWARE\Citrix\Receiver\SR\Store')) {
            $k = "Registry::HKEY_USERS\$sid\$sub"
            if (Test-Path -LiteralPath $k) { $stores += (Get-ChildItem -LiteralPath $k -ErrorAction SilentlyContinue).PSChildName }
        }
    }
    if ($stores) { Add-Result 'Configured stores' 'PASS' ("{0} store entr(ies)" -f $stores.Count) }
    else {
        Add-Result 'Configured stores' 'WARN' 'no store configured at machine or user level -- users will land on "Add Account"' `
            'Confirm GPO/WS1 re-pushes the StoreFront URL (a clean reinstall wipes stores)'
    }
}

function Test-RecentCrashes {
    $since = (Get-Date).AddHours(-$EventHours)
    $events = Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='Application Error'; StartTime=$since } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'wfcrun32|SelfService|wfica32|CDViewer|Receiver\.exe|AuthManSvr|Cleanup\.exe' }
    if (-not $events) {
        Add-Result "Citrix crashes (last ${EventHours}h)" 'PASS' 'none'
        return
    }
    $mods = ($events | ForEach-Object { if ($_.Message -match 'Faulting module name:\s*([^,]+)') { $Matches[1].Trim() } }) |
        Sort-Object -Unique
    foreach ($e in ($events | Select-Object -First 5)) {
        $app = if ($e.Message -match 'Faulting application name:\s*([^,]+)') { $Matches[1].Trim() } else { '?' }
        $mod = if ($e.Message -match 'Faulting module name:\s*([^,]+)') { $Matches[1].Trim() } else { '?' }
        Write-Log ("         {0:HH:mm:ss} {1} faulted in {2}" -f $e.TimeCreated, $app, $mod) 'WARNING'
    }
    $remedy = if ($mods -match 'MSVCP140|VCRUNTIME140') { 'Install-CitrixPrerequisites.ps1 -- crashes in the VC++ runtime mean it is below CWA minimum' }
              elseif ($mods -match 'coreclr') { 'Install-CitrixPrerequisites.ps1 -- check the .NET Desktop Runtime' }
              else { 'Review C:\Program Files (x86)\Citrix\Logs and %TEMP%\CTXWorkspaceInstallLogs' }
    Add-Result "Citrix crashes (last ${EventHours}h)" 'FAIL' `
        ("{0} crash event(s); faulting module(s): {1}" -f $events.Count, ($mods -join ', ')) $remedy 'prereq'
}

function Test-WingetUnderSystem {
    if (-not (Test-IsSystem)) { Add-Result 'winget usable' 'INFO' 'not running as SYSTEM; skipped'; return }
    $wg = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
    if (-not $wg) {
        $wg = Get-ChildItem -LiteralPath (Join-Path $env:ProgramFiles 'WindowsApps') -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'winget.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    $portable = Join-Path $DestinationFolder 'winget-portable\winget.exe'
    if (-not $wg -and (Test-Path -LiteralPath $portable)) { $wg = $portable }
    if (-not $wg) { Add-Result 'winget usable' 'WARN' 'winget.exe not found' 'Repair-Winget.ps1'; return }
    try {
        $p = Start-Process -FilePath $wg -ArgumentList '--version' -WorkingDirectory (Split-Path $wg -Parent) `
             -PassThru -WindowStyle Hidden -ErrorAction Stop
        $null = $p.Handle
        if (-not $p.WaitForExit(60000)) { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
            Add-Result 'winget usable' 'WARN' 'winget --version timed out' 'Repair-Winget.ps1'; return }
        if ($p.ExitCode -eq 0) { Add-Result 'winget usable' 'PASS' $wg }
        elseif ($p.ExitCode -eq $WingetDllNotFound) {
            Add-Result 'winget usable' 'WARN' '0xC0000135 under SYSTEM -- installer sourcing via winget will fail' `
                'Repair-Winget.ps1 (or stage the installer as WS1 payload / -SharePath)'
        } else { Add-Result 'winget usable' 'WARN' "winget --version returned $($p.ExitCode)" 'Repair-Winget.ps1' }
    } catch { Add-Result 'winget usable' 'WARN' "could not run winget: $($_.Exception.Message)" 'Repair-Winget.ps1' }
}

# ---------------------------------------------------------------------------
# Fix delegation
# ---------------------------------------------------------------------------
function Invoke-Fixes {
    param([Parameter(Mandatory)][string[]]$Keys)
    $dir = Split-Path -Parent $PSCommandPath
    if (-not $dir) { Write-Log 'Cannot resolve script folder; -Fix unavailable.' 'ERROR'; return }

    # Dependency order: runtime first (nothing else works if CWA crashes on
    # launch), then policy, then associations.
    $plan = @(
        @{ Key='prereq-orphan'; Script='Install-CitrixPrerequisites.ps1'; Args=@('-RemoveOrphanedRegistration') }
        @{ Key='prereq';        Script='Install-CitrixPrerequisites.ps1'; Args=@() }
        @{ Key='reinstall';     Script='Reinstall-CitrixLTSR.ps1';        Args=@() }
        @{ Key='autoupdate';    Script='Set-CitrixAutoUpdate.ps1';        Args=@() }
        @{ Key='ica';           Script='Repair-IcaAssociation.ps1';       Args=@() }
    )
    $ran = @()
    foreach ($step in $plan) {
        if ($Keys -notcontains $step.Key) { continue }
        if ($ran -contains $step.Script) { continue }   # orphan variant supersedes plain prereq
        $path = Join-Path $dir $step.Script
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Log "Cannot fix '$($step.Key)': $($step.Script) not found beside this script." 'ERROR'
            continue
        }
        Write-Log ("--- Fix: {0} {1} ---" -f $step.Script, ($step.Args -join ' ')) 'WARNING'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path @($step.Args)
        Write-Log ("    exit code: {0}" -f $LASTEXITCODE) 'WARNING'
        $ran += $step.Script
    }
    if (-not $ran) { Write-Log 'No automatic fix available for the reported failures.' 'WARNING' }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try { Initialize-Logging }
catch {
    Write-Host "FATAL: cannot create log directory '$DestinationFolder': $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

$exit = 0
try {
    Write-Log ('=' * 70)
    Write-Log "Citrix health check  (script v$ScriptVersion)"
    Write-Log "Computer: $env:COMPUTERNAME   User: $(whoami)   IsAdmin: $(Test-IsAdmin)"
    $hives = @(Get-LoadedUserHives)
    Write-Log ("Signed-in user hives: {0}" -f $(if ($hives) { $hives -join ', ' } else { 'none -- per-user checks will be incomplete' }))
    Write-Log ''

    Write-Log '--- Install ---'
    Test-CwaInstalled | Out-Null
    Test-CitrixBinaries

    Write-Log '--- Runtime prerequisites ---'
    Test-VCRuntime
    Test-DotNetRuntime
    Test-MsiCacheIntegrity
    Test-AppLocalShim

    Write-Log '--- Launch path ---'
    Test-IcaAssociation
    Test-ReceiverProtocol
    Test-RecentCrashes

    Write-Log '--- Configuration ---'
    Test-AutoUpdatePolicy
    Test-PerUserInstalls
    Test-ConfiguredStores
    Test-WingetUnderSystem

    # Summary
    $fails = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
    $warns = @($script:Results | Where-Object { $_.Status -eq 'WARN' })
    Write-Log ''
    Write-Log ('--- Summary: {0} pass, {1} warn, {2} fail ---' -f `
        @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $warns.Count, $fails.Count)
    foreach ($r in ($fails + $warns)) {
        Write-Log ("  {0,-4} {1}" -f $r.Status, $r.Name) $(if ($r.Status -eq 'FAIL') {'ERROR'} else {'WARNING'})
        if ($r.Remedy) { Write-Log ("         -> {0}" -f $r.Remedy) $(if ($r.Status -eq 'FAIL') {'ERROR'} else {'WARNING'}) }
    }
    if (-not $fails -and -not $warns) { Write-Log '  Everything healthy.' }

    if ($fails)      { $exit = 2 }
    elseif ($warns)  { $exit = 1 }

    if ($Fix) {
        $keys = @(($fails + $warns) | Where-Object { $_.FixKey } | ForEach-Object { $_.FixKey } | Sort-Object -Unique)
        if ($keys) {
            Write-Log ''
            Write-Log ('--- Applying fixes: {0} ---' -f ($keys -join ', ')) 'WARNING'
            Invoke-Fixes -Keys $keys
            Write-Log 'Fixes applied. Re-run this script (after a reboot if any installer asked for one) to confirm.' 'WARNING'
        } else {
            Write-Log 'Nothing to fix automatically.'
        }
    } elseif ($fails) {
        Write-Log ''
        Write-Log 'Re-run with -Fix to apply the remedies above automatically.' 'WARNING'
    }
}
catch {
    Write-Log "Unhandled exception: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    $exit = 2
}
finally {
    Write-Log "Exit code: $exit"
    Write-Log ('=' * 70)
}

exit $exit
