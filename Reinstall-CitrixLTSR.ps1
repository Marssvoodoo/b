<#
.SYNOPSIS
    Reinstall-CitrixLTSR.ps1 -- Forced reinstall of Citrix Workspace app LTSR from a
    staged offline installer. No winget dependency; deterministic under SYSTEM.

.DESCRIPTION
    Purpose: repair machines where CWA is installed but broken (e.g. .ica files no
    longer launch) by forcing the full installer to re-run, which rewrites file type
    associations, ProgIDs, protocol handlers, and component registration.

    Flow:
      1. Initialize logging (C:\drop\citrix, 30-day rotation).
      2. Locate the installer:
           a. -InstallerPath if provided and present (local path or UNC).
           b. Local payload next to this script (CitrixWorkspaceApp*.exe).
           c. UNC share (-SharePath) with TCP/445 fast-fail probe before access.
           d. winget download (stages the LTSR exe to C:\drop\citrix without
              installing; uses the SYSTEM working-directory fix). If download
              is unsupported/fails but winget runs, falls back to direct
              `winget install --force --custom /forceinstall`.
         v1.2.0: when winget dies with 0xC0000135 (STATUS_DLL_NOT_FOUND, e.g.
         DesktopAppInstaller 1.29.x under SYSTEM), the script now repairs the
         winget runtime itself -- via Repair-Winget.ps1 if packaged alongside,
         else by provisioning DesktopAppInstaller + VCLibs + UI.Xaml machine-
         wide -- then retries the winget tier once. Disable with -NoWingetRepair.
         v1.2.1: repair now starts with per-user registration of the staged
         App Installer package (Add-AppxPackage -Register), since provisioned
         MSIX packages only register at logon and SYSTEM never logs on.
         v1.2.2: registration is skipped under SYSTEM (Windows rejects it
         with 0x80073CF9); final fallback extracts the App Installer bundle
         to C:\drop\citrix\winget-portable and runs winget unpackaged.
      3. Optional SHA-256 verification (-ExpectedSha256).
      4. Kill running Citrix processes (they block silent reinstall).
      5. Run: CitrixWorkspaceApp.exe /silent /forceinstall /noreboot
         (/forceinstall = reinstall over same/any version; replaces legacy /rcu)
         With -CleanInstall: uses /CleanInstall instead -- scrubs leftover traces
         first but WIPES configured stores/accounts; users must re-add or GPO/WS1
         must re-push store config. Use only if /forceinstall does not cure it.
      6. Hard timeout with taskkill /T; MSI mutex wait before launch.
      7. Verify DisplayVersion present after install.

    Exit codes (WS1):
      0 = success (verified installed after forced reinstall)
      1 = completed with warnings
      2 = fatal (no installer, install failed, CWA absent after attempt)
      3 = installer hung / timeout exceeded

.PARAMETER InstallerPath
    Explicit path to CitrixWorkspaceApp.exe (local or UNC). Highest priority.

.PARAMETER SharePath
    UNC folder to search for CitrixWorkspaceApp*.exe if -InstallerPath not given
    and no local payload found. TCP/445 probe fast-fails if unreachable.

.PARAMETER ExpectedSha256
    Optional SHA-256 to verify the installer before executing. Recommended for
    UNC-sourced binaries. (2507.1 CU2 = 25.7.2000.2020 per Citrix downloads page;
    always take the hash from the page you downloaded from.)

.PARAMETER CleanInstall
    Use /CleanInstall instead of /forceinstall. WARNING: wipes stores/accounts.

.PARAMETER AutoUpdate
    Controls Citrix Workspace Updater policy, applied both as installer switches
    and as HKLM registry values (so it also remediates already-installed boxes).
      disabled (default) - no update checks. Correct for per-machine installs
                           where users are NOT local admins: any update prompt
                           they receive fails with "The installer detects that a
                           client already exists and it can be modified only by
                           an administrator." WS1 owns the update lifecycle.
      ltsr               - notify, but LTSR stream only. Users still need admin
                           rights to apply it (prompt will error for non-admins).
      current            - notify on Current Release. NOT recommended: this is
                           what silently pulls machines off the LTSR track.
      skip               - leave auto-update configuration untouched.

.PARAMETER NoWingetRepair
    Do not attempt to repair a broken winget runtime (0xC0000135); just fall
    through to the staging-reminder failure path as v1.1.0 did.

.PARAMETER TimeoutSeconds
    Hard timeout for the CWA installer. Default 900 (CWA installs can be slow).

.PARAMETER DryRun
    Log every action without killing processes or installing.

.NOTES
    Author  : MEB -- Oak Street Health / CVS Health IT Operations
    Version : 1.3.0
    Date    : 2026-07-30
    v1.3.0  : Added -AutoUpdate (default 'disabled'). The built-in Citrix
              Workspace Updater defaults to the Current Release stream, so an
              LTSR machine gets offered CR; on a per-machine install a non-admin
              user then hits "client already exists ... only by an
              administrator". Now sets /AutoUpdateCheck (+/AutoUpdateStream) at
              install AND writes the HKLM AutoUpdate values afterward, which
              remediates machines already deployed. Also verifies and logs the
              effective policy.
    v1.2.2  : Field fix #2 from OSHCGHL0X54: Windows hard-blocks LocalSystem
              from Appx Register (0x80073CF9), so registration is now skipped
              under SYSTEM, and a new final fallback extracts the downloaded
              App Installer msixbundle (a zip) into C:\drop\citrix\
              winget-portable and runs that winget.exe as a plain Win32
              process -- no package identity, immune to the restriction.
    v1.2.1  : Fix winget repair on boxes where App Installer is already
              provisioned (DISM no-ops): provisioned MSIX packages only
              register per-user at logon and SYSTEM never logs on, so now
              Add-AppxPackage -Register the App Installer manifest for the
              invoking account -- tried FIRST (no downloads), and again after
              provisioning.
    v1.2.0  : Self-heal winget: on 0xC0000135, repair the winget runtime
              (Repair-Winget.ps1 sidecar, else inline machine-wide provisioning
              of DesktopAppInstaller + VCLibs + UI.Xaml) and retry tier 4/5
              once. Added -NoWingetRepair.
    v1.1.0  : Added winget as installer source tier 4 (download-then-run, with
              direct install --force --custom fallback). Added -SkipWinget.
    Context : NT AUTHORITY\SYSTEM (WS1 Device context) or elevated admin
    PowerShell 5.1 compatible. Logs to C:\drop\citrix.
    NOTE: There is no Citrix evergreen URL for LTSR builds (CTX338523; the
    downloadplugins URL serves Current Release only). Stage the LTSR exe yourself.
#>

[CmdletBinding()]
param(
    [string]$InstallerPath = '',
    [string]$SharePath = '',
    [string]$ExpectedSha256 = '',
    [string]$WingetId = 'Citrix.Workspace.LTSR',
    [switch]$SkipWinget,
    [switch]$NoWingetRepair,
    [switch]$CleanInstall,
    [ValidateSet('disabled', 'ltsr', 'current', 'skip')]
    [string]$AutoUpdate = 'disabled',
    [int]$TimeoutSeconds = 900,
    [switch]$DryRun
)

$ScriptVersion    = '1.3.0'
$DestinationFolder = 'C:\drop\citrix'
$LogRetainDays    = 30
$TimeoutSentinel  = 99001

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$script:LogFile = $null

function Initialize-Logging {
    if (-not (Test-Path -LiteralPath $DestinationFolder)) {
        New-Item -Path $DestinationFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $DestinationFolder "Citrix-LTSR-Reinstall-$stamp.log"
    Get-ChildItem -LiteralPath $DestinationFolder -Filter 'Citrix-LTSR-Reinstall-*.log' -ErrorAction SilentlyContinue |
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

function Test-IsSystem {
    ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value -eq 'S-1-5-18'
}

function Get-InstalledCitrixVersion {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        } | Where-Object {
            $_.DisplayName -and
            ($_.DisplayName -like 'Citrix Workspace*' -or $_.DisplayName -like 'Citrix Receiver*') -and
            $_.Publisher -like '*Citrix*'
        } | Select-Object -First 1
        if ($hit) { return [string]$hit.DisplayVersion }
    }
    return $null
}

function Test-Tcp445 {
    # Fast-fail probe before touching a UNC path (avoids long SMB hangs).
    param([Parameter(Mandatory)][string]$UncPath)
    if ($UncPath -notmatch '^\\\\([^\\]+)\\') { return $true }   # not UNC; skip probe
    $server = $Matches[1]
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($server, 445, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne(3000, $false)
        if ($ok -and $client.Connected) { $client.Close(); return $true }
        $client.Close(); return $false
    } catch { return $false }
}

function Wait-ForMsiMutex {
    # Wait for _MSIExecute mutex to free up (another MSI in flight blocks install).
    param([int]$MaxWaitSeconds = 300)
    $deadline = (Get-Date).AddSeconds($MaxWaitSeconds)
    while ((Get-Date) -lt $deadline) {
        $msiexec = Get-Process -Name 'msiexec' -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -ne $PID }
        # Heuristic: msiexec service instance always runs; look for >1 or active CPU
        $busy = $false
        try {
            $m = [Threading.Mutex]::OpenExisting('Global\_MSIExecute')
            $busy = $true
            $m.Dispose()
        } catch [Threading.WaitHandleCannotBeOpenedException] { $busy = $false }
        catch { $busy = $false }
        if (-not $busy) { return $true }
        Write-Log 'MSI mutex held by another install; waiting 15s...' 'WARNING'
        Start-Sleep -Seconds 15
    }
    return $false
}

function Invoke-Process {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][int]$TimeoutSecondsLocal
    )
    Write-Log "Launching: `"$FilePath`" $Arguments  (timeout ${TimeoutSecondsLocal}s)"
    try {
        $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -ErrorAction Stop
    } catch {
        Write-Log "Failed to start process: $($_.Exception.Message)" 'ERROR'
        return 2
    }
    $null = $p.Handle
    if (-not $p.WaitForExit($TimeoutSecondsLocal * 1000)) {
        Write-Log "Process exceeded ${TimeoutSecondsLocal}s; killing tree (PID $($p.Id))." 'ERROR'
        $kill = & taskkill.exe /PID $p.Id /T /F 2>&1
        foreach ($l in $kill) { Write-Log "taskkill: $l" }
        return $TimeoutSentinel
    }
    $code = $p.ExitCode
    if ($null -eq $code) {
        Write-Log 'Process returned null exit code; treating as 0.' 'WARNING'
        $code = 0
    }
    Write-Log "Exit code: $code"
    return $code
}

# ---------------------------------------------------------------------------
# v1.3.0: Citrix Workspace Updater policy
# ---------------------------------------------------------------------------
# Registry home of the updater settings (REG_SZ values), per Citrix docs:
#   64-bit: HKLM\SOFTWARE\WOW6432Node\Citrix\ICA Client\AutoUpdate
#   32-bit: HKLM\SOFTWARE\Citrix\ICA Client\AutoUpdate
# Both are written; the one that does not apply to this OS is harmless.
$AutoUpdateKeys = @(
    'HKLM:\SOFTWARE\WOW6432Node\Citrix\ICA Client\AutoUpdate',
    'HKLM:\SOFTWARE\Citrix\ICA Client\AutoUpdate'
)

function Get-AutoUpdateInstallerArgs {
    # Installer switches matching -AutoUpdate. /AutoUpdateCheck is mandatory
    # before any other AutoUpdate switch is accepted.
    switch ($AutoUpdate) {
        'disabled' { return '/AutoUpdateCheck=disabled' }
        'ltsr'     { return '/AutoUpdateCheck=auto /AutoUpdateStream=LTSR' }
        'current'  { return '/AutoUpdateCheck=auto /AutoUpdateStream=Current' }
        default    { return '' }   # 'skip'
    }
}

function Set-CitrixAutoUpdatePolicy {
    # Enforce the policy in the registry as well as via installer switches.
    # This is what remediates machines that are ALREADY installed -- no
    # reinstall required for the popup to stop.
    if ($AutoUpdate -eq 'skip') {
        Write-Log 'Auto-update policy left untouched (-AutoUpdate skip).'
        return
    }
    $values = @{}
    switch ($AutoUpdate) {
        'disabled' {
            # Stream is still pinned to LTSR so that if anything re-enables
            # checking later, the machine cannot drift onto Current Release.
            $values = [ordered]@{ AutoUpdateCheck = 'Disabled'; AutoUpdateStream = 'LTSR' }
        }
        'ltsr'    { $values = [ordered]@{ AutoUpdateCheck = 'Auto'; AutoUpdateStream = 'LTSR' } }
        'current' { $values = [ordered]@{ AutoUpdateCheck = 'Auto'; AutoUpdateStream = 'Current' } }
    }

    foreach ($key in $AutoUpdateKeys) {
        try {
            if ($DryRun) {
                Write-Log "[DRYRUN] Would set $key -> $(($values.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')" 'WARNING'
                continue
            }
            if (-not (Test-Path -LiteralPath $key)) {
                New-Item -Path $key -Force -ErrorAction Stop | Out-Null
            }
            foreach ($entry in $values.GetEnumerator()) {
                New-ItemProperty -Path $key -Name $entry.Key -Value $entry.Value `
                    -PropertyType String -Force -ErrorAction Stop | Out-Null
            }
            Write-Log "Auto-update policy set: $key -> $(($values.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
        } catch {
            Write-Log "Could not write auto-update policy to ${key}: $($_.Exception.Message)" 'WARNING'
        }
    }
}

function Test-CitrixAutoUpdatePolicy {
    # Read back what the updater will actually honour, for the log.
    foreach ($key in $AutoUpdateKeys) {
        $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($props -and $props.AutoUpdateCheck) {
            Write-Log ("Effective auto-update policy: AutoUpdateCheck={0}, AutoUpdateStream={1}  ({2})" -f `
                $props.AutoUpdateCheck, $props.AutoUpdateStream, $key)
            return $props.AutoUpdateCheck
        }
    }
    Write-Log 'No AutoUpdate policy found in registry; Citrix Workspace Updater will use its defaults (Current Release stream).' 'WARNING'
    return $null
}

function Stop-CitrixProcesses {
    $names = @(
        'Receiver','SelfServicePlugin','SelfService','AuthManSvr','concentr',
        'wfcrun32','wfica32','ssonsvr','CDViewer','redirector','HdxBrowser',
        'HdxTeams','HdxRtcEngine','WebHelper','CitrixWorkspaceApp','CtxCFRUI',
        'CitrixReceiverUpdater','CWAUpdaterService','TrolleyExpress','CWAInstaller'
    )
    foreach ($n in $names) {
        $procs = Get-Process -Name $n -ErrorAction SilentlyContinue
        if ($procs) {
            if ($DryRun) {
                Write-Log "[DRYRUN] Would kill: $n (PID $($procs.Id -join ','))" 'WARNING'
            } else {
                $procs | Stop-Process -Force -ErrorAction SilentlyContinue
                Write-Log "Killed process: $n"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# v1.1.0: winget staging (source tier 4)
# ---------------------------------------------------------------------------
$WingetDllNotFound = -1073741515
$script:WingetDir  = $null

function Resolve-WingetPath {
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

function Invoke-WingetProcess {
    # Launch winget with the SYSTEM working-directory fix; returns exit code.
    param(
        [Parameter(Mandatory)][string]$WingetExe,
        [Parameter(Mandatory)][string]$Arguments,
        [int]$TimeoutSecondsLocal = 600
    )
    Write-Log "Launching: `"$WingetExe`" $Arguments  (timeout ${TimeoutSecondsLocal}s)"
    try {
        $startParams = @{
            FilePath     = $WingetExe
            ArgumentList = $Arguments
            PassThru     = $true
            ErrorAction  = 'Stop'
        }
        if ($script:WingetDir -and (Test-Path -LiteralPath $script:WingetDir)) {
            $startParams['WorkingDirectory'] = $script:WingetDir
            Write-Log "WorkingDirectory: $($script:WingetDir)"
        }
        $p = Start-Process @startParams
    } catch {
        Write-Log "Failed to start winget: $($_.Exception.Message)" 'ERROR'
        return 2
    }
    $null = $p.Handle
    if (-not $p.WaitForExit($TimeoutSecondsLocal * 1000)) {
        Write-Log "winget exceeded ${TimeoutSecondsLocal}s; killing tree (PID $($p.Id))." 'ERROR'
        & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
        return $TimeoutSentinel
    }
    $code = $p.ExitCode
    if ($null -eq $code) { $code = 0 }
    Write-Log "Exit code: $code"
    return $code
}

# ---------------------------------------------------------------------------
# v1.2.0: winget runtime self-heal (fixes 0xC0000135 under SYSTEM)
# ---------------------------------------------------------------------------
$script:WingetRepairAttempted = $false
$script:WingetExeOverride     = $null   # set when a portable extraction succeeds

function Get-WingetExe {
    # Portable copy (from a successful repair) wins over the packaged install.
    if ($script:WingetExeOverride -and (Test-Path -LiteralPath $script:WingetExeOverride)) {
        return $script:WingetExeOverride
    }
    return Resolve-WingetPath
}

function Test-WingetOperational {
    # Re-resolve (repairs can land in a new version folder or the portable
    # directory) and probe.
    $wg = Get-WingetExe
    if (-not $wg) { return $false }
    $script:WingetDir = Split-Path -Path $wg -Parent
    return ((Invoke-WingetProcess -WingetExe $wg -Arguments '--version' -TimeoutSecondsLocal 120) -eq 0)
}

function Register-WingetForCurrentUser {
    # v1.2.1: provisioned MSIX packages only register per-user at LOGON, and
    # SYSTEM never logs on -- so on many 0xC0000135 boxes every package is
    # already on disk and per-user registration is the only missing piece.
    # Registering the App Installer manifest for the invoking account also
    # pulls in its staged framework dependencies (VCLibs/UI.Xaml).
    if (Test-IsSystem) {
        # v1.2.2: Windows rejects Appx Register for LocalSystem outright
        # (0x80073CF9, "Local System account is not allowed"). Don't burn 5s
        # on a guaranteed failure; the portable fallback covers SYSTEM.
        Write-Log 'Skipping per-user Appx registration: Windows blocks LocalSystem from Register (0x80073CF9).'
        return $false
    }
    $wg = Resolve-WingetPath
    if (-not $wg) { return $false }
    $manifest = Join-Path (Split-Path -Path $wg -Parent) 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifest)) {
        Write-Log "AppxManifest.xml not found beside winget.exe: $manifest" 'WARNING'
        return $false
    }
    try {
        Write-Log "Registering App Installer for current user: $manifest"
        Add-AppxPackage -Register $manifest -DisableDevelopmentMode -ForceApplicationShutdown -ErrorAction Stop
        Write-Log 'App Installer registered for current user.'
        return $true
    } catch {
        Write-Log "Add-AppxPackage -Register failed: $($_.Exception.Message)" 'WARNING'
        return $false
    }
}

function Repair-WingetRuntime {
    # Makes the machine winget-capable when winget dies with 0xC0000135
    # (missing/mismatched MSIX dependencies: VCLibs / UI.Xaml). Returns $true
    # if a repair ran successfully; one attempt per script run.
    if ($NoWingetRepair) {
        Write-Log 'winget repair disabled (-NoWingetRepair).' 'WARNING'
        return $false
    }
    if ($script:WingetRepairAttempted) {
        Write-Log 'winget repair already attempted this run; not retrying.' 'WARNING'
        return $false
    }
    $script:WingetRepairAttempted = $true
    if ($DryRun) {
        Write-Log '[DRYRUN] Would repair the winget runtime (provision DesktopAppInstaller + VCLibs + UI.Xaml).' 'WARNING'
        return $false
    }

    # Prefer the full standalone repair script when packaged alongside
    # (adds Repair-WinGetPackageManager strategy, pre-staged package support).
    $scriptDir = Split-Path -Parent $PSCommandPath
    if ($scriptDir) {
        $standalone = Join-Path $scriptDir 'Repair-Winget.ps1'
        if (Test-Path -LiteralPath $standalone) {
            Write-Log "Repairing winget via sidecar: $standalone"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $standalone -SkipModuleRepair
            $rc = $LASTEXITCODE
            Write-Log "Repair-Winget.ps1 exit code: $rc"
            if ($rc -gt 1) { return $false }   # 0 = healthy, 1 = healthy with warnings
            # The sidecar may have fixed the packaged install OR produced a
            # portable copy; pick up whichever actually works.
            if (Test-WingetOperational) { return $true }
            $portable = Join-Path $DestinationFolder 'winget-portable\winget.exe'
            if (Test-Path -LiteralPath $portable) {
                $script:WingetExeOverride = $portable
                if (Test-WingetOperational) { return $true }
                $script:WingetExeOverride = $null
            }
            return $false
        }
    }

    # Inline step 1 (free, no downloads): per-user registration of the
    # already-staged App Installer. On boxes where a current App Installer is
    # already provisioned machine-wide (DISM would no-op), this alone cures
    # 0xC0000135 under SYSTEM.
    if (Register-WingetForCurrentUser) {
        if (Test-WingetOperational) {
            Write-Log 'winget operational after per-user registration (no downloads needed).'
            return $true
        }
        Write-Log 'Registration succeeded but winget still failing; provisioning packages.' 'WARNING'
    }

    # Inline step 2: machine-wide provisioning of App Installer + matched
    # dependencies, for boxes where the packages genuinely are not staged.
    Write-Log 'Repairing winget inline: provisioning DesktopAppInstaller + dependencies machine-wide.'
    $repairDir = Join-Path $DestinationFolder 'winget-repair'
    if (-not (Test-Path -LiteralPath $repairDir)) {
        New-Item -Path $repairDir -ItemType Directory -Force | Out-Null
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $packages = @(
        @{ Name = 'Microsoft.VCLibs.x64.14.00.Desktop.appx'
           Urls = @('https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'); Kind = 'dep' },
        @{ Name = 'Microsoft.UI.Xaml.2.8.x64.appx'
           Urls = @('https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.7/Microsoft.UI.Xaml.2.8.x64.appx',
                    'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx'); Kind = 'dep' },
        @{ Name = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
           Urls = @('https://aka.ms/getwinget'); Kind = 'main' }
    )
    $deps = @(); $main = $null
    foreach ($pkg in $packages) {
        $target = Join-Path $repairDir $pkg.Name
        $got = $false
        foreach ($url in $pkg.Urls) {
            try {
                Write-Log "Downloading: $url"
                Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
                if ((Get-Item -LiteralPath $target).Length -lt 100KB) { throw 'Downloaded file suspiciously small.' }
                $got = $true; break
            } catch {
                Write-Log "Download failed: $($_.Exception.Message)" 'WARNING'
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $got) {
            Write-Log "Could not obtain $($pkg.Name); winget repair aborted (no outbound HTTPS?)." 'ERROR'
            return $false
        }
        if ($pkg.Kind -eq 'main') { $main = $target } else { $deps += $target }
    }

    # Best-effort provisioning: even when it can't help this run (DISM no-ops
    # on a same-or-newer staged version), it registers winget for interactive
    # users at their next logon. Never fatal -- the portable fallback below
    # doesn't need it.
    try {
        Write-Log "Provisioning machine-wide: $main (deps: $($deps -join '; '))"
        Add-AppxProvisionedPackage -Online -PackagePath $main -DependencyPackagePath $deps -SkipLicense -ErrorAction Stop | Out-Null
        Write-Log 'winget runtime provisioned.'
    } catch {
        Write-Log "Provisioning failed: $($_.Exception.Message)" 'WARNING'
        try {
            Write-Log 'Fallback: provisioning dependency packages only...' 'WARNING'
            foreach ($dep in $deps) {
                Add-AppxProvisionedPackage -Online -PackagePath $dep -SkipLicense -ErrorAction Stop | Out-Null
            }
        } catch {
            Write-Log "Dependency-only provisioning also failed: $($_.Exception.Message)" 'WARNING'
        }
    }

    # Provisioning alone registers per-user only at next logon; register now
    # for the invoking account (no-op under SYSTEM), then probe.
    Start-Sleep -Seconds 5
    Register-WingetForCurrentUser | Out-Null
    if (Test-WingetOperational) {
        Write-Log "winget operational after repair: $($script:WingetDir)"
        return $true
    }

    # v1.2.2 final fallback: run winget unpackaged. The msixbundle is a zip;
    # extracting winget.exe plus the framework DLLs into a plain folder gives
    # a normal Win32 process with no package identity -- which sidesteps both
    # 0xC0000135 (DLL resolution) and 0x80073CF9 (LocalSystem Appx block).
    Write-Log 'Packaged winget still failing; extracting a portable copy (no Appx deployment involved).'
    $portableExe = New-PortableWinget -BundlePath $main -DependencyPaths $deps
    if ($portableExe) {
        $script:WingetExeOverride = $portableExe
        if (Test-WingetOperational) {
            Write-Log "Portable winget operational: $portableExe"
            return $true
        }
        $script:WingetExeOverride = $null
    }
    Write-Log 'winget still failing after all repair strategies.' 'ERROR'
    return $false
}

function New-PortableWinget {
    # Extract the App Installer msixbundle (zip) -> x64 msix (zip) -> flat
    # folder, then drop the VCLibs/UI.Xaml DLLs beside winget.exe so the
    # plain Win32 loader finds them. Returns the portable exe path or $null.
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string[]]$DependencyPaths
    )
    $portableDir = Join-Path $DestinationFolder 'winget-portable'
    $workDir     = Join-Path $DestinationFolder 'winget-portable-tmp'
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        foreach ($d in @($portableDir, $workDir)) {
            if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -Path $d -ItemType Directory -Force | Out-Null
        }

        # Pull the x64 application msix out of the bundle.
        $zip = [System.IO.Compression.ZipFile]::OpenRead($BundlePath)
        try {
            $entry = $zip.Entries | Where-Object { $_.Name -match '(?i)x64.*\.msix$' } | Select-Object -First 1
            if (-not $entry) {
                Write-Log 'No x64 msix found inside the App Installer bundle.' 'ERROR'
                return $null
            }
            Write-Log "Extracting from bundle: $($entry.Name)"
            $msixPath = Join-Path $workDir $entry.Name
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $msixPath, $true)
        } finally { $zip.Dispose() }

        [System.IO.Compression.ZipFile]::ExtractToDirectory($msixPath, $portableDir)

        # Framework DLLs (msvcp140_app, vcruntime140_app, Microsoft.UI.Xaml)
        # go beside the exe.
        foreach ($dep in $DependencyPaths) {
            $depDir = Join-Path $workDir ([IO.Path]::GetFileNameWithoutExtension($dep))
            [System.IO.Compression.ZipFile]::ExtractToDirectory($dep, $depDir)
            Get-ChildItem -LiteralPath $depDir -Filter '*.dll' -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $portableDir -Force }
        }

        $exe = Join-Path $portableDir 'winget.exe'
        if (-not (Test-Path -LiteralPath $exe)) {
            Write-Log 'winget.exe missing after extraction.' 'ERROR'
            return $null
        }
        Write-Log "Portable winget staged: $exe"
        return $exe
    } catch {
        Write-Log "Portable extraction failed: $($_.Exception.Message)" 'ERROR'
        return $null
    } finally {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-InstallerViaWinget {
    # Stage the LTSR installer using `winget download`. Returns exe path or $null.
    $wg = Get-WingetExe
    if (-not $wg) {
        Write-Log 'winget.exe not found; attempting to provision it.' 'WARNING'
        if (-not (Repair-WingetRuntime)) { return $null }
        $wg = Get-WingetExe
        if (-not $wg) { return $null }
    }
    $script:WingetDir = Split-Path -Path $wg -Parent
    Write-Log "Using winget for staging: $wg"

    $dlDir = Join-Path $DestinationFolder 'winget-dl'
    if (-not (Test-Path -LiteralPath $dlDir)) {
        New-Item -Path $dlDir -ItemType Directory -Force | Out-Null
    }
    # Clear stale downloads so we pick up exactly what this run fetched.
    Get-ChildItem -LiteralPath $dlDir -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    if ($DryRun) {
        Write-Log "[DRYRUN] Would run: winget download --exact --id $WingetId -d $dlDir" 'WARNING'
        return $null
    }

    $dlArgs = "download --exact --id $WingetId --download-directory `"$dlDir`" --accept-package-agreements --accept-source-agreements --disable-interactivity"
    $code = Invoke-WingetProcess -WingetExe $wg -Arguments $dlArgs -TimeoutSecondsLocal 600

    if ($code -eq $WingetDllNotFound) {
        Write-Log 'winget download failed with 0xC0000135 (DLL not found under SYSTEM); attempting runtime repair.' 'WARNING'
        if (Repair-WingetRuntime) {
            $wg = Get-WingetExe
            if ($wg) {
                $script:WingetDir = Split-Path -Path $wg -Parent
                $code = Invoke-WingetProcess -WingetExe $wg -Arguments $dlArgs -TimeoutSecondsLocal 600
            }
        }
        if ($code -eq $WingetDllNotFound) {
            Write-Log 'winget still broken after repair. This box needs -InstallerPath/-SharePath/payload staging.' 'WARNING'
            return $null
        }
    }
    if ($code -eq $TimeoutSentinel) {
        Write-Log 'winget download timed out.' 'WARNING'
        return $null
    }
    if ($code -ne 0) {
        Write-Log "winget download returned $code (older winget builds lack the download command)." 'WARNING'
        return $null
    }

    # winget download nests output in a subfolder; search recursively.
    $exe = Get-ChildItem -LiteralPath $dlDir -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending | Select-Object -First 1
    if ($exe) {
        Write-Log "Installer (winget download): $($exe.FullName)"
        return $exe.FullName
    }
    Write-Log 'winget download exited 0 but no exe found in download directory.' 'WARNING'
    return $null
}

function Invoke-WingetForceReinstall {
    # Last resort: direct winget install with --force, appending /forceinstall
    # to the installer via --custom so the FTA re-registration pass runs.
    # Returns $true if winget reports success.
    $wg = Get-WingetExe
    if (-not $wg) { return $false }
    $script:WingetDir = Split-Path -Path $wg -Parent
    Write-Log 'Attempting direct winget forced reinstall (install --force --custom "/forceinstall").'

    if ($DryRun) {
        Write-Log '[DRYRUN] Would run winget install --force with --custom "/forceinstall".' 'WARNING'
        return $false
    }

    $inArgs = "install --exact --id $WingetId --silent --force --custom `"/forceinstall`" --accept-package-agreements --accept-source-agreements --disable-interactivity"
    $code = Invoke-WingetProcess -WingetExe $wg -Arguments $inArgs -TimeoutSecondsLocal $TimeoutSeconds

    if ($code -eq $WingetDllNotFound) {
        Write-Log 'winget install failed with 0xC0000135; attempting runtime repair.' 'WARNING'
        if (Repair-WingetRuntime) {
            $wg = Get-WingetExe
            if ($wg) {
                $script:WingetDir = Split-Path -Path $wg -Parent
                $code = Invoke-WingetProcess -WingetExe $wg -Arguments $inArgs -TimeoutSecondsLocal $TimeoutSeconds
            }
        }
    }

    if ($code -eq 0) { Write-Log 'winget forced reinstall reported success.'; return $true }
    if ($code -eq $WingetDllNotFound) {
        Write-Log 'winget install still failing with 0xC0000135; winget is unusable on this box.' 'WARNING'
    } else {
        Write-Log "winget forced reinstall returned $code." 'WARNING'
    }
    return $false
}

function Resolve-Installer {
    # Priority 1: explicit -InstallerPath
    if ($InstallerPath) {
        if ($InstallerPath -like '\\*') {
            if (-not (Test-Tcp445 -UncPath $InstallerPath)) {
                Write-Log "TCP/445 probe failed for $InstallerPath; share unreachable." 'ERROR'
                return $null
            }
        }
        if (Test-Path -LiteralPath $InstallerPath) {
            Write-Log "Installer (explicit): $InstallerPath"
            return $InstallerPath
        }
        Write-Log "-InstallerPath specified but not found: $InstallerPath" 'ERROR'
        return $null
    }

    # Priority 2: payload staged next to this script (WS1 package layout)
    $scriptDir = Split-Path -Parent $MyInvocation.PSCommandPath
    if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
    if ($scriptDir) {
        $local = Get-ChildItem -LiteralPath $scriptDir -Filter 'CitrixWorkspaceApp*.exe' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($local) {
            Write-Log "Installer (local payload): $($local.FullName)"
            return $local.FullName
        }
    }

    # Priority 3: UNC share search
    if ($SharePath) {
        if (-not (Test-Tcp445 -UncPath $SharePath)) {
            Write-Log "TCP/445 probe failed for $SharePath; share unreachable." 'ERROR'
            return $null
        }
        $remote = Get-ChildItem -LiteralPath $SharePath -Filter 'CitrixWorkspaceApp*.exe' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($remote) {
            # Copy locally first -- never execute installers straight off SMB.
            $localCopy = Join-Path $DestinationFolder $remote.Name
            Write-Log "Copying $($remote.FullName) -> $localCopy"
            if (-not $DryRun) {
                Copy-Item -LiteralPath $remote.FullName -Destination $localCopy -Force -ErrorAction Stop
            }
            return $localCopy
        }
        Write-Log "No CitrixWorkspaceApp*.exe found in $SharePath" 'ERROR'
    }

    # Priority 4 (v1.1.0): stage via winget download
    if (-not $SkipWinget) {
        Write-Log 'No staged installer found; attempting winget download (tier 4).'
        $viaWinget = Get-InstallerViaWinget
        if ($viaWinget) { return $viaWinget }
    } else {
        Write-Log 'winget staging skipped (-SkipWinget).' 'WARNING'
    }

    return $null
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
    Write-Log "Citrix Workspace LTSR forced reinstall  (script v$ScriptVersion)"
    Write-Log "Computer: $env:COMPUTERNAME   User: $(whoami)   IsAdmin: $(Test-IsAdmin)"
    Write-Log "Mode: $(if ($CleanInstall) { '/CleanInstall (wipes stores!)' } else { '/forceinstall' })   DryRun: $($DryRun.IsPresent)"
    Write-Log "AutoUpdate policy: $AutoUpdate"

    if (-not (Test-IsAdmin)) {
        Write-Log 'Not running elevated. Install requires admin/SYSTEM.' 'ERROR'
        $exit = 2; exit $exit
    }

    $before = Get-InstalledCitrixVersion
    if ($before) { Write-Log "Installed version before reinstall: $before" }
    else { Write-Log 'No existing Citrix Workspace detected; this will be a fresh install.' 'WARNING' }

    # Locate installer
    $installer = Resolve-Installer
    $usedWingetDirect = $false
    if (-not $installer) {
        # v1.1.0 last resort: direct winget forced reinstall (v1.2.0: now
        # self-heals a 0xC0000135 winget before giving up; appends
        # /forceinstall via --custom so the FTA re-registration pass runs).
        if (-not $SkipWinget -and -not $CleanInstall -and (Invoke-WingetForceReinstall)) {
            $usedWingetDirect = $true
        } else {
            Write-Log 'No installer available. Provide -InstallerPath, stage a payload beside the script, or pass -SharePath.' 'ERROR'
            Write-Log 'Reminder: no Citrix evergreen URL exists for LTSR (CTX338523); download 2507.1 CU2 from citrix.com and stage it.' 'ERROR'
            $exit = 2; exit $exit
        }
    }

    if (-not $usedWingetDirect) {
        # Optional hash verification
        if ($ExpectedSha256) {
            $actual = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
            if ($actual -ne $ExpectedSha256.ToUpper().Trim()) {
                Write-Log "SHA-256 MISMATCH. Expected: $ExpectedSha256  Actual: $actual" 'ERROR'
                $exit = 2; exit $exit
            }
            Write-Log "SHA-256 verified: $actual"
        } else {
            Write-Log 'No -ExpectedSha256 provided; skipping hash verification.' 'WARNING'
        }

        # Unblock MOTW if copied from share
        if (-not $DryRun) { Unblock-File -LiteralPath $installer -ErrorAction SilentlyContinue }

        # Kill blocking processes
        Stop-CitrixProcesses

        # Wait for MSI mutex
        if (-not $DryRun) {
            if (-not (Wait-ForMsiMutex -MaxWaitSeconds 300)) {
                Write-Log 'MSI mutex still held after 300s; proceeding anyway (installer will queue or fail cleanly).' 'WARNING'
                $exit = 1
            }
        }

        # Build args and install
        $switch = if ($CleanInstall) { '/CleanInstall' } else { '/forceinstall' }
        $cwaArgs = "/silent $switch /noreboot"
        $auArgs = Get-AutoUpdateInstallerArgs
        if ($auArgs) { $cwaArgs = "$cwaArgs $auArgs" }

        if ($DryRun) {
            Write-Log "[DRYRUN] Would run: `"$installer`" $cwaArgs"
            Write-Log 'DRYRUN complete.'
            $exit = 0; exit $exit
        }

        $code = Invoke-Process -FilePath $installer -Arguments $cwaArgs -TimeoutSecondsLocal $TimeoutSeconds

        if ($code -eq $TimeoutSentinel) {
            Write-Log 'CWA installer timed out and was terminated.' 'ERROR'
            $exit = 3; exit $exit
        }
        # CWA installer: 0 = ok, 3010 = ok reboot required, 1603 = fatal msi error
        switch ($code) {
            0     { Write-Log 'CWA installer reported success (exit 0).' }
            3010  { Write-Log 'CWA installer success; reboot required to finalize (3010).' 'WARNING'; $exit = [math]::Max($exit,1) }
            1603  { Write-Log 'CWA installer fatal error 1603. Check %TEMP%\CTXWorkspaceInstallLogs / C:\Program Files (x86)\Citrix\Logs.' 'ERROR'; $exit = 2 }
            default {
                Write-Log "CWA installer returned $code; verifying anyway." 'WARNING'
                $exit = [math]::Max($exit,1)
            }
        }
    } else {
        Write-Log 'Install performed via direct winget forced reinstall; proceeding to verification.'
    }

    # Verify
    if ($exit -ne 2) {
        Start-Sleep -Seconds 10
        $after = Get-InstalledCitrixVersion
        if ($after) {
            Write-Log "Verified Citrix Workspace present after reinstall: $after"
            if ($before -and $after -eq $before) {
                Write-Log 'Same version re-registered in place (expected for /forceinstall repair).'
            }
            # Quick .ica association sanity check
            $icaDefault = (Get-ItemProperty 'Registry::HKCR\.ica' -ErrorAction SilentlyContinue).'(default)'
            $handler = $null
            if ($icaDefault) {
                $handler = (Get-ItemProperty "Registry::HKCR\$icaDefault\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
            }
            if ($handler -and $handler -match 'wfcrun32|CDViewer') {
                Write-Log ".ica association verified: $icaDefault -> $handler"
            } else {
                Write-Log ".ica association still looks wrong (ProgID: '$icaDefault', handler: '$handler'). Machine may need the association repair script." 'WARNING'
                $exit = [math]::Max($exit,1)
            }

            # v1.3.0: pin the updater policy. Installer switches only apply to
            # the install we just ran, so write the registry too -- that is what
            # fixes machines deployed by earlier script versions.
            Set-CitrixAutoUpdatePolicy
            Test-CitrixAutoUpdatePolicy | Out-Null
        } else {
            Write-Log 'Citrix Workspace NOT detected after reinstall attempt.' 'ERROR'
            $exit = 2
        }
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
