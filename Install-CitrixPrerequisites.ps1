<#
.SYNOPSIS
    Install-CitrixPrerequisites.ps1 -- verify and repair the runtime
    prerequisites Citrix Workspace app 2507 LTSR depends on. Fixes CWA
    components that install successfully but then CRASH on launch
    (0xc0000005 in MSVCP140.dll or coreclr.dll), which presents to the user
    as "I click it and nothing happens".

.DESCRIPTION
    CWA 2507 does not statically link its runtimes. If the machine's Visual
    C++ or .NET Desktop runtimes are older than CWA requires, the installer
    still reports success and the registry still looks perfect -- but
    wfcrun32.exe / SelfService.exe access-violate the moment they start.
    Nothing is logged by Citrix; the only evidence is Application event 1000.

    Observed on HCDL-BP0WCW3 (2026-07-31):
        Faulting application: wfcrun32.exe 25.7.2000.6
        Faulting module:      MSVCP140.dll 14.22.27821.0   <- VC++ 2019, far
        Exception code:       0xc0000005                       below minimum
        Faulting application: SelfService.exe 25.7.2000.11
        Faulting module:      coreclr.dll 8.0.2926.32403

    Minimums enforced here match Citrix's stated CWA 2507 prerequisites:
        Visual C++ redistributable  >= 14.42.34433.0  (x86 AND x64)
        .NET Desktop Runtime 8      >= 8.0.11         (x86 AND x64)

    Also checks for APP-LOCAL runtime DLLs inside the Citrix program folders.
    Windows resolves those before the system copies, so a stale msvcp140.dll
    sitting next to wfcrun32.exe keeps the crash alive no matter how current
    the system redistributable is. Those are reported, never auto-deleted --
    removing a DLL Citrix legitimately shipped would break the install.

    Flow:
      1. Initialize logging (C:\drop\citrix, 30-day rotation).
      2. Report installed VC++ (registry + actual system DLL versions) and
         .NET Desktop Runtime versions.
      3. Report any app-local runtime DLLs under the Citrix folders.
      4. Install whatever is missing or below minimum (unless -CheckOnly).
      5. Re-verify and report what still needs a reboot.

    Exit codes (WS1):
      0 = all prerequisites met (already, or after install)
      1 = met but a reboot is required to finalize, or app-local DLLs found,
          or the shim was requested and could not be fully applied
      2 = fatal (not elevated, download failed, still below minimum after
          install)
      3 = -CheckOnly and at least one prerequisite is below minimum

.PARAMETER CheckOnly
    Report only; install nothing. Use as a WS1 detection rule.

.PARAMETER ForceReinstall
    For a VC++ package whose repair failed: uninstall it and install fresh.
    Heavier than /repair -- other applications depend on this runtime, so
    there is a window between uninstall and install where they would fail to
    start. Use when /repair returns 1603 and a reboot has not helped.

.PARAMETER ShimAppLocal
    Workaround that does not depend on fixing the system runtime at all:
    copy a known-good msvcp140.dll / vcruntime140.dll (taken from the Citrix
    install itself) into the folder containing wfcrun32.exe. Windows resolves
    app-local DLLs before the system ones, so CWA binds the good copy while
    SysWOW64 stays as-is. This is Microsoft's documented "local deployment"
    model and is exactly what Citrix already does for its own subfolders on
    this machine. Reversible: delete the two files from the ICA Client folder.
    Affects only Citrix, not other applications.

.PARAMETER RemoveOrphanedRegistration
    Last resort for MSI System Error 1612. When a product is registered but
    its cached package under C:\Windows\Installer is gone, Windows Installer
    can neither remove, repair nor upgrade it -- RemoveExistingProducts fails
    and takes every install down with it. This clears the stale registration
    (Uninstall key, Installer\Products, \Features, UserData) and then installs
    fresh. Every key is exported to .reg under C:\drop\citrix\prereqs\regbackup
    before deletion, and a key whose backup fails is left alone. This edits the
    Windows Installer database directly -- use it only once the gentler steps
    have been tried and the logs show 1612.

.PARAMETER DryRun
    Log what would be downloaded/installed without doing it.

.NOTES
    Author  : MEB -- Oak Street Health / CVS Health IT Operations
    Version : 1.5.0
    Date    : 2026-07-31
    v1.5.0  : /layout produced no MSI on HCDL-BP0WCW3, so source-repair could
              not run either. The layout step now logs what it actually
              extracted and also looks beside the bundle. Added the real last
              resort for System Error 1612, -RemoveOrphanedRegistration: the
              product is registered but its cached package is gone, so
              RemoveExistingProducts can never succeed; clearing the stale
              registration (Uninstall key, Installer\Products, \Features and
              UserData, each exported to .reg first) lets a fresh install
              proceed with nothing to remove.
    v1.4.0  : The captured MSI log on HCDL-BP0WCW3 showed the real cause:
              "SOURCEMGMT: Failed to resolve source" + Error 1714 / System
              Error 1612 -- the package cached under C:\Windows\Installer is
              gone, so Windows Installer cannot repair, upgrade OR remove the
              runtime and every bundle action dies in RemoveExistingProducts.
              Added a source-repair escalation step: extract the bundle with
              /layout and run msiexec /fvomus against the extracted MSI, which
              re-caches the package from a real source and rewrites the files.
    v1.3.0  : Remediation now ESCALATES and verifies the on-disk DLL after
              each step instead of trusting the exit code. /install is tried
              FIRST: the bundle at aka.ms (14.44) is newer than what is
              usually registered (14.42), so it performs a real upgrade and
              rewrites the files -- and unlike /repair it does not need the
              package's cached MSI, which an aggressive cleanup may have
              deleted (the likely cause of the 1603 seen on HCDL-BP0WCW3).
              /repair is now the second step, uninstall+install the third.
    v1.2.0  : /repair returned 1603 on HCDL-BP0WCW3 and left the DLL stale.
              Added: bundle+MSI logging on every install/repair with the real
              error surfaced (1603 alone says nothing); -ForceReinstall
              (uninstall then install); and -ShimAppLocal, which places a
              known-good runtime next to wfcrun32.exe so Citrix works without
              the system runtime being fixed at all.
    v1.1.0  : FALSE-PASS FIX. v1.0.0 accepted the better of the registry
              version and the on-disk DLL, so HCDL-BP0WCW3 reported "all
              prerequisites met" while SysWOW64\msvcp140.dll was still
              14.22.27821.0 -- the exact module wfcrun32.exe faults in. The
              on-disk DLL is now authoritative, and when the package is
              registered as current but its DLL is stale the script runs
              /repair (a plain /install just returns 1638 and changes
              nothing).
    Context : NT AUTHORITY\SYSTEM (WS1 Device context) or elevated admin
    PowerShell 5.1 compatible. Logs to C:\drop\citrix.
    Needs outbound HTTPS to aka.ms. Re-run CWA launch test after a reboot if
    this reports 3010/reboot-required.
#>

[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$ForceReinstall,
    [switch]$ShimAppLocal,
    [switch]$RemoveOrphanedRegistration,
    [switch]$DryRun
)

$ScriptVersion     = '1.5.0'
$DestinationFolder = 'C:\drop\citrix'
$WorkDir           = Join-Path $DestinationFolder 'prereqs'
$LogRetainDays     = 30

$MinVCRedist = [version]'14.42.34433.0'
$MinDotNet   = [version]'8.0.11'

$Prereqs = @(
    @{ Key='vcx64'; Name='Visual C++ redistributable x64'; Url='https://aka.ms/vs/17/release/vc_redist.x64.exe'; File='vc_redist.x64.exe' }
    @{ Key='vcx86'; Name='Visual C++ redistributable x86'; Url='https://aka.ms/vs/17/release/vc_redist.x86.exe'; File='vc_redist.x86.exe' }
    @{ Key='netx64'; Name='.NET Desktop Runtime 8 x64'; Url='https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe'; File='windowsdesktop-runtime-x64.exe' }
    @{ Key='netx86'; Name='.NET Desktop Runtime 8 x86'; Url='https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x86.exe'; File='windowsdesktop-runtime-x86.exe' }
)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$script:LogFile = $null

function Initialize-Logging {
    if (-not (Test-Path -LiteralPath $DestinationFolder)) {
        New-Item -Path $DestinationFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $DestinationFolder "Citrix-Prereqs-$stamp.log"
    Get-ChildItem -LiteralPath $DestinationFolder -Filter 'Citrix-Prereqs-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetainDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-Log {
    param([string]$Message = '', [ValidateSet('INFO','WARNING','ERROR')][string]$Level = 'INFO')
    $line = ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    switch ($Level) {
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'WARNING' { Write-Host $line -ForegroundColor Yellow }
        default   { Write-Host $line -ForegroundColor Gray }
    }
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-VersionOrNull {
    param([string]$Text)
    if (-not $Text) { return $null }
    $clean = ($Text -replace '^v', '').Trim()
    # Trim 4th-part padding like 14.44.35211.00 -> parses fine, but guard anyway
    $m = [regex]::Match($clean, '^\d+(\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    try { return [version]$m.Value } catch { return $null }
}

function Get-VCRedistVersion {
    param([ValidateSet('x86','x64')][string]$Arch)
    $paths = if ($Arch -eq 'x64') {
        @('HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64')
    } else {
        @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x86',
          'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x86')
    }
    foreach ($p in $paths) {
        $props = Get-ItemProperty -LiteralPath $p -ErrorAction SilentlyContinue
        if ($props -and $props.Installed -eq 1) {
            $v = ConvertTo-VersionOrNull $props.Version
            if ($v) { return $v }
        }
    }
    return $null
}

function Get-SystemRuntimeDllVersion {
    # The DLL the loader will actually bind. x86 lives in SysWOW64 on 64-bit.
    param([ValidateSet('x86','x64')][string]$Arch, [string]$Dll = 'msvcp140.dll')
    $dir = if ($Arch -eq 'x64') { Join-Path $env:SystemRoot 'System32' } else { Join-Path $env:SystemRoot 'SysWOW64' }
    $full = Join-Path $dir $Dll
    if (-not (Test-Path -LiteralPath $full)) { return $null }
    return ConvertTo-VersionOrNull (Get-Item -LiteralPath $full).VersionInfo.FileVersion
}

function Get-DotNetDesktopVersion {
    param([ValidateSet('x86','x64')][string]$Arch)
    $root = if ($Arch -eq 'x64') { Join-Path $env:ProgramFiles 'dotnet\shared\Microsoft.WindowsDesktop.App' }
            else { Join-Path ${env:ProgramFiles(x86)} 'dotnet\shared\Microsoft.WindowsDesktop.App' }
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { return $null }
    $versions = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { ConvertTo-VersionOrNull $_.Name } |
        Where-Object { $_ -and $_.Major -eq 8 } |
        Sort-Object -Descending
    if ($versions) { return $versions[0] }
    return $null
}

function Find-AppLocalRuntimeDlls {
    # App-local copies beat the system ones in the DLL search order.
    $roots = @((Join-Path ${env:ProgramFiles(x86)} 'Citrix'), (Join-Path $env:ProgramFiles 'Citrix')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $names = @('msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll','coreclr.dll')
    $hits = @()
    foreach ($root in $roots) {
        foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
                        Where-Object { $names -contains $_.Name.ToLower() })) {
            $hits += [pscustomobject]@{ Path = $f.FullName; Version = (ConvertTo-VersionOrNull $f.VersionInfo.FileVersion) }
        }
    }
    return $hits
}

function Get-PrereqState {
    $vcx64 = Get-VCRedistVersion -Arch x64
    $vcx86 = Get-VCRedistVersion -Arch x86
    [pscustomobject]@{
        vcx64  = $vcx64
        vcx86  = $vcx86
        vcx64Dll = Get-SystemRuntimeDllVersion -Arch x64
        vcx86Dll = Get-SystemRuntimeDllVersion -Arch x86
        netx64 = Get-DotNetDesktopVersion -Arch x64
        netx86 = Get-DotNetDesktopVersion -Arch x86
    }
}

function Test-PrereqMet {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Key)
    switch ($Key) {
        # v1.1.0: the ON-DISK DLL is authoritative for VC++, NOT the registry.
        # The loader binds %SystemRoot%\SysWOW64\msvcp140.dll (or System32 for
        # x64); the redist registry key only records what the package believes
        # it installed. Those disagree in the field -- HCDL-BP0WCW3 had
        # registry=14.42.34433.0 with the DLL still at 14.22.27821.0, and that
        # 14.22 is exactly the module wfcrun32.exe faulted in. Trusting the
        # registry there produced a false pass. Registry is used only as a
        # fallback when the DLL cannot be read at all.
        'vcx64' { $v = if ($State.vcx64Dll) { $State.vcx64Dll } else { $State.vcx64 }
                  return ($v -and $v -ge $MinVCRedist) }
        'vcx86' { $v = if ($State.vcx86Dll) { $State.vcx86Dll } else { $State.vcx86 }
                  return ($v -and $v -ge $MinVCRedist) }
        'netx64' { return ($State.netx64 -and $State.netx64 -ge $MinDotNet) }
        'netx86' { return ($State.netx86 -and $State.netx86 -ge $MinDotNet) }
    }
    return $false
}

function Convert-ToPackedGuid {
    # MSI stores product codes in C:\...\Installer as a "packed" GUID:
    # {A1B2C3D4-E5F6-7890-ABCD-EF1234567890} -> 4D3C2B1A6F5E0987BADCFE2143658709
    # (first three groups reversed, remaining bytes pair-swapped).
    param([Parameter(Mandatory)][string]$Guid)
    $g = $Guid -replace '[{}\-]', ''
    if ($g.Length -ne 32) { return $null }
    $rev = { param($s) ($s.ToCharArray() | ForEach-Object { $_ })[($s.Length-1)..0] -join '' }
    $swap = { param($s) -join (0..($s.Length/2 - 1) | ForEach-Object { $s.Substring($_*2,2).ToCharArray()[1,0] -join '' }) }
    return (& $rev $g.Substring(0,8)) + (& $rev $g.Substring(8,4)) + (& $rev $g.Substring(12,4)) +
           (& $swap $g.Substring(16,4)) + (& $swap $g.Substring(20,12))
}

function Remove-OrphanedMsiRegistration {
    # Last resort for System Error 1612: the product is registered but its
    # cached package is gone, so RemoveExistingProducts can never succeed and
    # every install/upgrade/repair/uninstall fails. Clearing the stale
    # registration lets a fresh install proceed with nothing to remove.
    # Everything deleted is exported to .reg first.
    param([Parameter(Mandatory)][string]$NamePattern)

    $backupDir = Join-Path $WorkDir 'regbackup'
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }

    $targets = @()
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($props.DisplayName -and $props.DisplayName -like $NamePattern -and $_.PSChildName -match '^\{[0-9A-Fa-f\-]{36}\}$') {
                $targets += [pscustomobject]@{
                    Guid = $_.PSChildName; Name = $props.DisplayName; UninstallKey = $_.PSPath
                }
            }
        }
    }
    if (-not $targets) {
        Write-Log "  No installed product matched '$NamePattern'; nothing to clear." 'WARNING'
        return $false
    }

    $removedAny = $false
    foreach ($t in $targets) {
        Write-Log "  Clearing stale registration: $($t.Name)  $($t.Guid)" 'WARNING'
        $packed = Convert-ToPackedGuid -Guid $t.Guid
        if (-not $packed) { Write-Log "    Could not pack GUID $($t.Guid); skipping." 'ERROR'; continue }

        $keys = @(
            ($t.UninstallKey -replace '^Microsoft\.PowerShell\.Core\\Registry::', 'Registry::'),
            "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\Installer\Products\$packed",
            "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\Installer\Features\$packed",
            "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$packed"
        )
        foreach ($k in $keys) {
            if (-not (Test-Path -LiteralPath $k)) { continue }
            $regPath = ($k -replace '^Registry::', '')
            $file = Join-Path $backupDir ("{0}_{1}.reg" -f $t.Guid.Trim('{}'), ([IO.Path]::GetFileName($regPath)))
            if ($DryRun) {
                Write-Log "    [DRYRUN] Would export and delete $regPath" 'WARNING'
                continue
            }
            & reg.exe export $regPath $file /y 2>&1 | Out-Null
            if (Test-Path -LiteralPath $file) { Write-Log "    Backed up -> $file" }
            else { Write-Log "    WARNING: backup of $regPath failed; not deleting it." 'ERROR'; continue }
            try {
                Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction Stop
                Write-Log "    Removed $regPath"
                $removedAny = $true
            } catch {
                Write-Log "    Could not remove ${regPath}: $($_.Exception.Message)" 'ERROR'
            }
        }
    }
    if ($removedAny) { Write-Log "  Stale registrations cleared. Backups: $backupDir (restore with reg import)." 'WARNING' }
    return $removedAny
}

function Repair-FromExtractedSource {
    # For MSI System Error 1612 / "SOURCEMGMT: Failed to resolve source":
    # the package cached under C:\Windows\Installer is gone, so Windows
    # Installer cannot repair, upgrade or remove the product -- every bundle
    # action dies in RemoveExistingProducts with 1714/1603.
    #
    # /layout extracts the real MSIs and CABs out of the bundle, giving the
    # installer a valid source again. msiexec /fvomus then RE-CACHES the
    # package from that source (that is what the 'v' does) and rewrites every
    # file, which is exactly what the stale msvcp140.dll needs.
    param([Parameter(Mandatory)][hashtable]$Item)

    $bundle = Join-Path $WorkDir $Item.File
    if (-not (Test-Path -LiteralPath $bundle)) {
        if (-not (Invoke-Download -Url $Item.Url -OutFile $bundle)) { return $false }
    }
    $layout = Join-Path $WorkDir ('layout_' + $Item.Key)
    if (Test-Path -LiteralPath $layout) { Remove-Item -LiteralPath $layout -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -Path $layout -ItemType Directory -Force | Out-Null

    Write-Log "  Extracting installer layout to $layout"
    try {
        # WorkingDirectory matters: under SYSTEM the default cwd is
        # %SystemRoot%\System32, and a bundle that mis-parses the layout path
        # will silently drop its payload there instead.
        $p = Start-Process -FilePath $bundle -ArgumentList '/layout',"`"$layout`"",'/quiet','/norestart' `
             -WorkingDirectory $layout -PassThru -Wait -ErrorAction Stop
        Write-Log "  /layout exit code: $($p.ExitCode)"
    } catch {
        Write-Log "  Could not extract layout: $($_.Exception.Message)" 'ERROR'
        return $false
    }

    # Report what actually landed -- "no MSI found" alone is not diagnosable.
    $produced = @(Get-ChildItem -LiteralPath $layout -Recurse -ErrorAction SilentlyContinue)
    Write-Log ("  Layout produced {0} item(s)." -f $produced.Count)
    foreach ($grp in ($produced | Group-Object Extension | Sort-Object Count -Descending | Select-Object -First 6)) {
        Write-Log ("    {0,-8} x{1}" -f $(if ($grp.Name) { $grp.Name } else { '<dir>' }), $grp.Count)
    }

    $msis = @($produced | Where-Object { $_.Extension -ieq '.msi' })
    if (-not $msis) {
        # Some bundles write the layout beside themselves rather than into the
        # requested directory; look there before giving up.
        $msis = @(Get-ChildItem -LiteralPath $WorkDir -Recurse -Filter '*.msi' -ErrorAction SilentlyContinue)
        if ($msis) { Write-Log ("  Found {0} MSI(s) elsewhere under {1}." -f $msis.Count, $WorkDir) 'WARNING' }
    }
    if (-not $msis) {
        Write-Log '  No MSI produced by /layout, so the package source still cannot be restored this way.' 'ERROR'
        Write-Log '  The product registration is orphaned: MSI can neither remove, repair nor upgrade it. Re-run with -RemoveOrphanedRegistration to clear the stale registration (backed up first) and install fresh.' 'ERROR'
        return $false
    }

    $any = $false
    foreach ($msi in $msis) {
        # f=repair v=re-cache from this source o=replace older/missing files
        # m/u=rewrite machine+user registration s=shortcuts
        $msiLog = Join-Path $WorkDir ("{0}_source_{1}.log" -f $Item.Key, $msi.BaseName)
        Write-Log "  msiexec /fvomus `"$($msi.Name)`"  (re-caching package from extracted source)"
        try {
            $mp = Start-Process -FilePath 'msiexec.exe' `
                  -ArgumentList '/fvomus',"`"$($msi.FullName)`"",'/quiet','/norestart','/l*v',"`"$msiLog`"" `
                  -PassThru -Wait -ErrorAction Stop
            $code = $mp.ExitCode
        } catch {
            Write-Log "  Failed to launch msiexec: $($_.Exception.Message)" 'ERROR'
            continue
        }
        switch ($code) {
            0     { Write-Log "    $($msi.Name): re-cached and repaired (exit 0)."; $any = $true }
            3010  { Write-Log "    $($msi.Name): repaired, reboot required (3010)." 'WARNING'; $any = $true }
            1605  { Write-Log "    $($msi.Name): not currently installed (1605); skipping." 'WARNING' }
            default {
                Write-Log "    $($msi.Name): msiexec returned $code." 'WARNING'
                $hits = Select-String -LiteralPath $msiLog -ErrorAction SilentlyContinue `
                        -Pattern 'Error \d+|return value 3|MainEngineThread is returning' | Select-Object -Last 4
                foreach ($h in $hits) { Write-Log ("      {0}" -f $h.Line.Trim()) 'WARNING' }
            }
        }
    }
    return $any
}

function Invoke-PrereqRemediation {
    # v1.3.0: escalate, verifying the ON-DISK DLL after each step rather than
    # trusting the installer's exit code.
    #   1. /install  -- the bundle at aka.ms is newer than what is typically
    #                   registered (14.44 vs 14.42), so this is a real UPGRADE
    #                   and rewrites the files. Cheapest, and unlike /repair it
    #                   does not depend on the package's cached MSI still being
    #                   present in C:\Windows\Installer -- which an aggressive
    #                   cleanup may have removed. Tried FIRST for that reason.
    #   2. /repair   -- for when the bundle is not newer, so /install no-ops
    #                   with 1638.
    #   3. uninstall+install (-ForceReinstall only) -- last resort.
    # Returns 'ok' | 'reboot' | 'fail'.
    param([Parameter(Mandatory)][hashtable]$Item)
    $steps = @('install','repair')
    # sourcerepair only applies to the VC++ bundles (the .NET runtime bundle
    # has no /layout-and-recache equivalent worth attempting here).
    if ($Item.Key -in @('vcx64','vcx86')) { $steps += 'sourcerepair' }
    if ($RemoveOrphanedRegistration -and $Item.Key -in @('vcx64','vcx86')) { $steps += 'deorphan' }
    if ($ForceReinstall -and $Item.Key -in @('vcx64','vcx86')) { $steps += 'forcereinstall' }
    $reboot = $false

    foreach ($step in $steps) {
        if ($step -eq 'deorphan') {
            $arch = if ($Item.Key -eq 'vcx64') { 'X64' } else { 'X86' }
            Write-Log "  Escalating: clearing the orphaned MSI registration for Microsoft Visual C++ * $arch * Runtime, then installing fresh." 'WARNING'
            if (Remove-OrphanedMsiRegistration -NamePattern "Microsoft Visual C++ * $arch *Runtime*") {
                $result = Install-Prereq -Item $Item -Action 'install'
            } else {
                $result = 'fail'
            }
        } elseif ($step -eq 'sourcerepair') {
            Write-Log '  Escalating: extracting the installer layout and re-caching the MSI from it (fixes System Error 1612 / missing C:\Windows\Installer cache).' 'WARNING'
            $result = if (Repair-FromExtractedSource -Item $Item) { 'ok' } else { 'fail' }
        } elseif ($step -eq 'forcereinstall') {
            Write-Log '  Escalating to uninstall + install. Other applications share this runtime and may fail to start until it completes.' 'WARNING'
            Install-Prereq -Item $Item -Action 'uninstall' | Out-Null
            $result = Install-Prereq -Item $Item -Action 'install'
        } else {
            $result = Install-Prereq -Item $Item -Action $step
        }
        if ($result -eq 'reboot') { $reboot = $true }

        # Verify against the file on disk -- exit 0 does not prove the DLL moved.
        $now = Get-PrereqState
        if (Test-PrereqMet -State $now -Key $Item.Key) {
            Write-Log "  $($Item.Name): resolved after /$step (on-disk DLL now meets the minimum)."
            return $(if ($reboot) { 'reboot' } else { 'ok' })
        }
        Write-Log "  /$step completed but the on-disk DLL is still below minimum." 'WARNING'
    }
    return 'fail'
}

function Write-PrereqState {
    param([Parameter(Mandatory)]$State)
    foreach ($a in @(@{k='vcx64';n='x64';dir='System32'}, @{k='vcx86';n='x86';dir='SysWOW64'})) {
        $reg = if ($a.k -eq 'vcx64') { $State.vcx64 }    else { $State.vcx86 }
        $dll = if ($a.k -eq 'vcx64') { $State.vcx64Dll } else { $State.vcx86Dll }
        $met = Test-PrereqMet $State $a.k
        Write-Log ("  VC++ {0} : {1}\msvcp140.dll={2,-16} (registry claims {3,-16}) min={4}  [{5}]" -f `
            $a.n, $a.dir, ($dll -as [string]), ($reg -as [string]), $MinVCRedist, $(if ($met) {'OK'} else {'BELOW MINIMUM'})) `
            $(if ($met) {'INFO'} else {'WARNING'})
        if ($reg -and $dll -and $reg -ne $dll) {
            Write-Log ("    MISMATCH: the registered package version and the DLL actually on disk differ. The loader binds the DLL, so {0} is what CWA gets." -f $dll) 'WARNING'
        }
    }
    Write-Log ("  .NET Desktop x64 : {0,-16} min={1}  [{2}]" -f `
        ($State.netx64 -as [string]), $MinDotNet, $(if (Test-PrereqMet $State 'netx64') {'OK'} else {'BELOW MINIMUM'}))
    Write-Log ("  .NET Desktop x86 : {0,-16} min={1}  [{2}]" -f `
        ($State.netx86 -as [string]), $MinDotNet, $(if (Test-PrereqMet $State 'netx86') {'OK'} else {'BELOW MINIMUM'}))
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
function Invoke-Download {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutFile)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Write-Log "  Downloading (attempt $attempt): $Url"
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
            $size = (Get-Item -LiteralPath $OutFile).Length
            if ($size -lt 100KB) { throw "File suspiciously small ($size bytes)." }
            Write-Log ("  Saved {0:N1} MB" -f ($size / 1MB))
            return $true
        } catch {
            Write-Log "  Download failed: $($_.Exception.Message)" 'WARNING'
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            if ($attempt -lt 3) { Start-Sleep -Seconds ([math]::Pow(2, $attempt)) }
        }
    }
    return $false
}

function Install-Prereq {
    # Both VC++ redist and the .NET runtime are Burn bundles: same switches.
    # Returns 'ok' | 'reboot' | 'fail'
    param(
        [Parameter(Mandatory)][hashtable]$Item,
        [ValidateSet('install','repair','uninstall')][string]$Action = 'install'
    )
    $target = Join-Path $WorkDir $Item.File
    if (-not (Invoke-Download -Url $Item.Url -OutFile $target)) { return 'fail' }
    # /repair rewrites files the package owns. /install would return 1638
    # ("newer version already installed") and leave the stale DLL in place.
    $verb = if ($Action -eq 'repair') { '/repair' } elseif ($Action -eq 'uninstall') { '/uninstall' } else { '/install' }
    # Always capture a bundle log; 1603 is generic and the real cause only
    # appears in the MSI log Burn writes alongside it.
    $logBase = Join-Path $WorkDir ("{0}_{1}.log" -f ($Item.Key), $Action)
    Write-Log "  Running $verb  (log: $logBase)" $(if ($Action -eq 'repair') { 'WARNING' } else { 'INFO' })
    try {
        $p = Start-Process -FilePath $target -ArgumentList $verb,'/quiet','/norestart','/log',"`"$logBase`"" -PassThru -Wait -ErrorAction Stop
        $code = $p.ExitCode
    } catch {
        Write-Log "  Failed to launch installer: $($_.Exception.Message)" 'ERROR'
        return 'fail'
    }
    switch ($code) {
        0     { Write-Log "  $($Item.Name): $Action succeeded (exit 0)."; return 'ok' }
        3010  { Write-Log "  $($Item.Name): $Action succeeded, reboot required (3010)." 'WARNING'; return 'reboot' }
        1638  { Write-Log "  $($Item.Name): package reports a newer version already present (1638)." 'WARNING'; return 'ok' }
        5100  { Write-Log "  $($Item.Name): package reports a newer version already present (5100)." 'WARNING'; return 'ok' }
        default {
            Write-Log "  $($Item.Name): installer returned $code." 'ERROR'
            Write-BundleLogErrors -LogBase $logBase
            return 'fail'
        }
    }
}

function Write-BundleLogErrors {
    # Surface the actual failure out of the Burn/MSI logs so 1603 stops being
    # an opaque number. Burn writes siblings like <base>_000_vcRuntime...log.
    param([Parameter(Mandatory)][string]$LogBase)
    $dir  = Split-Path -Path $LogBase -Parent
    $stem = [IO.Path]::GetFileNameWithoutExtension($LogBase)
    $logs = Get-ChildItem -LiteralPath $dir -Filter "$stem*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    if (-not $logs) { Write-Log '  (no bundle log was produced)' 'WARNING'; return }
    foreach ($l in $logs) {
        $hits = Select-String -LiteralPath $l.FullName -ErrorAction SilentlyContinue `
            -Pattern 'Error \d+|return value 3|MainEngineThread is returning|Failed to |cannot access|being used by another process|Product: .*-- Error' |
            Select-Object -Last 8
        if ($hits) {
            Write-Log "  --- from $($l.Name) ---" 'WARNING'
            foreach ($h in $hits) { Write-Log ("    {0}" -f ($h.Line.Trim())) 'WARNING' }
        }
    }
    Write-Log "  Full logs: $dir" 'WARNING'
}

function Invoke-AppLocalShim {
    # Put a known-good runtime next to wfcrun32.exe. Windows checks the
    # application directory before the system directories, so CWA binds this
    # copy regardless of what SysWOW64 holds. Only Citrix is affected.
    # Returns $true if the shim is in place.
    $icaDir = @((Join-Path ${env:ProgramFiles(x86)} 'Citrix\ICA Client'),
                (Join-Path $env:ProgramFiles 'Citrix\ICA Client')) |
        Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'wfcrun32.exe')) } |
        Select-Object -First 1
    if (-not $icaDir) {
        Write-Log 'Cannot shim: wfcrun32.exe not found.' 'ERROR'
        return $false
    }
    Write-Log "Shim target (folder holding wfcrun32.exe): $icaDir"

    $ok = $true
    foreach ($dll in @('msvcp140.dll','vcruntime140.dll')) {
        # Source: the newest copy Citrix already ships that meets the minimum.
        $src = Find-AppLocalRuntimeDlls |
            Where-Object { (Split-Path $_.Path -Leaf) -ieq $dll -and $_.Version -and $_.Version -ge $MinVCRedist } |
            Sort-Object Version -Descending | Select-Object -First 1
        if (-not $src) {
            Write-Log "  No source copy of $dll at >= $MinVCRedist found inside the Citrix tree." 'ERROR'
            $ok = $false; continue
        }
        $dest = Join-Path $icaDir $dll
        if (Test-Path -LiteralPath $dest) {
            $existing = ConvertTo-VersionOrNull (Get-Item -LiteralPath $dest).VersionInfo.FileVersion
            if ($existing -and $existing -ge $MinVCRedist) {
                Write-Log "  $dll already present at v$existing; leaving it."
                continue
            }
            $backup = "$dest.bak"
            if ($DryRun) { Write-Log "  [DRYRUN] Would back up $dest -> $backup" 'WARNING' }
            else { Copy-Item -LiteralPath $dest -Destination $backup -Force -ErrorAction SilentlyContinue
                   Write-Log "  Backed up existing $dll -> $backup" }
        }
        if ($DryRun) {
            Write-Log "  [DRYRUN] Would copy $($src.Path) (v$($src.Version)) -> $dest" 'WARNING'
            continue
        }
        try {
            Copy-Item -LiteralPath $src.Path -Destination $dest -Force -ErrorAction Stop
            $now = ConvertTo-VersionOrNull (Get-Item -LiteralPath $dest).VersionInfo.FileVersion
            Write-Log "  Copied $dll v$now from $($src.Path)"
        } catch {
            Write-Log "  Failed to copy ${dll}: $($_.Exception.Message)" 'ERROR'
            $ok = $false
        }
    }
    if ($ok -and -not $DryRun) {
        Write-Log 'App-local shim in place. CWA will now load the good runtime even though SysWOW64 is still stale.'
        Write-Log "To undo: delete msvcp140.dll and vcruntime140.dll from $icaDir (restore any .bak files)."
    }
    return $ok
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
    Write-Log "Citrix Workspace prerequisites  (script v$ScriptVersion)"
    Write-Log "Computer: $env:COMPUTERNAME   User: $(whoami)   IsAdmin: $(Test-IsAdmin)"
    Write-Log "CheckOnly: $($CheckOnly.IsPresent)   DryRun: $($DryRun.IsPresent)"

    if (-not (Test-IsAdmin)) {
        Write-Log 'Not running elevated. Installing runtimes requires admin/SYSTEM.' 'ERROR'
        $exit = 2; exit $exit
    }

    Write-Log '--- Current state ---'
    $state = Get-PrereqState
    Write-PrereqState -State $state

    # App-local runtime DLLs shadow the system copies.
    $appLocal = Find-AppLocalRuntimeDlls
    if ($appLocal) {
        Write-Log '--- App-local runtime DLLs inside the Citrix folders ---'
        foreach ($d in $appLocal) {
            $stale = $d.Version -and $d.Version -lt $MinVCRedist -and $d.Path -notmatch 'coreclr'
            Write-Log ("  {0}  v{1}{2}" -f $d.Path, $d.Version, $(if ($stale) { '   <-- OLDER THAN MINIMUM; shadows the system copy' } else { '' })) `
                $(if ($stale) { 'WARNING' } else { 'INFO' })
        }
        Write-Log 'App-local DLLs are reported only, never removed automatically -- some are shipped by Citrix on purpose.' 'WARNING'
    }

    # Shim first when asked: it is independent of the system runtime and gets
    # Citrix working even if every install/repair below fails.
    $shimDone = $false
    if ($ShimAppLocal -and -not $CheckOnly) {
        Write-Log '--- App-local shim (Citrix only) ---'
        $shimDone = Invoke-AppLocalShim
        if (-not $shimDone) { $exit = [math]::Max($exit, 1) }
    }

    $needed = @($Prereqs | Where-Object { -not (Test-PrereqMet -State $state -Key $_.Key) })

    if (-not $needed) {
        Write-Log 'All prerequisites meet the CWA 2507 minimums.'
        if ($appLocal | Where-Object { $_.Version -and $_.Version -lt $MinVCRedist -and $_.Path -notmatch 'coreclr' }) {
            Write-Log 'However a stale app-local DLL was found above -- if CWA still crashes, that is the next thing to look at.' 'WARNING'
            $exit = 1
        }
        exit $exit
    }

    Write-Log ("Below minimum: {0}" -f (($needed | ForEach-Object { $_.Name }) -join '; ')) 'WARNING'

    if ($CheckOnly) {
        Write-Log 'CheckOnly specified; not installing.'
        $exit = 3; exit $exit
    }
    if ($DryRun) {
        foreach ($n in $needed) { Write-Log "[DRYRUN] Would install $($n.Name) from $($n.Url)" 'WARNING' }
        Write-Log 'DRYRUN complete.'
        $exit = 0; exit $exit
    }

    if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    Write-Log '--- Installing ---'
    $rebootNeeded = $false; $failed = @()
    foreach ($item in $needed) {
        Write-Log "$($item.Name):"
        switch (Invoke-PrereqRemediation -Item $item) {
            'reboot' { $rebootNeeded = $true }
            'fail'   { $failed += $item.Name }
        }
    }

    Write-Log '--- Re-verify ---'
    $after = Get-PrereqState
    Write-PrereqState -State $after
    $still = @($Prereqs | Where-Object { -not (Test-PrereqMet -State $after -Key $_.Key) })

    if ($failed) { Write-Log ("Failed to install: {0}" -f ($failed -join '; ')) 'ERROR' }

    if ($still) {
        Write-Log ("STILL below minimum: {0}" -f (($still | ForEach-Object { $_.Name }) -join '; ')) 'ERROR'
        if ($still | Where-Object { $_.Key -in @('vcx64','vcx86') }) {
            Write-Log 'A VC++ system DLL is still stale. Something outside the redistributable is holding or replacing it (a process with the DLL loaded, a pending file-rename awaiting reboot, or a missing MSI cache entry).' 'ERROR'
            Write-Log 'Escalation order: (1) reboot and re-run; (2) re-run with -ForceReinstall; (3) re-run with -ShimAppLocal to unblock Citrix without touching the system runtime.' 'ERROR'
            if (-not $ShimAppLocal) {
                Write-Log 'TIP: -ShimAppLocal fixes Citrix immediately and independently of this failure.' 'WARNING'
            }
        }
        if ($shimDone) {
            Write-Log 'The app-local shim IS in place, so Citrix should launch despite the system runtime still being stale. Exit code stays 2 because the machine-level problem is unresolved.' 'WARNING'
        }
        $exit = 2
    } elseif ($rebootNeeded) {
        Write-Log 'All prerequisites met; a reboot is required to finalize. Test the Citrix launch after rebooting.' 'WARNING'
        $exit = 1
    } else {
        Write-Log 'All prerequisites now meet the CWA 2507 minimums. Re-test launching a published app.'
        $exit = 0
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
