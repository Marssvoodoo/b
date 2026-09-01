<#
.SYNOPSIS
    Test-CitrixHealth.ps1 -- one health check covering every failure mode found
    during the 2026-07 Citrix investigation. Read-only by default; -Fix
    repairs what it finds.

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
    Repair whatever the checks reported as FAIL or WARN. The repairs are built
    into this script, so it works deployed on its own -- nothing else needs to
    be present. Order is deliberate: runtime prerequisites first (nothing
    downstream works while Citrix crashes on launch), then auto-update policy,
    then the .ica association, and the app-local shim is only removed last and
    only once the system runtime actually passes.

    Repairs performed natively: runtime install/repair including clearing an
    orphaned MSI registration (registry exported first), auto-update policy,
    .ica association plus per-user overrides, stale shim removal.

    A full CWA install is also performed natively (see -InstallerPath), so
    nothing is left unfixable. When Reinstall-CitrixLTSR.ps1 happens to sit
    beside this script it is preferred for that one step, since it adds richer
    installer sourcing, MSI mutex handling and hash verification.

    Nothing is changed unless -Fix is passed.

.PARAMETER InstallerPath
    Explicit CitrixWorkspaceApp.exe for -Fix to install from. Otherwise a
    payload beside this script is used, then winget.

.PARAMETER WingetId
    winget package id used when -Fix has to fetch the installer. Defaults to
    Citrix.Workspace.LTSR -- the LTSR manifest. Do NOT point this at
    Citrix.Workspace, which is the Current Release track.

.PARAMETER WebLaunchOnly
    Accepted and ignored. Web launch is now the assumed model, so an
    unconfigured store never warns and the switch has nothing left to turn on.
    It is kept only so existing WS1 command lines that pass it keep working.

.PARAMETER EventHours
    How far back to look for crash events. Default 24.

.PARAMETER Quiet
    Suppress the per-check detail lines; print only the summary.

.NOTES
    Author  : MEB -- Oak Street Health / CVS Health IT Operations
    Version : 1.10.0
    Date    : 2026-09-01
    v1.10.0 : Stores are never warned about. This site does not configure them
              -- users launch from the web page and the client just runs the
              downloaded .ica -- so an empty store list is the intended state
              and is now reported as INFO unconditionally. -WebLaunchOnly is
              accepted and ignored, so command lines already passing it keep
              working.
              Also: an app-local runtime copy is only a problem where it shadows an
              executable on the LAUNCH path. OSHCDQ04PG4 -- a clean machine --
              warned about the redist CWA 2507 bundles (14.42) sitting in its
              own bootstrapper folder beside CWAInstaller.exe,
              bootstrapperhelper.exe and DotNetCoreInstaller.exe. Those run at
              install time and had already run against that very copy; they
              cannot affect a published app launching. Since every patched
              machine ends up with a system runtime newer than the bundled one,
              that warning would have fired fleet-wide, forever, on endpoints
              with nothing wrong -- the same noise -WebLaunchOnly removed.
              Now WARN only when a launch binary (wfcrun32, wfica32,
              SelfService, CDViewer, AuthManSvr, WebHelper, Receiver, concentr)
              shares the directory; installer-only folders report INFO and
              -Fix leaves them alone.
    v1.9.0  : Decide "already repaired" from the crash event, not a timestamp.
              HCDL-B14YRW3 kept reporting FAIL after a successful repair: the
              12:45 run showed wfcrun32.exe had faulted at 11:54 in MSVCP140.dll
              v14.22.27821.0 while that same path now holds v14.44.35211.0 --
              provably a pre-repair crash, still called live. The old rule
              compared the crash time against the DLL's LastWriteTime, and
              installers preserve a file's original build timestamp, so the
              repaired runtime carried a write time older than the crash.
              Now: if every copy of the faulting module on disk is newer than
              the version the event recorded, the crash cannot recur as logged
              and is reported historical -- and that also dates the repair, so
              earlier collateral faults (SelfService in coreclr.dll, which
              links against the same VC++ redist) are covered by it.
              Also: app-local runtime copies are only called shadowing when an
              executable shares their directory. CWA leaves redist payload in
              its bootstrapper folders (Citrix Workspace 2507, Ctx-{GUID})
              where nothing loads it; v1.8.0 called those a shim and deleted
              them, which was harmless but not a fix and not accurate.
    v1.8.0  : Crash reporting told a machine to fix something this same run had
              just measured as healthy. HCDL-B14YRW3 passed every runtime check
              (VC++ x86 14.44.35211.0, .NET 8.0.30) and was still told "crashes
              in the VC++ runtime mean it is below CWA minimum". Four changes:
              (a) the remedy now depends on whether the runtime checks passed
                  and where the module loaded from, not on its name alone;
              (b) crash lines log the faulting module's PATH and VERSION, which
                  is what distinguishes the system DLL from a private copy;
              (c) the VC++ check reads the whole redist as a SET -- msvcp140.dll
                  can be current while vcruntime140.dll is not, and a process
                  then faults inside MSVCP140 with nothing looking wrong;
              (d) app-local runtime copies are searched across the whole Citrix
                  tree, not just ICA Client, since SelfServicePlugin and the
                  other exe folders each get their own loader search path.
              A crash whose remedy -Fix cannot act on no longer claims a fix
              category, so "applying fixes" stops appearing where nothing runs.
    v1.7.0  : Added -WebLaunchOnly. Where users launch from the StoreFront web
              page and the Workspace app only executes the downloaded .ica, an
              unconfigured store is correct, not a defect -- warning about it
              on every run is noise that hides real findings.
    v1.6.0  : Do not report a repaired machine as failing on historical
              crashes. HCDL-B14YRW3 was fixed at 11:54 and still reported FAIL
              afterwards, because every crash in the 24h lookback predated the
              repair. Crashes older than the runtime DLL's write time are now
              WARN ("historical"), but only when the runtime actually passes --
              if it is still below minimum they remain a FAIL.
    v1.5.0  : Grade the per-user .ica UserChoice by WHAT it points at. One
              pointing at the repaired ProgID is fine; one pointing at the
              advertised ProgID is a FAIL, because it outranks the machine
              setting and that user still gets the "modified only by an
              administrator" dialog on every .ica open. Windows recreates it
              whenever the user answers an "Open with" prompt, so it returns
              after a machine-level fix.
    v1.4.0  : HCDL-B14YRW3 passed the MSI cache check and its VC++ install
              still failed 1612/1714, because a missing cached PATCH fails
              exactly like a missing cached product. The cache check now scans
              patches too, and the runtime repair self-escalates on the actual
              1612 rather than trusting the pre-check: it clears the stale
              registration and retries. Every runtime repair now verifies the
              on-disk DLL afterwards instead of trusting the exit code.
    v1.3.0  : When a direct runtime download is blocked (seen on HCDL-B14YRW3:
              three TLS failures against aka.ms while winget worked fine), fall
              back to installing the runtime via winget instead of leaving the
              machine broken.
    v1.2.0  : -Fix can now install CWA itself (-InstallerPath / payload beside
              the script / winget Citrix.Workspace.LTSR), so a standalone
              deployment is no longer left unable to install. Reinstall-
              CitrixLTSR.ps1 is still preferred when present.
    v1.1.0  : -Fix repairs natively instead of delegating, so the script is
              self-contained when deployed alone. Only the full CWA reinstall
              still needs a sibling script.
    Context : NT AUTHORITY\SYSTEM (WS1 Device context) or elevated admin
    PowerShell 5.1 compatible. Logs to C:\drop\citrix.
    Per-user checks (10, and per-user parts of 7) only see users who are
    signed in; run while the affected user has a session for full coverage.
#>

[CmdletBinding()]
param(
    [switch]$Fix,
    [string]$InstallerPath = '',
    [string]$WingetId = 'Citrix.Workspace.LTSR',
    [int]$EventHours = 24,
    [switch]$WebLaunchOnly,
    [switch]$Quiet
)

$ScriptVersion     = '1.10.0'
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

# The executables that run when a user launches a published app. Everything
# else under the Citrix tree -- CWAInstaller.exe, bootstrapperhelper.exe,
# DotNetCoreInstaller.exe -- only runs during install, so a stale DLL beside
# THOSE cannot affect a launch.
$script:CitrixLaunchExe = @(
    'wfcrun32.exe', 'wfica32.exe', 'SelfService.exe', 'CDViewer.exe',
    'AuthManSvr.exe', 'WebHelper.exe', 'Receiver.exe', 'concentr.exe'
)

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

# Every DLL the VC++ redistributable installs as one unit. They are always
# stamped with the same version, so a set where they DISAGREE means something
# replaced part of it -- and a process can then access-violate inside
# MSVCP140.dll while msvcp140.dll itself reads as a perfectly current version.
# Checking msvcp140.dll alone cannot see that.
$script:VCRuntimeSet = @(
    'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'msvcp140_atomic_wait.dll',
    'msvcp140_codecvt_ids.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'concrt140.dll'
)

function Get-VCRuntimeSetState {
    # Versions of every member of the set that is actually present in $Dir.
    # Members legitimately absent on older redists (msvcp140_atomic_wait.dll
    # arrived in 14.28, vcruntime140_1.dll is x64-only) are skipped, not failed.
    param([Parameter(Mandatory)][string]$Dir)
    $out = @()
    foreach ($n in $script:VCRuntimeSet) {
        $p = Join-Path $Dir $n
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $v = ConvertTo-VersionOrNull (Get-Item -LiteralPath $p).VersionInfo.FileVersion
        if ($v) { $out += [pscustomobject]@{ Name = $n; Version = $v; Path = $p } }
    }
    return $out
}

function Test-VCRuntime {
    foreach ($a in @(@{n='x86'; dir='SysWOW64'}, @{n='x64'; dir='System32'})) {
        $archDir = Join-Path $env:SystemRoot $a.dir
        $dllPath = Join-Path $archDir 'msvcp140.dll'
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

        # msvcp140.dll can be current while the rest of the redist is not. That
        # set is what the loader actually binds, so check it as a set.
        if ($dll) {
            $set   = @(Get-VCRuntimeSetState -Dir $archDir)
            $stale = @($set | Where-Object { $_.Version -lt $MinVCRedist })
            $spread = @($set | Select-Object -ExpandProperty Version -Unique)
            if ($stale) {
                Add-Result "VC++ $($a.n) set consistency" 'FAIL' `
                    ("{0} below minimum $MinVCRedist while msvcp140.dll is $dll -- a split redist crashes inside MSVCP140 even though msvcp140.dll looks current" -f `
                        (($stale | ForEach-Object { "$($_.Name)=$($_.Version)" }) -join ', ')) `
                    'Install-CitrixPrerequisites.ps1 -ForceReinstall (reinstalls the whole redist, not just the one DLL)' 'prereq'
            } elseif ($spread.Count -gt 1) {
                Add-Result "VC++ $($a.n) set consistency" 'WARN' `
                    ("{0} versions present, all at or above minimum: {1}" -f $spread.Count, `
                        (($set | ForEach-Object { "$($_.Name)=$($_.Version)" }) -join ', ')) `
                    'Not necessarily a fault, but the redist normally stamps every file the same -- reinstall it if Citrix crashes in one of these modules'
            } else {
                Add-Result "VC++ $($a.n) set consistency" 'PASS' ("{0} file(s), all $($spread[0])" -f $set.Count)
            }
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
        if ($props -and $props.LocalPackage -and -not (Test-Path -LiteralPath $props.LocalPackage)) {
            $broken += [pscustomobject]@{
                Name = $(if ($props.DisplayName) { $props.DisplayName } else { $p.PSChildName })
                Package = $props.LocalPackage
            }
        }
        # A missing cached PATCH fails identically to a missing cached product:
        # RemoveExistingProducts cannot run, and the install dies 1612/1714.
        # HCDL-B14YRW3 passed the product scan and still failed this way, so the
        # patch cache has to be checked as well.
        $patchRoot = Join-Path $p.PSPath 'Patches'
        foreach ($patch in (Get-ChildItem -LiteralPath $patchRoot -ErrorAction SilentlyContinue)) {
            $pp = Get-ItemProperty -LiteralPath $patch.PSPath -ErrorAction SilentlyContinue
            if ($pp -and $pp.LocalPackage -and -not (Test-Path -LiteralPath $pp.LocalPackage)) {
                $owner = $(if ($props -and $props.DisplayName) { $props.DisplayName } else { $p.PSChildName })
                $broken += [pscustomobject]@{
                    Name = "$owner (patch $($patch.PSChildName))"
                    Package = $pp.LocalPackage
                }
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

function Get-AppLocalRuntimeCopy {
    # Search the WHOLE Citrix tree, not just ICA Client. The loader prefers a
    # DLL sitting next to the .exe over the system one, so a copy in any
    # subfolder that holds an executable -- SelfServicePlugin, Receiver,
    # Authentication -- silently outranks a repaired system runtime for the
    # process that lives there. Looking in one directory misses those.
    $out = @()
    foreach ($root in (Get-CitrixRoots)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $out += Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $script:VCRuntimeSet -contains $_.Name } |
            ForEach-Object {
                # A DLL only outranks the system copy for an executable in its
                # OWN directory. CWA leaves the redist payload behind in its
                # bootstrapper folders (Citrix Workspace 2507, Ctx-{GUID}),
                # where nothing loads it -- calling those a shim that shadows
                # the system runtime is simply wrong.
                $dir = $_.DirectoryName
                $exe = @(Get-ChildItem -LiteralPath $dir -Filter '*.exe' -File -ErrorAction SilentlyContinue |
                            Select-Object -ExpandProperty Name)
                [pscustomobject]@{
                    Name = $_.Name; Path = $_.FullName
                    Version = (ConvertTo-VersionOrNull $_.VersionInfo.FileVersion)
                    Exes = $exe
                }
            }
    }
    return $out
}

function Test-AppLocalShim {
    $copies = @(Get-AppLocalRuntimeCopy)
    if (-not $copies) {
        Add-Result 'App-local runtime shim' 'PASS' 'none anywhere under the Citrix tree (Citrix uses the system runtime)'
        return
    }
    $sysP = Join-Path (Join-Path $env:SystemRoot 'SysWOW64') 'msvcp140.dll'
    $sysV = if (Test-Path -LiteralPath $sysP) { ConvertTo-VersionOrNull (Get-Item -LiteralPath $sysP).VersionInfo.FileVersion } else { $null }
    $stale = @($copies | Where-Object { $sysV -and $_.Version -and $_.Version -lt $sysV })
    # A stale copy only matters where it shadows an executable on the LAUNCH
    # path. Every CWA install leaves its bundled redist (14.42 for 2507) in the
    # bootstrapper folder next to CWAInstaller.exe and friends, so any machine
    # whose system runtime is newer -- which is every patched machine -- would
    # otherwise raise this warning forever, on an endpoint with nothing wrong.
    $shadowing = @($stale | Where-Object { @($_.Exes | Where-Object { $script:CitrixLaunchExe -contains $_ }).Count -gt 0 })
    $installer = @($stale | Where-Object { $_ -notin $shadowing })

    if ($sysV -and $sysV -ge $MinVCRedist -and $shadowing) {
        Add-Result 'App-local runtime shim' 'WARN' `
            ("{0} copy(ies) older than the system runtime v{1} sit beside a launch executable and outrank it there, and are never serviced: {2}" -f `
                $shadowing.Count, $sysV, `
                (($shadowing | ForEach-Object { "$($_.Path)=$($_.Version) [loads for: $(($_.Exes | Where-Object { $script:CitrixLaunchExe -contains $_ } | Select-Object -First 3) -join ', ')]" }) -join '; ')) `
            'Delete them and re-test the launch (-Fix does this)' 'shim'
    } elseif ($installer) {
        $near = @(($installer | ForEach-Object { $_.Exes }) | Sort-Object -Unique | Select-Object -First 4)
        Add-Result 'App-local runtime shim' 'INFO' `
            ("{0} older redist file(s) in Citrix install folders, beside {1} -- nothing on the launch path loads them: {2}" -f `
                $installer.Count, `
                $(if ($near) { "installer components only ($($near -join ', '))" } else { 'no executable at all' }), `
                (($installer | ForEach-Object { $_.Path }) -join '; '))
    } else {
        Add-Result 'App-local runtime shim' 'INFO' `
            ("present (system v{0}): {1} -- not older than the system runtime" -f `
                $sysV, (($copies | ForEach-Object { "$($_.Path)=$($_.Version)" }) -join '; '))
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
            $ucProg = (Get-ItemProperty -LiteralPath $uc -ErrorAction SilentlyContinue).ProgId
            # A UserChoice pointing at the REPAIRED ProgID is harmless -- it just
            # pins the user to the fix. One pointing at the advertised ProgID is
            # the actual fault: it outranks the machine default, so that user
            # still triggers Installer self-repair and gets the Citrix
            # "can be modified only by an administrator" dialog on every launch.
            # Windows recreates it whenever the user picks an app from an
            # "Open with" prompt, so it can come back after a machine-level fix.
            if ($ucProg -and $ucProg -notmatch '\.NEW$') {
                Add-Result '.ica UserChoice override' 'FAIL' `
                    "$sid -> '$ucProg' is the advertised ProgID and outranks the machine setting; this user gets the admin-credentials dialog when opening a .ica" `
                    'Repair-IcaAssociation.ps1 (then that user must sign out and back in)' 'ica'
            } else {
                Add-Result '.ica UserChoice override' 'PASS' "$sid -> $ucProg (repaired ProgID)"
            }
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
    # This site does not configure stores at all: users launch from the
    # StoreFront/Epic web page and the Workspace app only executes the .ica the
    # browser downloads. An empty store list is therefore the intended state,
    # not a defect, so it is reported and never warned about. What actually
    # decides whether a web launch works -- the .ica association and the
    # receiver:// handler -- is checked separately above.
    if ($stores) { Add-Result 'Configured stores' 'PASS' ("{0} store entr(ies)" -f $stores.Count) }
    else { Add-Result 'Configured stores' 'INFO' 'none configured, and none expected: users launch from the web portal' }
}

function Get-CrashDetail {
    # Application Error (event 1000) publishes its fields as ordered properties:
    #   0 app name, 1 app version, 3 module name, 4 module version,
    #   6 exception code, 10 app path, 11 module path.
    # Read those rather than the rendered message: the "Faulting module name:"
    # labels are localised, so message parsing quietly returns nothing on a
    # non-English Windows. The message regex stays as a fallback.
    # Named $Record, not $Event: $Event is a PowerShell automatic variable.
    param([Parameter(Mandatory)]$Record)

    $d = [ordered]@{
        Time = $Record.TimeCreated; App = ''; AppVersion = ''; Module = ''
        ModuleVersion = ''; Code = ''; ModulePath = ''
    }
    $p = @()
    try { $p = @($Record.Properties | ForEach-Object { [string]$_.Value }) }
    catch { $p = @() }   # unreadable properties just fall through to the message
    if ($p.Count -ge 12) {
        $d.App = $p[0].Trim(); $d.AppVersion = $p[1].Trim(); $d.Module = $p[3].Trim()
        $d.ModuleVersion = $p[4].Trim(); $d.Code = $p[6].Trim(); $d.ModulePath = $p[11].Trim()
    }

    $m = [string]$Record.Message
    if ($m) {
        if (-not $d.App        -and $m -match 'Faulting application name:\s*([^,\r\n]+)') { $d.App = $Matches[1].Trim() }
        if (-not $d.Module     -and $m -match 'Faulting module name:\s*([^,\r\n]+)')      { $d.Module = $Matches[1].Trim() }
        if (-not $d.ModulePath -and $m -match 'Faulting module path:\s*([^\r\n]+)')       { $d.ModulePath = $Matches[1].Trim() }
        if (-not $d.Code       -and $m -match 'Exception code:\s*(0x[0-9a-fA-F]+)')       { $d.Code = $Matches[1].Trim() }
        # The versions matter as much as the names: the module version is what
        # proves whether a crash predates the repair, so it needs a fallback of
        # its own rather than riding on the properties being readable.
        if (-not $d.ModuleVersion -and $m -match 'Faulting module name:[^,\r\n]+,\s*version:\s*([^,\r\n]+)') {
            $d.ModuleVersion = $Matches[1].Trim()
        }
        if (-not $d.AppVersion -and $m -match 'Faulting application name:[^,\r\n]+,\s*version:\s*([^,\r\n]+)') {
            $d.AppVersion = $Matches[1].Trim()
        }
    }
    # The properties render the code bare ("c0000005"); prefix it so the log
    # shows the same form the Citrix and Microsoft articles use.
    if ($d.Code -match '^[0-9a-fA-F]{8}$') { $d.Code = "0x$($d.Code)" }
    return [pscustomobject]$d
}

function Get-ModuleVersionCandidate {
    # Versions of a module present on disk NOW at the path a crash recorded.
    # A 32-bit process reports its DLLs as loading from System32 even though
    # WOW64 redirected it to SysWOW64 -- HCDL-B14YRW3 logged
    # C:\Windows\SYSTEM32\MSVCP140.dll v14.22 for wfcrun32.exe, a 32-bit
    # process. Rather than guess the bitness, return both system directories
    # and let the caller require them to agree.
    param([Parameter(Mandatory)][string]$Path)

    $paths = @($Path)
    $sys = (Join-Path $env:SystemRoot 'System32').TrimEnd('\')
    $wow = (Join-Path $env:SystemRoot 'SysWOW64').TrimEnd('\')
    $leaf = Split-Path -Leaf $Path
    $dir  = (Split-Path -Parent $Path)
    if ($dir -and $leaf) {
        $dir = $dir.TrimEnd('\')
        if     ($dir -ieq $sys) { $paths += (Join-Path $wow $leaf) }
        elseif ($dir -ieq $wow) { $paths += (Join-Path $sys $leaf) }
    }
    $out = @()
    foreach ($p in ($paths | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $v = ConvertTo-VersionOrNull (Get-Item -LiteralPath $p -ErrorAction SilentlyContinue).VersionInfo.FileVersion
        if ($v) { $out += $v }
    }
    return $out
}

function Test-RecentCrashes {
    $since = (Get-Date).AddHours(-$EventHours)
    $events = Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='Application Error'; StartTime=$since } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'wfcrun32|SelfService|wfica32|CDViewer|Receiver\.exe|AuthManSvr|Cleanup\.exe' }
    if (-not $events) {
        Add-Result "Citrix crashes (last ${EventHours}h)" 'PASS' 'none'
        return
    }
    $details = @($events | ForEach-Object { Get-CrashDetail $_ })
    $mods = @($details | Where-Object { $_.Module } | Select-Object -ExpandProperty Module | Sort-Object -Unique)
    foreach ($d in ($details | Select-Object -First 5)) {
        # Log the module's PATH and VERSION, not just its name. "faulted in
        # MSVCP140.dll" cannot tell you whether the process bound the repaired
        # system DLL or an old private copy next to the exe -- and those need
        # opposite fixes. The event already carries both; print them.
        Write-Log ("         {0:HH:mm:ss} {1} faulted in {2} v{3} {4} [{5}]" -f `
            $d.Time, ($d.App -replace '^$','?'), ($d.Module -replace '^$','?'), `
            ($d.ModuleVersion -replace '^$','?'), $d.Code, ($d.ModulePath -replace '^$','path unknown')) 'WARNING'
    }

    # Where the faulting module actually loaded from decides the remedy.
    $sysRoot  = $env:SystemRoot.TrimEnd('\')
    $private  = @($details | Where-Object { $_.ModulePath -and $_.ModulePath -notlike "$sysRoot\*" -and
                                            $script:VCRuntimeSet -contains $_.Module } |
                    Select-Object -ExpandProperty ModulePath -Unique)
    $runtimeOk = (Test-RuntimeOk -Kind 'vcx86') -and (Test-RuntimeOk -Kind 'vcx64')

    $remedy =
        if ($private) {
            "The faulting runtime DLL did NOT load from $sysRoot -- it came from $($private -join '; '). A private copy beside the exe outranks the system runtime; remove it (this script's -Fix does) and re-test."
        }
        elseif ($mods -match 'MSVCP140|VCRUNTIME140') {
            if ($runtimeOk) {
                # Do not repeat the below-minimum diagnosis when this run just
                # measured the runtime as fine -- that sends whoever reads the
                # log to reinstall something that is already current.
                'The system VC++ already meets the minimum, so this is NOT the below-minimum crash. Check the "VC++ set consistency" result above, then run Get-CitrixLaunchDiagnostics.ps1 while the affected user is signed in.'
            } else {
                'Install-CitrixPrerequisites.ps1 -- crashes in the VC++ runtime mean it is below CWA minimum'
            }
        }
        elseif ($mods -match 'coreclr') {
            # coreclr.dll is where a managed exception surfaces, so the fault is
            # usually an unhandled .NET exception in SelfService, not a bad
            # runtime. Reinstalling .NET does nothing for it.
            'coreclr.dll is where an unhandled .NET exception surfaces -- it is usually an application fault in SelfService, not a bad .NET runtime. Check the .NET result above; if it passes, read C:\Program Files (x86)\Citrix\ICA Client\SelfServicePlugin logs and confirm the store SelfService is trying to reach.'
        }
        else { 'Review C:\Program Files (x86)\Citrix\Logs and %TEMP%\CTXWorkspaceInstallLogs' }

    # Only claim a category -Fix can actually act on. Sending a machine whose
    # runtimes all pass through the prereq fix just logs "applying fixes" and
    # changes nothing, which reads as a repair that silently failed.
    $category = if ($private) { 'shim' } elseif (-not $runtimeOk) { 'prereq' } else { '' }

    # A crash that happened BEFORE the runtime was repaired is history, not a
    # live fault -- but it stays in the event log for the whole lookback window,
    # so without this a successful remediation shows red in WS1 for 24 hours.
    #
    # Prove it from the events themselves. Event 1000 records the VERSION of the
    # module that faulted; if every copy of that module on disk today is newer,
    # the machine is no longer running the DLL that crashed and the fault cannot
    # recur as recorded.
    #
    # This is deliberately not judged by the DLL's LastWriteTime any more.
    # Installers routinely preserve a file's original build timestamp, so a
    # runtime repaired this morning can carry a write time from years earlier.
    # HCDL-B14YRW3 proved it: wfcrun32.exe faulted in MSVCP140.dll v14.22.27821.0
    # at 11:54, the same path held v14.44.35211.0 by 12:45, and the timestamp
    # rule still reported the crash as live.
    $evidence = @()
    foreach ($d in $details) {
        if (-not $d.ModulePath -or -not $d.ModuleVersion) { continue }
        $was = ConvertTo-VersionOrNull $d.ModuleVersion
        if (-not $was) { continue }
        $now = @(Get-ModuleVersionCandidate -Path $d.ModulePath)
        if (-not $now) { continue }
        # Every candidate must be newer. If one architecture still carries the
        # old build, the fault can still happen and this proves nothing.
        if (@($now | Where-Object { $_ -le $was }).Count -eq 0) {
            $evidence += [pscustomobject]@{
                Time = $d.Time; Module = $d.Module; Was = $was
                Now = (($now | Sort-Object -Unique) -join '/')
            }
        }
    }

    # The latest crash we can prove was superseded also dates the repair: it
    # happened after that crash. Anything at or before that moment is therefore
    # pre-repair too, which covers the collateral faults -- SelfService dying in
    # coreclr.dll minutes earlier is the same stale runtime, and .NET Core links
    # against the VC++ redist, so it never records a version of its own to test.
    $proven = $evidence | Sort-Object Time -Descending | Select-Object -First 1
    $newest = ($details | Sort-Object Time -Descending | Select-Object -First 1).Time

    if ($runtimeOk -and $proven -and $newest -le $proven.Time) {
        Add-Result "Citrix crashes (last ${EventHours}h)" 'WARN' `
            ("{0} crash event(s) [{1}], newest {2:HH:mm:ss} -- all pre-repair: {3} faulted at v{4} and every copy on disk is now v{5}" -f `
                $details.Count, ($mods -join ', '), $newest, $proven.Module, $proven.Was, $proven.Now) `
            'Historical, not a live fault. Have a user launch a published app to confirm; the next run past the lookback window clears this by itself.'
        return
    }
    Add-Result "Citrix crashes (last ${EventHours}h)" 'FAIL' `
        ("{0} crash event(s); faulting module(s): {1}" -f $events.Count, ($mods -join ', ')) $remedy $category
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
# Repairs -- self-contained so this script works deployed on its own.
# Only the full CWA reinstall delegates, and only if the sibling is present.
# ---------------------------------------------------------------------------
function Invoke-Download {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutFile)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    for ($i = 1; $i -le 3; $i++) {
        try {
            Write-Log "    downloading (attempt $i): $Url"
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
            if ((Get-Item -LiteralPath $OutFile).Length -lt 100KB) { throw 'file suspiciously small' }
            return $true
        } catch {
            Write-Log "    download failed: $($_.Exception.Message)" 'WARNING'
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            if ($i -lt 3) { Start-Sleep -Seconds ([math]::Pow(2, $i)) }
        }
    }
    return $false
}

function Convert-ToPackedGuid {
    # MSI stores product codes packed: {A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
    # -> 4D3C2B1A6F5E0987BADCFE2143658709
    param([Parameter(Mandatory)][string]$Guid)
    $g = $Guid -replace '[{}\-]', ''
    if ($g.Length -ne 32) { return $null }
    $rev  = { param($s) ($s.ToCharArray())[($s.Length-1)..0] -join '' }
    $swap = { param($s) -join (0..($s.Length/2 - 1) | ForEach-Object { $s.Substring($_*2,2).ToCharArray()[1,0] -join '' }) }
    (& $rev $g.Substring(0,8)) + (& $rev $g.Substring(8,4)) + (& $rev $g.Substring(12,4)) +
    (& $swap $g.Substring(16,4)) + (& $swap $g.Substring(20,12))
}

function Remove-OrphanedMsiRegistration {
    # A product whose cached package is gone cannot be repaired, upgraded or
    # uninstalled (System Error 1612). Clearing the registration lets a fresh
    # install proceed with nothing to remove. Everything is exported first.
    param([Parameter(Mandatory)][string]$NamePattern)
    $backupDir = Join-Path $DestinationFolder 'health-regbackup'
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }

    $targets = @()
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -and $p.DisplayName -like $NamePattern -and $_.PSChildName -match '^\{[0-9A-Fa-f\-]{36}\}$') {
                $targets += [pscustomobject]@{ Guid = $_.PSChildName; Name = $p.DisplayName; Key = $_.PSPath }
            }
        }
    }
    if (-not $targets) { Write-Log "    no product matched '$NamePattern'" 'WARNING'; return $false }

    $removed = $false
    foreach ($t in $targets) {
        $packed = Convert-ToPackedGuid -Guid $t.Guid
        if (-not $packed) { continue }
        Write-Log "    clearing: $($t.Name) $($t.Guid)" 'WARNING'
        $keys = @(
            ($t.Key -replace '^Microsoft\.PowerShell\.Core\\Registry::', 'Registry::'),
            "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\Installer\Products\$packed",
            "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\Installer\Features\$packed",
            "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$packed"
        )
        foreach ($k in $keys) {
            if (-not (Test-Path -LiteralPath $k)) { continue }
            $regPath = ($k -replace '^Registry::', '')
            $file = Join-Path $backupDir ("{0}_{1}.reg" -f $t.Guid.Trim('{}'), [IO.Path]::GetFileName($regPath))
            & reg.exe export $regPath $file /y 2>&1 | Out-Null
            if (-not (Test-Path -LiteralPath $file)) { Write-Log "    backup failed for $regPath; not deleting" 'ERROR'; continue }
            try { Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction Stop; $removed = $true }
            catch { Write-Log "    could not remove ${regPath}: $($_.Exception.Message)" 'ERROR' }
        }
    }
    if ($removed) { Write-Log "    registrations cleared (backups: $backupDir)" 'WARNING' }
    return $removed
}

function Install-PrereqViaWinget {
    # Fallback when the direct download is blocked. winget uses its own
    # transport and its own source, so it frequently succeeds on networks where
    # a raw HTTPS GET to aka.ms is intercepted or refused.
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Name)
    $wg = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source -ErrorAction SilentlyContinue
    if (-not $wg) {
        $wg = Get-ChildItem -LiteralPath (Join-Path $env:ProgramFiles 'WindowsApps') -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'winget.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    $portable = Join-Path $DestinationFolder 'winget-portable\winget.exe'
    if (-not $wg -and (Test-Path -LiteralPath $portable)) { $wg = $portable }
    if (-not $wg) { Write-Log '    winget not available for fallback.' 'WARNING'; return $false }

    $wgArgs = "install --exact --id $Id --silent --force --accept-package-agreements --accept-source-agreements --disable-interactivity"
    Write-Log "    falling back to winget: $Id" 'WARNING'
    try {
        $p = Start-Process -FilePath $wg -ArgumentList $wgArgs -WorkingDirectory (Split-Path -Path $wg -Parent) `
             -PassThru -WindowStyle Hidden -ErrorAction Stop
        $null = $p.Handle
        if (-not $p.WaitForExit(900000)) {
            & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
            Write-Log '    winget fallback timed out.' 'ERROR'; return $false
        }
    } catch { Write-Log "    winget fallback could not start: $($_.Exception.Message)" 'ERROR'; return $false }
    if ($p.ExitCode -eq 0) { Write-Log "    winget installed $Name."; return $true }
    Write-Log "    winget fallback returned $($p.ExitCode) for $Id." 'WARNING'
    return $false
}

function Repair-RuntimePrereq {
    # Install/repair VC++ and .NET; clear an orphaned registration first when
    # the MSI cache check found one, since nothing else can succeed until then.
    param([bool]$OrphanFound)
    $work = Join-Path $DestinationFolder 'health-prereqs'
    if (-not (Test-Path -LiteralPath $work)) { New-Item -Path $work -ItemType Directory -Force | Out-Null }

    $pkgs = @(
        @{ Name='VC++ x86'; Kind='vcx86'; Url='https://aka.ms/vs/17/release/vc_redist.x86.exe'; File='vc_redist.x86.exe'; Orphan='Microsoft Visual C++ * X86 *Runtime*'; WingetId='Microsoft.VCRedist.2015+.x86' }
        @{ Name='VC++ x64'; Kind='vcx64'; Url='https://aka.ms/vs/17/release/vc_redist.x64.exe'; File='vc_redist.x64.exe'; Orphan='Microsoft Visual C++ * X64 *Runtime*'; WingetId='Microsoft.VCRedist.2015+.x64' }
        @{ Name='.NET Desktop 8 x86'; Kind='netx86'; Url='https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x86.exe'; File='ndp-x86.exe'; Orphan=$null; WingetId='Microsoft.DotNet.DesktopRuntime.8' }
        @{ Name='.NET Desktop 8 x64'; Kind='netx64'; Url='https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe'; File='ndp-x64.exe'; Orphan=$null; WingetId='Microsoft.DotNet.DesktopRuntime.8' }
    )
    $reboot = $false
    foreach ($pkg in $pkgs) {
        # Only touch what is actually failing.
        $needed = -not (Test-RuntimeOk -Kind $pkg.Kind)
        if (-not $needed) { continue }
        Write-Log "  Repairing $($pkg.Name)" 'WARNING'
        if ($OrphanFound -and $pkg.Orphan) { Remove-OrphanedMsiRegistration -NamePattern $pkg.Orphan | Out-Null }
        $target = Join-Path $work $pkg.File
        if (-not (Invoke-Download -Url $pkg.Url -OutFile $target)) {
            # Direct download can fail on locked-down networks (TLS interception,
            # aka.ms blocked) even where winget works, since winget uses its own
            # transport. Fall back to it rather than giving up on the runtime.
            if ($pkg.WingetId -and (Install-PrereqViaWinget -Id $pkg.WingetId -Name $pkg.Name)) {
                if (Test-RuntimeOk -Kind $pkg.Kind) { Write-Log "    $($pkg.Name): resolved via winget."; continue }
                Write-Log "    $($pkg.Name): winget install ran but the runtime is still below minimum." 'ERROR'
            }
            continue
        }
        $logFile = Join-Path $work ("{0}.log" -f ($pkg.File -replace '\.exe$',''))
        $code = Invoke-PrereqInstaller -Installer $target -LogFile $logFile -Name $pkg.Name
        switch ($code) {
            0    { Write-Log "    $($pkg.Name): installed." }
            3010 { Write-Log "    $($pkg.Name): installed, reboot required." 'WARNING'; $reboot = $true }
            default {
                Write-Log "    $($pkg.Name): installer returned $code" 'ERROR'
                Write-PrereqLogErrors -Work $work -LogFile $logFile
                # Self-escalate on ERROR_INSTALL_SOURCE_ABSENT. The cached
                # package (or a cached patch) is gone, so RemoveExistingProducts
                # can never succeed and no retry of the same install will help.
                # This is deliberately driven by the ACTUAL error rather than by
                # the MSI-cache pre-check: on HCDL-B14YRW3 that check passed and
                # the install still failed 1612, because a missing cached PATCH
                # produces the same failure as a missing cached product.
                if ($pkg.Orphan -and (Test-MsiSourceAbsent -Work $work -LogFile $logFile)) {
                    Write-Log "    $($pkg.Name): MSI reports the cached source is absent (1612/1714)." 'ERROR'
                    Write-Log "    Escalating: clearing the stale registration, then retrying the install." 'WARNING'
                    if (Remove-OrphanedMsiRegistration -NamePattern $pkg.Orphan) {
                        $retryLog = Join-Path $work ("{0}-retry.log" -f ($pkg.File -replace '\.exe$',''))
                        $code2 = Invoke-PrereqInstaller -Installer $target -LogFile $retryLog -Name $pkg.Name
                        switch ($code2) {
                            0    { Write-Log "    $($pkg.Name): installed after clearing the stale registration." }
                            3010 { Write-Log "    $($pkg.Name): installed after clearing; reboot required." 'WARNING'; $reboot = $true }
                            default {
                                Write-Log "    $($pkg.Name): still failing after escalation (exit $code2)." 'ERROR'
                                Write-PrereqLogErrors -Work $work -LogFile $retryLog
                            }
                        }
                    } else {
                        Write-Log "    Nothing could be cleared; the runtime remains below minimum." 'ERROR'
                    }
                }
            }
        }
        if (Test-RuntimeOk -Kind $pkg.Kind) { Write-Log "    $($pkg.Name): verified on disk." }
        else { Write-Log "    $($pkg.Name): STILL below minimum on disk." 'ERROR' }
    }
    return $reboot
}

function Invoke-PrereqInstaller {
    param([Parameter(Mandatory)][string]$Installer, [Parameter(Mandatory)][string]$LogFile, [Parameter(Mandatory)][string]$Name)
    try {
        $p = Start-Process -FilePath $Installer -ArgumentList '/install','/quiet','/norestart','/log',"`"$LogFile`"" -PassThru -Wait -ErrorAction Stop
        return $p.ExitCode
    } catch {
        Write-Log "    could not launch $Name installer: $($_.Exception.Message)" 'ERROR'
        return -1
    }
}

function Get-PrereqLogFiles {
    # Burn writes sibling MSI logs alongside the bundle log it was given.
    param([Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$LogFile)
    Get-ChildItem -LiteralPath $Work -Filter "$([IO.Path]::GetFileNameWithoutExtension($LogFile))*.log" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName }
}

function Write-PrereqLogErrors {
    param([Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$LogFile)
    $files = @(Get-PrereqLogFiles -Work $Work -LogFile $LogFile)
    if (-not $files) { return }
    Select-String -LiteralPath $files -Pattern 'Error \d+|System Error \d+|return value 3|Failed to resolve source' -ErrorAction SilentlyContinue |
        Select-Object -Last 4 | ForEach-Object { Write-Log ("      {0}" -f $_.Line.Trim()) 'WARNING' }
}

function Test-MsiSourceAbsent {
    # System Error 1612 = ERROR_INSTALL_SOURCE_ABSENT; 1714 is the
    # "older version cannot be removed" that it surfaces as.
    param([Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$LogFile)
    $files = @(Get-PrereqLogFiles -Work $Work -LogFile $LogFile)
    if (-not $files) { return $false }
    $hit = Select-String -LiteralPath $files -Pattern 'System Error 1612|Error 1714|SOURCEMGMT: Failed to resolve source' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    return [bool]$hit
}

function Test-RuntimeOk {
    param([Parameter(Mandatory)][ValidateSet('vcx86','vcx64','netx86','netx64')][string]$Kind)
    switch ($Kind) {
        'vcx86' { $f = Join-Path (Join-Path $env:SystemRoot 'SysWOW64') 'msvcp140.dll' }
        'vcx64' { $f = Join-Path (Join-Path $env:SystemRoot 'System32') 'msvcp140.dll' }
        default { $f = $null }
    }
    if ($f) {
        if (-not (Test-Path -LiteralPath $f)) { return $false }
        $v = ConvertTo-VersionOrNull (Get-Item -LiteralPath $f).VersionInfo.FileVersion
        return ($v -and $v -ge $MinVCRedist)
    }
    $root = if ($Kind -eq 'netx64') { Join-Path $env:ProgramFiles 'dotnet\shared\Microsoft.WindowsDesktop.App' }
            else { Join-Path ${env:ProgramFiles(x86)} 'dotnet\shared\Microsoft.WindowsDesktop.App' }
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { return $false }
    $best = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { ConvertTo-VersionOrNull $_.Name } |
        Where-Object { $_ -and $_.Major -eq 8 } | Sort-Object -Descending | Select-Object -First 1
    return ($best -and $best -ge $MinDotNet)
}

function Repair-AutoUpdatePolicy {
    # Disabled, with the stream still pinned to LTSR so re-enabling checks
    # later cannot drift the machine onto Current Release.
    $values = [ordered]@{ AutoUpdateCheck = 'Disabled'; AutoUpdateStream = 'LTSR' }
    $ok = $false
    foreach ($key in @('HKLM:\SOFTWARE\WOW6432Node\Citrix\ICA Client\AutoUpdate',
                       'HKLM:\SOFTWARE\Citrix\ICA Client\AutoUpdate')) {
        try {
            if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force -ErrorAction Stop | Out-Null }
            foreach ($e in $values.GetEnumerator()) {
                New-ItemProperty -Path $key -Name $e.Key -Value $e.Value -PropertyType String -Force -ErrorAction Stop | Out-Null
            }
            Write-Log "  Auto-update policy set: $key -> AutoUpdateCheck=Disabled, AutoUpdateStream=LTSR"
            $ok = $true
        } catch { Write-Log "  could not write ${key}: $($_.Exception.Message)" 'WARNING' }
    }
    return $ok
}

function Repair-IcaAssociationNative {
    # Republish under a non-advertised ProgID so launching stops triggering
    # Windows Installer self-repair, and clear per-user overrides that would
    # otherwise outrank the machine setting.
    $ica = Get-CitrixRoots | ForEach-Object { Join-Path $_ 'ICA Client' } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ 'wfcrun32.exe') } | Select-Object -First 1
    if (-not $ica) { Write-Log '  cannot repair .ica: wfcrun32.exe not found' 'ERROR'; return $false }
    $wfcrun32 = Join-Path $ica 'wfcrun32.exe'

    $current = Get-DefaultValue -Path 'Registry::HKEY_CLASSES_ROOT\.ica'
    $base = if ($current) { $current } else { 'Citrix.ICAClient' }
    while ($base -match '\.NEW$') { $base = $base -replace '\.NEW$', '' }
    $target = "$base.NEW"
    $command = '"{0}" "%1"' -f $wfcrun32

    try {
        $cmdKey = "HKLM:\SOFTWARE\Classes\$target\shell\open\command"
        New-Item -Path $cmdKey -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -LiteralPath $cmdKey -Name '(default)' -Value $command -ErrorAction Stop
        Set-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Classes\$target" -Name '(default)' -Value 'Citrix ICA Client' -ErrorAction SilentlyContinue
        New-Item -Path 'HKLM:\SOFTWARE\Classes\.ica' -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Classes\.ica' -Name '(default)' -Value $target -ErrorAction Stop
        Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Classes\.ica' -Name 'Content Type' -Value 'application/x-ica' -ErrorAction SilentlyContinue
        Write-Log "  .ica repointed -> $target -> $command"
    } catch {
        Write-Log "  could not write the .ica association: $($_.Exception.Message)" 'ERROR'
        return $false
    }

    foreach ($sid in (Get-LoadedUserHives)) {
        foreach ($p in @("Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.ica\UserChoice",
                         "Registry::HKEY_USERS\$sid\SOFTWARE\Classes\.ica")) {
            if (-not (Test-Path -LiteralPath $p)) { continue }
            try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
                  Write-Log "  removed per-user override: $p" 'WARNING' }
            catch { Write-Log "  could not remove ${p}: $($_.Exception.Message)" 'WARNING' }
        }
    }
    Write-Log '  affected users must sign out and back in before Explorer picks this up.' 'WARNING'
    return $true
}

function Remove-StaleShim {
    # Remove app-local VC++ runtime copies wherever they sit in the Citrix
    # tree, so the process falls back to the serviced system runtime. Only
    # copies OLDER than the system DLL are touched: a copy that is newer is
    # doing real work, and deleting it would break the app rather than fix it.
    $sysP = Join-Path (Join-Path $env:SystemRoot 'SysWOW64') 'msvcp140.dll'
    $sysV = if (Test-Path -LiteralPath $sysP) { ConvertTo-VersionOrNull (Get-Item -LiteralPath $sysP).VersionInfo.FileVersion } else { $null }
    if (-not $sysV -or $sysV -lt $MinVCRedist) {
        Write-Log '  system runtime is not healthy enough to fall back to; leaving app-local copies in place.' 'WARNING'
        return $false
    }
    $removed = $false
    foreach ($c in (Get-AppLocalRuntimeCopy)) {
        if (-not $c.Version -or $c.Version -ge $sysV) {
            Write-Log "  keeping $($c.Path) (v$($c.Version), not older than system v$sysV)"
            continue
        }
        if (@($c.Exes | Where-Object { $script:CitrixLaunchExe -contains $_ }).Count -eq 0) {
            # Nothing on the launch path loads it, so deleting it fixes nothing.
            # The Citrix installer components beside it ran fine against this
            # very copy, and removing a file the bootstrapper shipped is a
            # change to the install footprint with no upside.
            Write-Log "  keeping $($c.Path) (no launch-path executable in that folder loads it)"
            continue
        }
        try { Remove-Item -LiteralPath $c.Path -Force -ErrorAction Stop
              Write-Log "  removed stale app-local shim: $($c.Path) (v$($c.Version) < system v$sysV)" 'WARNING'; $removed = $true }
        catch { Write-Log "  could not remove $($c.Path): $($_.Exception.Message)" 'WARNING' }
    }
    return $removed
}

function Install-CwaNative {
    # Install CWA LTSR without needing Reinstall-CitrixLTSR.ps1 present, so a
    # standalone deployment of this script can actually install.
    # Source order: -InstallerPath -> payload beside this script -> winget
    # (Citrix.Workspace.LTSR, the LTSR manifest -- never Current Release).
    # Auto-update is disabled on the command line so the machine cannot be
    # offered Current Release again the moment it comes up.
    $installer = $null

    if ($InstallerPath) {
        if (Test-Path -LiteralPath $InstallerPath) {
            $installer = $InstallerPath
            Write-Log "  installer (explicit): $installer"
        } else {
            Write-Log "  -InstallerPath specified but not found: $InstallerPath" 'ERROR'
            return $false
        }
    }
    if (-not $installer) {
        $dir = Split-Path -Parent $PSCommandPath
        if ($dir) {
            $local = Get-ChildItem -LiteralPath $dir -Filter 'CitrixWorkspaceApp*.exe' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($local) { $installer = $local.FullName; Write-Log "  installer (payload beside script): $installer" }
        }
    }
    if (-not $installer) {
        $wg = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source -ErrorAction SilentlyContinue
        if (-not $wg) {
            $wg = Get-ChildItem -LiteralPath (Join-Path $env:ProgramFiles 'WindowsApps') -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'winget.exe' } |
                Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        }
        $portable = Join-Path $DestinationFolder 'winget-portable\winget.exe'
        if (-not $wg -and (Test-Path -LiteralPath $portable)) { $wg = $portable }
        if (-not $wg) {
            Write-Log '  no installer available and winget.exe was not found.' 'ERROR'
            Write-Log '  Pass -InstallerPath, put CitrixWorkspaceApp*.exe beside this script, or repair winget first.' 'ERROR'
            return $false
        }
        $dlDir = Join-Path $DestinationFolder 'health-winget-dl'
        if (Test-Path -LiteralPath $dlDir) { Remove-Item -LiteralPath $dlDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -Path $dlDir -ItemType Directory -Force | Out-Null
        $wgArgs = "download --exact --id $WingetId --download-directory `"$dlDir`" --accept-package-agreements --accept-source-agreements --disable-interactivity"
        Write-Log "  staging via winget: $wg $wgArgs"
        try {
            $p = Start-Process -FilePath $wg -ArgumentList $wgArgs -WorkingDirectory (Split-Path -Path $wg -Parent) `
                 -PassThru -WindowStyle Hidden -ErrorAction Stop
            $null = $p.Handle
            if (-not $p.WaitForExit(900000)) {
                & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
                Write-Log '  winget download timed out after 900s.' 'ERROR'; return $false
            }
            if ($p.ExitCode -ne 0) { Write-Log "  winget download returned $($p.ExitCode)." 'ERROR'; return $false }
        } catch { Write-Log "  could not run winget: $($_.Exception.Message)" 'ERROR'; return $false }
        $exe = Get-ChildItem -LiteralPath $dlDir -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue |
            Sort-Object Length -Descending | Select-Object -First 1
        if (-not $exe) { Write-Log '  winget download produced no installer.' 'ERROR'; return $false }
        $installer = $exe.FullName
        Write-Log "  installer (winget): $installer"
    }

    Unblock-File -LiteralPath $installer -ErrorAction SilentlyContinue
    $cwaArgs = '/silent /forceinstall /noreboot /AutoUpdateCheck=disabled'
    Write-Log "  running: `"$installer`" $cwaArgs"
    try {
        $ip = Start-Process -FilePath $installer -ArgumentList $cwaArgs -PassThru -ErrorAction Stop
        $null = $ip.Handle
        if (-not $ip.WaitForExit(1800000)) {
            & taskkill.exe /PID $ip.Id /T /F 2>&1 | Out-Null
            Write-Log '  CWA installer exceeded 1800s and was terminated.' 'ERROR'; return $false
        }
        $code = $ip.ExitCode
        if ($null -eq $code) { $code = 0 }
    } catch { Write-Log "  could not launch the CWA installer: $($_.Exception.Message)" 'ERROR'; return $false }

    # Citrix installer exit codes per CTX695019.
    switch ($code) {
        0     { Write-Log '  CWA installed (exit 0).'; return $true }
        3010  { Write-Log '  CWA installed; reboot required to finalize (3010).' 'WARNING'; return $true }
        40032 { Write-Log '  CWA reports it is already up to date (40032); nothing was reinstalled.' 'WARNING'; return $true }
        40026 { Write-Log '  installer could not stop processes/drivers (40026). Reboot and re-run.' 'ERROR'; return $false }
        40034 { Write-Log '  Windows Installer failure (40034). Check %TEMP%\CTXWorkspaceInstallLogs.' 'ERROR'; return $false }
        1603  { Write-Log '  fatal installer error 1603. Check %TEMP%\CTXWorkspaceInstallLogs.' 'ERROR'; return $false }
        default { Write-Log "  CWA installer returned $code (see Citrix CTX695019)." 'ERROR'; return $false }
    }
}

function Invoke-Fixes {
    param([Parameter(Mandatory)][string[]]$Keys)
    $rebootNeeded = $false

    # Order matters: runtime first (nothing downstream works while CWA crashes
    # on launch), then policy, then associations, then shim cleanup last so it
    # is only removed once the system runtime is actually good.
    if ($Keys -contains 'prereq' -or $Keys -contains 'prereq-orphan') {
        Write-Log '--- Fix: runtime prerequisites ---' 'WARNING'
        $rebootNeeded = Repair-RuntimePrereq -OrphanFound ($Keys -contains 'prereq-orphan')
    }
    if ($Keys -contains 'reinstall') {
        Write-Log '--- Fix: Citrix Workspace install ---' 'WARNING'
        # Prefer the full script when it is present (richer installer sourcing,
        # MSI mutex handling, hash verification); otherwise install natively so
        # a standalone deployment is not left unable to install anything.
        $dir = Split-Path -Parent $PSCommandPath
        $sib = if ($dir) { Join-Path $dir 'Reinstall-CitrixLTSR.ps1' } else { $null }
        if ($sib -and (Test-Path -LiteralPath $sib)) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sib
            Write-Log ("  Reinstall-CitrixLTSR.ps1 exit code: {0}" -f $LASTEXITCODE) 'WARNING'
        } else {
            Write-Log '  Reinstall-CitrixLTSR.ps1 not present; installing natively.' 'WARNING'
            if (Install-CwaNative) { Write-Log '  CWA install completed.' }
            else { Write-Log '  CWA install did not complete; see the errors above.' 'ERROR' }
        }
    }
    if ($Keys -contains 'autoupdate') {
        Write-Log '--- Fix: auto-update policy ---' 'WARNING'
        Repair-AutoUpdatePolicy | Out-Null
    }
    if ($Keys -contains 'ica') {
        Write-Log '--- Fix: .ica association ---' 'WARNING'
        Repair-IcaAssociationNative | Out-Null
    }
    if ($Keys -contains 'shim') {
        Write-Log '--- Fix: stale app-local runtime shim ---' 'WARNING'
        if (Test-RuntimeOk -Kind 'vcx86') { Remove-StaleShim | Out-Null }
        else { Write-Log '  system runtime is still below minimum; leaving the shim in place.' 'WARNING' }
    }
    if ($rebootNeeded) { Write-Log 'A reboot is required to finalize the runtime changes.' 'WARNING' }
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
