<#
.SYNOPSIS
    Get-CitrixLaunchDiagnostics.ps1 -- READ-ONLY collection of everything that
    decides whether a published app actually launches. Changes nothing.

.DESCRIPTION
    Written for the case where Citrix Workspace app "does nothing" -- the Start
    menu entry opens nothing and clicking a published app in the browser opens
    nothing, with or without a prior admin credential prompt.

    That symptom has several independent causes and they are not distinguishable
    from the outside, so this collects all of them at once:

      1. Machine-wide CWA registration (version, install location).
      2. PER-USER CWA registrations under each loaded HKU hive. A per-user
         install that has been displaced by an admin install ("an administrator
         version is being installed and the user version is being uninstalled")
         commonly leaves a half-removed profile behind.
      3. Key binaries and their versions (wfcrun32, SelfService, CDViewer...).
      4. .ica association at MACHINE level (HKLM\SOFTWARE\Classes).
      5. .ica association at PER-USER level (HKU\<SID>\SOFTWARE\Classes) --
         this OUTRANKS the machine association. A stale per-user entry pointing
         into a removed per-user install path (…\AppData\Local\Citrix\…) makes
         a launch do exactly nothing, silently.
      6. UserChoice overrides for .ica.
      7. receiver:// protocol handler registration (machine and per-user) --
         this is what the browser uses; it can be broken independently of the
         file association.
      8. Per-profile Citrix state folders under AppData.
      9. Configured stores/accounts (machine and per-user).
     10. Running Citrix processes.
     11. Recent MsiInstaller + Application events mentioning Citrix, which is
         where self-repair and install/uninstall activity shows up.

    Output goes to the console and to C:\drop\citrix\Citrix-Diagnostics-*.log.
    Send that log back for analysis.

    Exit codes: 0 = collected (always, unless it could not write a log).

.PARAMETER EventHours
    How far back to search the event log. Default 24.

.NOTES
    Author  : MEB -- Oak Street Health / CVS Health IT Operations
    Version : 1.0.0
    Date    : 2026-07-31
    Context : NT AUTHORITY\SYSTEM (WS1 Device context) or elevated admin
    PowerShell 5.1 compatible. READ-ONLY -- makes no changes.
    NOTE: per-user hives are only visible while that user is signed in. Run
    this WHILE the affected user is logged on for the per-user sections to be
    populated; otherwise only their on-disk profile is inspected.
#>

[CmdletBinding()]
param(
    [int]$EventHours = 24
)

$ScriptVersion     = '1.0.0'
$DestinationFolder = 'C:\drop\citrix'
$LogRetainDays     = 30

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$script:LogFile = $null

function Initialize-Logging {
    if (-not (Test-Path -LiteralPath $DestinationFolder)) {
        New-Item -Path $DestinationFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $DestinationFolder "Citrix-Diagnostics-$stamp.log"
    Get-ChildItem -LiteralPath $DestinationFolder -Filter 'Citrix-Diagnostics-*.log' -ErrorAction SilentlyContinue |
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

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Log ''
    Write-Log ('--- {0} {1}' -f $Title, ('-' * [math]::Max(0, 60 - $Title.Length)))
}

function Get-DefaultValue {
    param([Parameter(Mandatory)][string]$Path)
    (Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue).'(default)'
}

function Get-LoadedUserHives {
    # SID -> profile path, for hives currently loaded under HKEY_USERS.
    $result = @()
    $profiles = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue
    foreach ($hive in (Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        $sid = Split-Path $hive.Name -Leaf
        if ($sid -match '_Classes$') { continue }
        if ($sid -notmatch '^S-1-5-21-') { continue }   # skip service/system SIDs
        $p = $profiles | Where-Object { (Split-Path $_.Name -Leaf) -eq $sid } | Select-Object -First 1
        $path = if ($p) { (Get-ItemProperty $p.PSPath -ErrorAction SilentlyContinue).ProfileImagePath } else { $null }
        $result += [pscustomobject]@{ Sid = $sid; ProfilePath = $path }
    }
    return $result
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try { Initialize-Logging }
catch {
    Write-Host "FATAL: cannot create log directory '$DestinationFolder': $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

try {
    Write-Log ('=' * 70)
    Write-Log "Citrix launch diagnostics (READ-ONLY)  (script v$ScriptVersion)"
    Write-Log "Computer: $env:COMPUTERNAME   User: $(whoami)"
    Write-Log "OS: $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').ProductName) build $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber)"

    $hives = Get-LoadedUserHives
    Write-Log "Loaded user hives: $(if ($hives) { ($hives | ForEach-Object { $_.Sid }) -join ', ' } else { 'none (no interactive user signed in)' })"
    if (-not $hives) {
        Write-Log 'Per-user sections will be EMPTY. Re-run while the affected user is signed in for a complete picture.' 'WARNING'
    }

    # --- 1. Machine-wide install ---
    Write-Section 'Machine-wide Citrix registration'
    $found = $false
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -and $p.DisplayName -match 'Citrix') {
                $found = $true
                Write-Log ("  {0} | {1} | InstallLocation='{2}' | Key={3}" -f `
                    $p.DisplayName, $p.DisplayVersion, $p.InstallLocation, (Split-Path $_.PSPath -Leaf))
            }
        }
    }
    if (-not $found) { Write-Log '  NONE -- no machine-wide Citrix product registered.' 'WARNING' }

    # --- 2. Per-user installs ---
    Write-Section 'PER-USER Citrix registrations (HKU)'
    $anyPerUser = $false
    foreach ($h in $hives) {
        $root = "Registry::HKEY_USERS\$($h.Sid)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -and $p.DisplayName -match 'Citrix') {
                $anyPerUser = $true
                Write-Log ("  [{0}] {1} | {2} | InstallLocation='{3}'" -f $h.Sid, $p.DisplayName, $p.DisplayVersion, $p.InstallLocation) 'WARNING'
            }
        }
    }
    if (-not $anyPerUser) { Write-Log '  None found (expected after the user version is uninstalled).' }

    # --- 3. Binaries ---
    Write-Section 'Citrix binaries'
    $icaDirs = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Citrix\ICA Client'),
        (Join-Path $env:ProgramFiles 'Citrix\ICA Client')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    if (-not $icaDirs) { Write-Log '  No Citrix\ICA Client directory found!' 'ERROR' }
    foreach ($dir in $icaDirs) {
        Write-Log "  Directory: $dir"
        foreach ($exe in @('wfcrun32.exe','wfica32.exe','SelfService.exe','SelfServicePlugin.exe','CDViewer.exe','Receiver.exe','concentr.exe','AuthManSvr.exe','WebHelper.exe')) {
            $full = Join-Path $dir $exe
            if (Test-Path -LiteralPath $full) {
                $v = (Get-Item -LiteralPath $full).VersionInfo.FileVersion
                Write-Log ("    {0,-24} present  v{1}" -f $exe, $v)
            } else {
                Write-Log ("    {0,-24} MISSING" -f $exe) 'WARNING'
            }
        }
    }

    # --- 4/5. .ica association, machine then per-user ---
    Write-Section '.ica association -- MACHINE (HKLM\SOFTWARE\Classes)'
    $mProg = Get-DefaultValue -Path 'HKLM:\SOFTWARE\Classes\.ica'
    if ($mProg) {
        $mCmd = Get-DefaultValue -Path "HKLM:\SOFTWARE\Classes\$mProg\shell\open\command"
        Write-Log "  .ica -> '$mProg'"
        Write-Log "  command = $mCmd"
        if ($mCmd -and $mCmd -match '([A-Za-z]:\\[^""]+\.exe)') {
            $exePath = $Matches[1]
            if (Test-Path -LiteralPath $exePath) { Write-Log "  handler exists: $exePath" }
            else { Write-Log "  HANDLER MISSING ON DISK: $exePath" 'ERROR' }
        }
    } else { Write-Log '  No machine-level .ica association.' 'ERROR' }

    Write-Section '.ica association -- PER-USER (HKU\<SID>\SOFTWARE\Classes)  [OUTRANKS MACHINE]'
    $anyUserAssoc = $false
    foreach ($h in $hives) {
        $key = "Registry::HKEY_USERS\$($h.Sid)\SOFTWARE\Classes\.ica"
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $anyUserAssoc = $true
        $uProg = Get-DefaultValue -Path $key
        Write-Log "  [$($h.Sid)] .ica -> '$uProg'" 'WARNING'
        if ($uProg) {
            $uCmd = Get-DefaultValue -Path "Registry::HKEY_USERS\$($h.Sid)\SOFTWARE\Classes\$uProg\shell\open\command"
            Write-Log "  [$($h.Sid)] command = $uCmd" 'WARNING'
            if ($uCmd -and $uCmd -match '([A-Za-z]:\\[^""]+\.exe)') {
                $uExe = $Matches[1]
                if (Test-Path -LiteralPath $uExe) { Write-Log "  [$($h.Sid)] handler exists: $uExe" }
                else { Write-Log "  [$($h.Sid)] STALE PER-USER HANDLER, FILE MISSING: $uExe  <-- launches will silently do nothing" 'ERROR' }
            }
        }
    }
    if (-not $anyUserAssoc) { Write-Log '  None (good -- machine association applies).' }

    # --- 6. UserChoice ---
    Write-Section '.ica UserChoice overrides'
    $anyUC = $false
    foreach ($h in $hives) {
        $uc = "Registry::HKEY_USERS\$($h.Sid)\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.ica\UserChoice"
        if (Test-Path -LiteralPath $uc) {
            $anyUC = $true
            Write-Log ("  [{0}] ProgId = {1}" -f $h.Sid, (Get-ItemProperty -LiteralPath $uc -ErrorAction SilentlyContinue).ProgId) 'WARNING'
        }
    }
    if (-not $anyUC) { Write-Log '  None.' }

    # --- 7. receiver:// protocol handler ---
    Write-Section 'receiver:// protocol handler (used by the browser)'
    foreach ($scheme in @('receiver','citrixworkspace')) {
        $mp = "HKLM:\SOFTWARE\Classes\$scheme"
        if (Test-Path $mp) {
            Write-Log ("  MACHINE {0}:// -> {1}" -f $scheme, (Get-DefaultValue -Path "$mp\shell\open\command"))
        } else {
            Write-Log ("  MACHINE {0}:// NOT registered" -f $scheme) 'WARNING'
        }
        foreach ($h in $hives) {
            $up = "Registry::HKEY_USERS\$($h.Sid)\SOFTWARE\Classes\$scheme"
            if (Test-Path -LiteralPath $up) {
                Write-Log ("  [{0}] {1}:// -> {2}" -f $h.Sid, $scheme, (Get-DefaultValue -Path "$up\shell\open\command")) 'WARNING'
            }
        }
    }

    # --- 8. Per-profile Citrix state ---
    Write-Section 'Per-profile Citrix state folders'
    $profileRoots = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue |
        ForEach-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath } |
        Where-Object { $_ -and $_ -like '*\Users\*' -and (Test-Path -LiteralPath $_) }
    foreach ($prof in $profileRoots) {
        foreach ($sub in @('AppData\Local\Citrix','AppData\Roaming\Citrix','AppData\Roaming\ICAClient','AppData\LocalLow\Citrix')) {
            $full = Join-Path $prof $sub
            if (Test-Path -LiteralPath $full) {
                $count = (Get-ChildItem -LiteralPath $full -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
                Write-Log ("  {0}  ({1} files)" -f $full, $count)
            }
        }
    }

    # --- 9. Configured stores ---
    Write-Section 'Configured stores / accounts'
    foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Citrix\Dazzle\Sites','HKLM:\SOFTWARE\Citrix\Dazzle\Sites',
                     'HKLM:\SOFTWARE\WOW6432Node\Citrix\Receiver\SR\Store','HKLM:\SOFTWARE\Citrix\Receiver\SR\Store')) {
        if (Test-Path $k) { Write-Log "  MACHINE $k :"; Get-ChildItem $k -ErrorAction SilentlyContinue | ForEach-Object { Write-Log "    $($_.PSChildName)" } }
    }
    foreach ($h in $hives) {
        foreach ($sub in @('SOFTWARE\Citrix\Dazzle\Sites','SOFTWARE\Citrix\Receiver\SR\Store')) {
            $k = "Registry::HKEY_USERS\$($h.Sid)\$sub"
            if (Test-Path -LiteralPath $k) {
                Write-Log "  [$($h.Sid)] $sub :"
                Get-ChildItem -LiteralPath $k -ErrorAction SilentlyContinue | ForEach-Object { Write-Log "    $($_.PSChildName)" }
            }
        }
    }

    # --- 10. Processes ---
    Write-Section 'Running Citrix processes'
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match 'Receiver|SelfService|AuthManSvr|concentr|wfcrun32|wfica32|CDViewer|redirector|HdxBrowser|WebHelper|CWA'
    }
    if ($procs) { $procs | ForEach-Object { Write-Log ("  {0} (PID {1})" -f $_.Name, $_.Id) } }
    else { Write-Log '  None running.' }

    # --- 11. Events ---
    Write-Section "Event log: MsiInstaller / Citrix (last $EventHours h)"
    $since = (Get-Date).AddHours(-$EventHours)
    $events = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $since } -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match 'MsiInstaller|Citrix' -or $_.Message -match 'Citrix|ICA Client|Online Plug-in' } |
        Select-Object -First 40
    if ($events) {
        foreach ($e in $events) {
            $msg = ($e.Message -replace '\s+', ' ')
            if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + '...' }
            Write-Log ("  {0:yyyy-MM-dd HH:mm:ss} [{1}] Id={2} {3}" -f $e.TimeCreated, $e.ProviderName, $e.Id, $msg)
        }
    } else {
        Write-Log '  No matching events.'
    }

    Write-Log ''
    Write-Log "Diagnostics written to: $($script:LogFile)"
}
catch {
    Write-Log "Unhandled exception: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
}
finally {
    Write-Log ('=' * 70)
}

exit 0
