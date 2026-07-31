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
      1 = met but a reboot is required to finalize, or app-local DLLs found
      2 = fatal (not elevated, download failed, still below minimum after
          install)
      3 = -CheckOnly and at least one prerequisite is below minimum

.PARAMETER CheckOnly
    Report only; install nothing. Use as a WS1 detection rule.

.PARAMETER DryRun
    Log what would be downloaded/installed without doing it.

.NOTES
    Author  : MEB -- Oak Street Health / CVS Health IT Operations
    Version : 1.1.0
    Date    : 2026-07-31
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
    [switch]$DryRun
)

$ScriptVersion     = '1.1.0'
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

function Get-PrereqAction {
    # 'repair'  -- package registered as current but the on-disk DLL is stale,
    #              so a plain /install no-ops with 1638 and fixes nothing.
    # 'install' -- package missing or genuinely below minimum.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Key)
    if ($Key -notin @('vcx64','vcx86')) { return 'install' }
    $reg = if ($Key -eq 'vcx64') { $State.vcx64 }    else { $State.vcx86 }
    $dll = if ($Key -eq 'vcx64') { $State.vcx64Dll } else { $State.vcx86Dll }
    if ($reg -and $reg -ge $MinVCRedist -and $dll -and $dll -lt $MinVCRedist) { return 'repair' }
    return 'install'
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
        [ValidateSet('install','repair')][string]$Action = 'install'
    )
    $target = Join-Path $WorkDir $Item.File
    if (-not (Invoke-Download -Url $Item.Url -OutFile $target)) { return 'fail' }
    # /repair rewrites files the package owns. /install would return 1638
    # ("newer version already installed") and leave the stale DLL in place.
    $verb = if ($Action -eq 'repair') { '/repair' } else { '/install' }
    Write-Log "  Running $verb (package is registered as current but its DLL on disk is stale)" `
        $(if ($Action -eq 'repair') { 'WARNING' } else { 'INFO' })
    try {
        $p = Start-Process -FilePath $target -ArgumentList $verb,'/quiet','/norestart' -PassThru -Wait -ErrorAction Stop
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
        default { Write-Log "  $($Item.Name): installer returned $code." 'ERROR'; return 'fail' }
    }
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
        $action = Get-PrereqAction -State $state -Key $item.Key
        Write-Log "$($item.Name)  [action: $action]:"
        switch (Install-Prereq -Item $item -Action $action) {
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
            Write-Log 'A VC++ system DLL is still stale after a repair. Something outside the redistributable is overwriting it (an older app that drops msvcp140.dll into SysWOW64, or a pending-rename that needs a reboot).' 'ERROR'
            Write-Log 'Next steps: reboot and re-run this script; if it persists, uninstall the VC++ 2015-2022 x86 redistributable from Programs and Features, reboot, then re-run.' 'ERROR'
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
