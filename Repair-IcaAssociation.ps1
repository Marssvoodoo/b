<#
.SYNOPSIS
    Repair-IcaAssociation.ps1 -- stop Windows Installer self-repair firing when a
    user launches a published app, which on a per-machine CWA install shows up as
    a prompt for ADMINISTRATOR CREDENTIALS before the .ica will open.

.DESCRIPTION
    Symptom: user signs in to Storefront/Workspace fine, clicks an app, and gets
    a UAC credential prompt asking for an administrator (and/or "Please wait
    while Windows configures Online Plug-in" then "Fatal error during
    installation"). The .ica never opens for a non-admin user.

    Root cause (Citrix CTX267718): the .ica file association is bound to an
    MSI-ADVERTISED component. When Windows Installer resolves that component it
    runs a resiliency/self-repair check; because CWA is installed per-machine, a
    non-admin user cannot complete it, so Windows asks for admin credentials.
    Event Viewer > Application shows an MsiInstaller entry like:
        Detection of product '{...}', feature 'WEB_CLIENT'
        failed during request for component '{...}'

    IMPORTANT: Citrix documents that the association is corrupt "despite
    appearing intact within the Windows registry". A registry check of
    HKCR\.ica -> ProgID -> shell\open\command (what Reinstall-CitrixLTSR.ps1
    verifies) therefore PASSES on an affected machine. A green .ica check does
    not rule this out.

    Fix (per CTX267718): republish the handler under a NEW ProgID that points
    straight at wfcrun32.exe. The new ProgID is not an advertised MSI entry
    point, so Windows Installer stops being invoked on launch and the prompt
    goes away. Reinstalling does NOT fix it -- a reinstall recreates the same
    advertised association.

    Flow:
      1. Initialize logging (C:\drop\citrix, 30-day rotation).
      2. Locate wfcrun32.exe (both Program Files roots).
      3. Read the current .ica ProgID; derive a stable target ProgID
         (<base>.NEW -- idempotent, never chains .NEW.NEW).
      4. Back up the current association to the log before changing it.
      5. Create the new ProgID under HKLM\SOFTWARE\Classes and point .ica at it.
      6. Remove per-user UserChoice overrides for .ica (they outrank the machine
         default, so the fix would not reach affected users otherwise). Skip
         with -KeepUserChoice.
      7. Verify by reading the association back.

    Exit codes (WS1):
      0 = association repaired and verified
      1 = repaired with warnings (e.g. a user hive could not be cleaned)
      2 = fatal (not elevated, wfcrun32.exe missing, verification failed)

.PARAMETER KeepUserChoice
    Leave per-user HKCU\...\FileExts\.ica\UserChoice entries alone. Only use if
    you know no user has an explicit override; otherwise the machine-level fix
    may not take effect for the user who is actually affected.

.PARAMETER DryRun
    Log every action without changing the registry.

.NOTES
    Author  : MEB -- Oak Street Health / CVS Health IT Operations
    Version : 1.0.0
    Date    : 2026-07-31
    Context : NT AUTHORITY\SYSTEM (WS1 Device context) or elevated admin
    PowerShell 5.1 compatible. Logs to C:\drop\citrix.
    Reference: Citrix CTX267718.
    Affected users should sign out and back in; Explorer caches associations.
#>

[CmdletBinding()]
param(
    [switch]$KeepUserChoice,
    [switch]$DryRun
)

$ScriptVersion     = '1.0.0'
$DestinationFolder = 'C:\drop\citrix'
$LogRetainDays     = 30
$ClassesRoot       = 'HKLM:\SOFTWARE\Classes'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$script:LogFile = $null

function Initialize-Logging {
    if (-not (Test-Path -LiteralPath $DestinationFolder)) {
        New-Item -Path $DestinationFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $DestinationFolder "Citrix-IcaAssoc-$stamp.log"
    Get-ChildItem -LiteralPath $DestinationFolder -Filter 'Citrix-IcaAssoc-*.log' -ErrorAction SilentlyContinue |
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

function Get-DefaultValue {
    param([Parameter(Mandatory)][string]$Path)
    (Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue).'(default)'
}

function Find-Wfcrun32 {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Citrix\ICA Client\wfcrun32.exe'),
        (Join-Path $env:ProgramFiles 'Citrix\ICA Client\wfcrun32.exe')
    ) | Where-Object { $_ }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Get-TargetProgId {
    # Idempotent: strip any trailing .NEW so repeat runs do not chain suffixes.
    param([string]$Current)
    if (-not $Current) { return 'Citrix.ICAClient.NEW' }
    $base = $Current
    while ($base -match '\.NEW$') { $base = $base -replace '\.NEW$', '' }
    return "$base.NEW"
}

function Clear-IcaUserChoice {
    # Per-user UserChoice outranks the machine default. Removing it makes the
    # user fall back to the repaired machine-level association.
    $cleared = 0; $failed = 0
    $hives = Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '_Classes$' }
    foreach ($hive in $hives) {
        $uc = "$($hive.Name)\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.ica\UserChoice"
        if (-not (Test-Path -LiteralPath "Registry::$uc")) { continue }
        $progId = (Get-ItemProperty -LiteralPath "Registry::$uc" -ErrorAction SilentlyContinue).ProgId
        if ($DryRun) {
            Write-Log "[DRYRUN] Would remove UserChoice (ProgId='$progId'): $uc" 'WARNING'
            $cleared++
            continue
        }
        try {
            Remove-Item -LiteralPath "Registry::$uc" -Force -Recurse -ErrorAction Stop
            Write-Log "Removed UserChoice override (was ProgId='$progId'): $uc"
            $cleared++
        } catch {
            Write-Log "Could not remove UserChoice at ${uc}: $($_.Exception.Message)" 'WARNING'
            $failed++
        }
    }
    if ($cleared -eq 0 -and $failed -eq 0) { Write-Log 'No per-user .ica UserChoice overrides found.' }
    return $failed
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
    Write-Log "Citrix .ica association repair  (script v$ScriptVersion)"
    Write-Log "Computer: $env:COMPUTERNAME   User: $(whoami)   IsAdmin: $(Test-IsAdmin)"
    Write-Log "KeepUserChoice: $($KeepUserChoice.IsPresent)   DryRun: $($DryRun.IsPresent)"

    if (-not (Test-IsAdmin)) {
        Write-Log 'Not running elevated. Writing HKLM\SOFTWARE\Classes requires admin/SYSTEM.' 'ERROR'
        $exit = 2; exit $exit
    }

    # 1. Locate the handler
    $wfcrun32 = Find-Wfcrun32
    if (-not $wfcrun32) {
        Write-Log 'wfcrun32.exe not found. Citrix Workspace app does not appear to be installed; run Reinstall-CitrixLTSR.ps1 first.' 'ERROR'
        $exit = 2; exit $exit
    }
    Write-Log "Handler: $wfcrun32"

    # 2. Record the current state before touching anything
    $currentProgId = Get-DefaultValue -Path 'Registry::HKEY_CLASSES_ROOT\.ica'
    if ($currentProgId) {
        $currentCmd = Get-DefaultValue -Path "Registry::HKEY_CLASSES_ROOT\$currentProgId\shell\open\command"
        Write-Log "Current association: .ica -> '$currentProgId' -> '$currentCmd'"
        Write-Log 'NOTE: this can look correct and still trigger MSI self-repair -- the ProgID is an advertised MSI entry point (CTX267718).'
    } else {
        Write-Log '.ica has no machine-level association.' 'WARNING'
    }

    $targetProgId = Get-TargetProgId -Current $currentProgId
    $command      = '"{0}" "%1"' -f $wfcrun32
    Write-Log "Target association: .ica -> '$targetProgId' -> '$command'"

    if ($currentProgId -eq $targetProgId) {
        Write-Log 'Association already points at the repaired ProgID; refreshing it in place.'
    }

    # 3. Publish the new ProgID and repoint .ica
    if ($DryRun) {
        Write-Log "[DRYRUN] Would create $ClassesRoot\$targetProgId\shell\open\command = $command" 'WARNING'
        Write-Log "[DRYRUN] Would set $ClassesRoot\.ica default = $targetProgId" 'WARNING'
        Clear-IcaUserChoice | Out-Null
        Write-Log 'DRYRUN complete.'
        $exit = 0; exit $exit
    }

    try {
        $cmdKey = "$ClassesRoot\$targetProgId\shell\open\command"
        New-Item -Path $cmdKey -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -LiteralPath $cmdKey -Name '(default)' -Value $command -ErrorAction Stop
        Set-ItemProperty -LiteralPath "$ClassesRoot\$targetProgId" -Name '(default)' `
            -Value 'Citrix ICA Client' -ErrorAction SilentlyContinue
        Write-Log "Created ProgID: $cmdKey"

        New-Item -Path "$ClassesRoot\.ica" -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -LiteralPath "$ClassesRoot\.ica" -Name '(default)' -Value $targetProgId -ErrorAction Stop
        # Content type helps browsers hand the file to the right app.
        Set-ItemProperty -LiteralPath "$ClassesRoot\.ica" -Name 'Content Type' `
            -Value 'application/x-ica' -ErrorAction SilentlyContinue
        Write-Log "Repointed .ica -> $targetProgId"
    } catch {
        Write-Log "Failed to write the association: $($_.Exception.Message)" 'ERROR'
        $exit = 2; exit $exit
    }

    # 4. Per-user overrides
    if ($KeepUserChoice) {
        Write-Log 'Per-user UserChoice overrides left in place (-KeepUserChoice). If the affected user has one, they will NOT pick up this fix.' 'WARNING'
    } else {
        if ((Clear-IcaUserChoice) -gt 0) { $exit = [math]::Max($exit, 1) }
    }

    # 5. Verify
    $verifyProgId = Get-DefaultValue -Path 'Registry::HKEY_CLASSES_ROOT\.ica'
    $verifyCmd    = Get-DefaultValue -Path "Registry::HKEY_CLASSES_ROOT\$verifyProgId\shell\open\command"
    if ($verifyProgId -eq $targetProgId -and $verifyCmd -eq $command) {
        Write-Log "Verified: .ica -> $verifyProgId -> $verifyCmd"
        Write-Log 'Affected users must sign out and back in before Explorer picks this up.'
    } else {
        Write-Log "Verification failed. .ica -> '$verifyProgId' -> '$verifyCmd'" 'ERROR'
        $exit = 2
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
