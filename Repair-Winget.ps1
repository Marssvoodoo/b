<#
.SYNOPSIS
    Repair-Winget.ps1 -- make winget usable machine-wide, including under
    NT AUTHORITY\SYSTEM (WS1 Device context). Fixes exit -1073741515
    (0xC0000135 STATUS_DLL_NOT_FOUND).

.DESCRIPTION
    Root cause this script targets: winget.exe (Microsoft.DesktopAppInstaller)
    launches from C:\Program Files\WindowsApps\... but the loader cannot
    resolve its MSIX framework dependencies (Microsoft.VCLibs.140.00.UWPDesktop
    and Microsoft.UI.Xaml.2.8) because the installed dependency packages are
    missing or version-mismatched against the App Installer build that
    auto-updated onto the box. Symptom: instant exit -1073741515 before winget
    prints anything, most visible when invoked as SYSTEM.

    Flow:
      1. Initialize logging (C:\drop\citrix, 30-day rotation).
      2. Health probe: resolve winget.exe (PATH, then newest WindowsApps
         package folder) and run `winget --version` with the working
         directory set to the package folder (the SYSTEM working-dir fix).
         Healthy + not -Force -> exit 0, nothing touched.
      3. Strategy 0 -- per-user registration (free, no downloads):
         Add-AppxPackage -Register on the staged App Installer's
         AppxManifest.xml. Provisioned MSIX packages only register per-user
         at LOGON, and SYSTEM never logs on -- so on many broken boxes every
         package is already on disk and registration for the invoking
         account is the only missing piece. This is the most common cure.
      4. Strategy A -- Microsoft.WinGet.Client PowerShell module:
         install NuGet provider + module from PSGallery (AllUsers), then
         Repair-WinGetPackageManager -AllUsers -Force -Latest. This is
         Microsoft's supported repair path and handles dependency matching
         itself. Needs PSGallery reachability.
      5. Strategy B -- manual machine-wide provisioning (no PSGallery):
         download Microsoft.VCLibs.x64.14.00.Desktop.appx,
         Microsoft.UI.Xaml.2.8 (x64) and the latest
         Microsoft.DesktopAppInstaller msixbundle (aka.ms/getwinget), then
         Add-AppxProvisionedPackage -Online with the dependencies, followed
         by per-user registration (provisioning alone only registers at next
         logon; DISM also no-ops silently when a same-or-newer App Installer
         is already provisioned).
      6. Re-probe: re-resolve winget.exe (the repaired install can land in a
         NEW versioned folder), run `winget --version`, then prime sources
         with `winget source update` so the first real install doesn't stall
         on source bootstrap under SYSTEM.

    Pair with Reinstall-CitrixLTSR.ps1: run this first (or let that script's
    built-in repair fire), and winget-tier sourcing works fleet-wide.

    Exit codes (WS1):
      0 = winget healthy (already, or after repair)
      1 = repaired with warnings (winget runs; source update failed, etc.)
      2 = repair failed / winget still broken
      3 = unsupported OS (no MSIX app support, e.g. Server 2019 LTSC w/o store)

.PARAMETER Force
    Run the repair even if the health probe says winget already works.

.PARAMETER SkipModuleRepair
    Skip Strategy A (PSGallery module) and go straight to manual provisioning.
    Use on networks where PSGallery is blocked -- saves ~2 min of timeouts.

.PARAMETER TimeoutSeconds
    Per-operation timeout (downloads, winget probes). Default 600.

.PARAMETER DryRun
    Log every action without downloading, installing, or provisioning.

.NOTES
    Author  : MEB -- Oak Street Health / CVS Health IT Operations
    Version : 1.1.0
    Date    : 2026-07-14
    v1.1.0  : Added Strategy 0 (Add-AppxPackage -Register for the invoking
              account, tried before any download) and post-provisioning
              registration in Strategy B. Field finding from OSHCGHL0X54:
              DISM no-ops when a same-or-newer App Installer is already
              provisioned, and per-user registration was the actual gap.
    v1.0.0  : Initial release.
    Context : NT AUTHORITY\SYSTEM (WS1 Device context) or elevated admin
    PowerShell 5.1 compatible. Logs to C:\drop\citrix.
    Downloads require outbound HTTPS to aka.ms / *.microsoft.com / github.com
    (Strategy B) and PSGallery (Strategy A). On fully dark networks, provision
    the three packages from a share instead (see $ManualPackageDir).
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipModuleRepair,
    [int]$TimeoutSeconds = 600,
    [switch]$DryRun
)

$ScriptVersion     = '1.1.0'
$DestinationFolder = 'C:\drop\citrix'
$RepairDir         = Join-Path $DestinationFolder 'winget-repair'
$LogRetainDays     = 30
$WingetDllNotFound = -1073741515
$TimeoutSentinel   = 99001

# Optional: pre-staged packages (e.g. copied from a share) are used instead of
# downloading when all three exist here. Names must match the patterns below.
$ManualPackageDir  = Join-Path $RepairDir 'staged'

# Dependency/download matrix. UI.Xaml 2.8 is what DesktopAppInstaller 1.22+
# links against; VCLibs 14.00 Desktop is required by both.
$Downloads = @(
    @{
        Name    = 'Microsoft.VCLibs.x64.14.00.Desktop.appx'
        Urls    = @('https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx')
        Kind    = 'dependency'
    },
    @{
        Name    = 'Microsoft.UI.Xaml.2.8.x64.appx'
        Urls    = @(
            'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.7/Microsoft.UI.Xaml.2.8.x64.appx',
            'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx'
        )
        Kind    = 'dependency'
    },
    @{
        Name    = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
        Urls    = @('https://aka.ms/getwinget')
        Kind    = 'main'
    }
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
    $script:LogFile = Join-Path $DestinationFolder "Winget-Repair-$stamp.log"
    Get-ChildItem -LiteralPath $DestinationFolder -Filter 'Winget-Repair-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetainDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR')][string]$Level = 'INFO'
    )
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
# Helpers
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-WingetPath {
    # PATH first (rare under SYSTEM), then the newest x64 package folder.
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $root = Join-Path $env:ProgramFiles 'WindowsApps'
    $hit = Get-ChildItem -LiteralPath $root -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'winget.exe' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    return $hit
}

function Invoke-WingetProbe {
    # Run winget with WorkingDirectory = package folder (the SYSTEM fix).
    # Returns the exit code, $TimeoutSentinel on hang, or 2 on failure-to-start.
    param(
        [Parameter(Mandatory)][string]$WingetExe,
        [string]$Arguments = '--version',
        [int]$TimeoutSecondsLocal = 120
    )
    $dir = Split-Path -Path $WingetExe -Parent
    Write-Log "Probe: `"$WingetExe`" $Arguments  (WorkingDirectory: $dir, timeout ${TimeoutSecondsLocal}s)"
    try {
        $p = Start-Process -FilePath $WingetExe -ArgumentList $Arguments `
            -WorkingDirectory $dir -PassThru -WindowStyle Hidden -ErrorAction Stop
    } catch {
        Write-Log "Failed to start winget: $($_.Exception.Message)" 'ERROR'
        return 2
    }
    $null = $p.Handle
    if (-not $p.WaitForExit($TimeoutSecondsLocal * 1000)) {
        Write-Log "winget probe exceeded ${TimeoutSecondsLocal}s; killing (PID $($p.Id))." 'ERROR'
        & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
        return $TimeoutSentinel
    }
    $code = $p.ExitCode
    if ($null -eq $code) { $code = 0 }
    Write-Log "Probe exit code: $code"
    return $code
}

function Test-WingetHealthy {
    # $true only if winget resolves AND `--version` exits 0.
    $wg = Resolve-WingetPath
    if (-not $wg) {
        Write-Log 'winget.exe not found on this machine.' 'WARNING'
        return $false
    }
    Write-Log "Found winget: $wg"
    $code = Invoke-WingetProbe -WingetExe $wg
    if ($code -eq 0) { return $true }
    if ($code -eq $WingetDllNotFound) {
        Write-Log 'winget exits 0xC0000135 (STATUS_DLL_NOT_FOUND): MSIX dependencies missing/mismatched.' 'WARNING'
    } else {
        Write-Log "winget probe failed with $code." 'WARNING'
    }
    return $false
}

function Invoke-Download {
    # Download with retries across candidate URLs. Returns local path or $null.
    param(
        [Parameter(Mandatory)][string[]]$Urls,
        [Parameter(Mandatory)][string]$OutFile
    )
    foreach ($url in $Urls) {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Write-Log "Downloading (attempt $attempt): $url"
                Invoke-WebRequest -Uri $url -OutFile $OutFile -UseBasicParsing `
                    -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                $size = (Get-Item -LiteralPath $OutFile).Length
                if ($size -lt 100KB) { throw "Downloaded file suspiciously small ($size bytes)." }
                Write-Log ("Saved: {0} ({1:N1} MB)" -f $OutFile, ($size / 1MB))
                return $OutFile
            } catch {
                Write-Log "Download failed: $($_.Exception.Message)" 'WARNING'
                Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
                if ($attempt -lt 3) { Start-Sleep -Seconds ([math]::Pow(2, $attempt)) }
            }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Strategy 0: per-user registration of the staged App Installer package
# ---------------------------------------------------------------------------
function Invoke-PackageRegistration {
    # Provisioned MSIX packages only register per-user at LOGON; SYSTEM never
    # logs on, so register the staged App Installer (plus its staged framework
    # dependencies) for the invoking account directly. Free -- no downloads.
    Write-Log '--- Strategy 0: Add-AppxPackage -Register for the invoking account ---'
    if ($DryRun) {
        Write-Log '[DRYRUN] Would register the staged App Installer manifest for the current user.' 'WARNING'
        return $false
    }
    $wg = Resolve-WingetPath
    if (-not $wg) {
        Write-Log 'No staged App Installer found to register.' 'WARNING'
        return $false
    }
    $manifest = Join-Path (Split-Path -Path $wg -Parent) 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifest)) {
        Write-Log "AppxManifest.xml not found beside winget.exe: $manifest" 'WARNING'
        return $false
    }
    try {
        Write-Log "Registering: $manifest"
        Add-AppxPackage -Register $manifest -DisableDevelopmentMode -ForceApplicationShutdown -ErrorAction Stop
        Write-Log 'App Installer registered for current user.'
        return $true
    } catch {
        Write-Log "Add-AppxPackage -Register failed: $($_.Exception.Message)" 'WARNING'
        return $false
    }
}

# ---------------------------------------------------------------------------
# Strategy A: Microsoft.WinGet.Client module repair
# ---------------------------------------------------------------------------
function Invoke-ModuleRepair {
    Write-Log '--- Strategy A: Repair-WinGetPackageManager (Microsoft.WinGet.Client) ---'
    if ($DryRun) {
        Write-Log '[DRYRUN] Would install Microsoft.WinGet.Client and run Repair-WinGetPackageManager -AllUsers -Force -Latest.' 'WARNING'
        return $false
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
            if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
                Write-Log 'Installing NuGet package provider...'
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction Stop | Out-Null
            }
            Write-Log 'Installing Microsoft.WinGet.Client module from PSGallery (AllUsers)...'
            Install-Module -Name Microsoft.WinGet.Client -Force -Scope AllUsers `
                -Repository PSGallery -AllowClobber -ErrorAction Stop
        } else {
            Write-Log 'Microsoft.WinGet.Client module already available.'
        }

        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        Write-Log 'Running Repair-WinGetPackageManager -AllUsers -Force -Latest ...'
        Repair-WinGetPackageManager -AllUsers -Force -Latest -ErrorAction Stop
        Write-Log 'Repair-WinGetPackageManager completed.'
        return $true
    } catch {
        Write-Log "Strategy A failed: $($_.Exception.Message)" 'WARNING'
        return $false
    }
}

# ---------------------------------------------------------------------------
# Strategy B: manual machine-wide provisioning
# ---------------------------------------------------------------------------
function Invoke-ManualProvision {
    Write-Log '--- Strategy B: manual provisioning (DesktopAppInstaller + VCLibs + UI.Xaml) ---'
    if ($DryRun) {
        Write-Log '[DRYRUN] Would download 3 packages and run Add-AppxProvisionedPackage -Online.' 'WARNING'
        return $false
    }

    if (-not (Test-Path -LiteralPath $RepairDir)) {
        New-Item -Path $RepairDir -ItemType Directory -Force | Out-Null
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $dependencyPaths = @()
    $mainPath = $null

    foreach ($item in $Downloads) {
        $target = Join-Path $RepairDir $item.Name

        # Pre-staged copy (dark-network path) wins over download.
        $staged = Join-Path $ManualPackageDir $item.Name
        if (Test-Path -LiteralPath $staged) {
            Write-Log "Using pre-staged package: $staged"
            Copy-Item -LiteralPath $staged -Destination $target -Force
        } elseif (-not (Invoke-Download -Urls $item.Urls -OutFile $target)) {
            Write-Log "Could not obtain $($item.Name) from any source." 'ERROR'
            return $false
        }

        if ($item.Kind -eq 'main') { $mainPath = $target } else { $dependencyPaths += $target }
    }

    try {
        Write-Log "Provisioning machine-wide: $mainPath"
        Write-Log "Dependencies: $($dependencyPaths -join '; ')"
        # -SkipLicense is fine for App Installer (store-licensed framework app).
        Add-AppxProvisionedPackage -Online -PackagePath $mainPath `
            -DependencyPackagePath $dependencyPaths -SkipLicense -ErrorAction Stop | Out-Null
        Write-Log 'Add-AppxProvisionedPackage succeeded.'
        return $true
    } catch {
        Write-Log "Provisioning failed: $($_.Exception.Message)" 'ERROR'
        # Common cause: a same-or-higher broken version already staged. Try
        # registering the dependencies alone, which is enough to cure
        # 0xC0000135 when the App Installer binaries themselves are intact.
        try {
            Write-Log 'Fallback: provisioning dependency packages only...' 'WARNING'
            foreach ($dep in $dependencyPaths) {
                Add-AppxProvisionedPackage -Online -PackagePath $dep -SkipLicense -ErrorAction Stop | Out-Null
                Write-Log "Provisioned dependency: $dep"
            }
            return $true
        } catch {
            Write-Log "Dependency-only provisioning also failed: $($_.Exception.Message)" 'ERROR'
            return $false
        }
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
    Write-Log "Winget repair / machine enablement  (script v$ScriptVersion)"
    Write-Log "Computer: $env:COMPUTERNAME   User: $(whoami)   IsAdmin: $(Test-IsAdmin)"
    Write-Log "Force: $($Force.IsPresent)   SkipModuleRepair: $($SkipModuleRepair.IsPresent)   DryRun: $($DryRun.IsPresent)"

    if (-not (Test-IsAdmin)) {
        Write-Log 'Not running elevated. Provisioning requires admin/SYSTEM.' 'ERROR'
        $exit = 2; exit $exit
    }

    # MSIX apps need Win10 1809+ (build 17763); LTSC/Server without the Appx
    # servicing stack can't host winget at all.
    $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
    if ($build -lt 17763) {
        Write-Log "OS build $build does not support winget (needs 17763+)." 'ERROR'
        $exit = 3; exit $exit
    }

    # --- Health probe ---
    Write-Log '--- Health probe ---'
    $healthy = Test-WingetHealthy
    if ($healthy -and -not $Force) {
        Write-Log 'winget already healthy; nothing to do. (-Force to repair anyway.)'
        $exit = 0; exit $exit
    }
    if ($healthy) { Write-Log 'winget healthy but -Force specified; repairing anyway.' 'WARNING' }

    # --- Repair ---
    # Strategy 0 first: registration is free and is the common cure when the
    # packages are already staged (SYSTEM has no logon to register them at).
    $repaired = $false
    if (Invoke-PackageRegistration) {
        if (Test-WingetHealthy) {
            Write-Log 'Per-user registration alone fixed winget; no downloads needed.'
            $repaired = $true
        } else {
            Write-Log 'Registration succeeded but winget still failing; escalating.' 'WARNING'
        }
    }
    if (-not $repaired -and -not $SkipModuleRepair) {
        $repaired = Invoke-ModuleRepair
    } elseif (-not $repaired) {
        Write-Log 'Strategy A skipped (-SkipModuleRepair).'
    }
    if (-not $repaired) {
        $repaired = Invoke-ManualProvision
        if ($repaired) {
            # Provisioning registers per-user only at next logon; do it now.
            Invoke-PackageRegistration | Out-Null
        }
    }

    if ($DryRun) {
        Write-Log 'DRYRUN complete.'
        $exit = 0; exit $exit
    }
    if (-not $repaired) {
        Write-Log 'All repair strategies failed.' 'ERROR'
        $exit = 2; exit $exit
    }

    # --- Verify ---
    Write-Log '--- Post-repair verification ---'
    Start-Sleep -Seconds 5
    $wg = Resolve-WingetPath   # repaired install lands in a NEW version folder
    if (-not $wg) {
        Write-Log 'winget.exe still not found after repair.' 'ERROR'
        $exit = 2; exit $exit
    }
    $code = Invoke-WingetProbe -WingetExe $wg
    if ($code -ne 0) {
        Write-Log "winget still failing after repair (exit $code)." 'ERROR'
        $exit = 2; exit $exit
    }
    Write-Log "winget operational: $wg"

    # Prime sources so the first real install under SYSTEM doesn't stall on
    # source bootstrap. Non-fatal if it fails (offline, proxy).
    $srcCode = Invoke-WingetProbe -WingetExe $wg `
        -Arguments 'source update --disable-interactivity' -TimeoutSecondsLocal 300
    if ($srcCode -ne 0) {
        Write-Log "winget source update returned $srcCode (non-fatal; sources will bootstrap on first use)." 'WARNING'
        $exit = 1
    } else {
        Write-Log 'winget sources primed.'
    }

    Write-Log 'Machine is winget-capable.'
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
