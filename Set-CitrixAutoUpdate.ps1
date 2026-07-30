<#
.SYNOPSIS
    Set-CitrixAutoUpdate.ps1 -- stop the Citrix Workspace Updater from prompting
    non-admin users, and keep LTSR machines off the Current Release track.
    Fixes: "Cannot install Citrix Workspace. The installer detects that a client
    already exists and it can be modified only by an administrator."

.DESCRIPTION
    Why that popup happens: CWA installed per-machine (admin/SYSTEM install, as
    WS1 does) can only be modified by an administrator. The built-in Citrix
    Workspace Updater runs in the LOGGED-IN USER's context, and if that user is
    not a local admin the update it tries to apply fails with the error above.

    Why it fires even on a current LTSR build: the updater's default stream is
    Current Release. An LTSR machine (25.7.x) therefore sees CR (26.3.x) as
    "an update available" and offers it -- which would also silently move the
    endpoint off the LTSR track if an admin ever accepted it.

    This script writes the updater policy to HKLM so no reinstall is needed.
    Run it once fleet-wide to clear existing machines; Reinstall-CitrixLTSR.ps1
    v1.3.0+ applies the same policy on every install.

    Registry (REG_SZ values), per Citrix documentation:
      64-bit: HKLM\SOFTWARE\WOW6432Node\Citrix\ICA Client\AutoUpdate
      32-bit: HKLM\SOFTWARE\Citrix\ICA Client\AutoUpdate

    Exit codes (WS1):
      0 = policy applied and verified
      1 = applied with warnings (one hive unwritable, verification mismatch)
      2 = fatal (not elevated, nothing written)

.PARAMETER Mode
    disabled (default) - AutoUpdateCheck=Disabled. No update checks, no prompts.
                         Correct when WS1 owns the CWA update lifecycle and
                         users are not local admins.
    ltsr               - AutoUpdateCheck=Auto, stream LTSR. Users are notified
                         about LTSR CUs only. NOTE: non-admin users will still
                         hit the "only by an administrator" error when they try
                         to apply one -- use 'disabled' unless your users are
                         local admins.
    current            - AutoUpdateCheck=Auto, stream Current. Not recommended
                         on an LTSR fleet; this is the setting that pulls
                         machines off LTSR.

.PARAMETER DeferUpdateCount
    Optional. -1 = defer indefinitely, 0 = no defer option, 1-30 = max defers.
    Only meaningful with -Mode ltsr/current.

.PARAMETER DryRun
    Log what would be written without changing the registry.

.NOTES
    Author  : MEB -- Oak Street Health / CVS Health IT Operations
    Version : 1.0.0
    Date    : 2026-07-30
    Context : NT AUTHORITY\SYSTEM (WS1 Device context) or elevated admin
    PowerShell 5.1 compatible. Logs to C:\drop\citrix.
    Takes effect on the next updater check; no reboot or reinstall required.
    Running users may need to sign out/in (or have the updater restarted) for
    an already-queued prompt to stop appearing.
#>

[CmdletBinding()]
param(
    [ValidateSet('disabled', 'ltsr', 'current')]
    [string]$Mode = 'disabled',
    [ValidateRange(-1, 30)]
    [int]$DeferUpdateCount = [int]::MinValue,
    [switch]$DryRun
)

$ScriptVersion     = '1.0.0'
$DestinationFolder = 'C:\drop\citrix'
$LogRetainDays     = 30

$AutoUpdateKeys = @(
    'HKLM:\SOFTWARE\WOW6432Node\Citrix\ICA Client\AutoUpdate',
    'HKLM:\SOFTWARE\Citrix\ICA Client\AutoUpdate'
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
    $script:LogFile = Join-Path $DestinationFolder "Citrix-AutoUpdate-$stamp.log"
    Get-ChildItem -LiteralPath $DestinationFolder -Filter 'Citrix-AutoUpdate-*.log' -ErrorAction SilentlyContinue |
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

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
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
    Write-Log "Citrix Workspace Updater policy  (script v$ScriptVersion)"
    Write-Log "Computer: $env:COMPUTERNAME   User: $(whoami)   IsAdmin: $(Test-IsAdmin)"
    Write-Log "Mode: $Mode   DryRun: $($DryRun.IsPresent)"

    if (-not (Test-IsAdmin)) {
        Write-Log 'Not running elevated. Writing HKLM policy requires admin/SYSTEM.' 'ERROR'
        $exit = 2; exit $exit
    }

    $installed = Get-InstalledCitrixVersion
    if ($installed) { Write-Log "Citrix Workspace installed: $installed" }
    else { Write-Log 'Citrix Workspace not detected; policy will still be written for future installs.' 'WARNING' }

    # Build the value set. With 'disabled' the stream is still pinned to LTSR so
    # that re-enabling checks later cannot drift the machine onto Current.
    $values = [ordered]@{}
    switch ($Mode) {
        'disabled' { $values['AutoUpdateCheck'] = 'Disabled'; $values['AutoUpdateStream'] = 'LTSR' }
        'ltsr'     { $values['AutoUpdateCheck'] = 'Auto';     $values['AutoUpdateStream'] = 'LTSR' }
        'current'  { $values['AutoUpdateCheck'] = 'Auto';     $values['AutoUpdateStream'] = 'Current' }
    }
    if ($DeferUpdateCount -ne [int]::MinValue) {
        $values['DeferUpdateCount'] = [string]$DeferUpdateCount
    }
    Write-Log ("Applying: {0}" -f (($values.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))

    $written = 0
    foreach ($key in $AutoUpdateKeys) {
        try {
            if ($DryRun) {
                Write-Log "[DRYRUN] Would write $key" 'WARNING'
                $written++
                continue
            }
            if (-not (Test-Path -LiteralPath $key)) {
                New-Item -Path $key -Force -ErrorAction Stop | Out-Null
                Write-Log "Created key: $key"
            }
            foreach ($entry in $values.GetEnumerator()) {
                New-ItemProperty -Path $key -Name $entry.Key -Value $entry.Value `
                    -PropertyType String -Force -ErrorAction Stop | Out-Null
            }
            Write-Log "Wrote policy: $key"
            $written++
        } catch {
            Write-Log "Could not write ${key}: $($_.Exception.Message)" 'WARNING'
            $exit = [math]::Max($exit, 1)
        }
    }

    if ($written -eq 0) {
        Write-Log 'No registry hive could be written.' 'ERROR'
        $exit = 2; exit $exit
    }

    if ($DryRun) {
        Write-Log 'DRYRUN complete.'
        $exit = 0; exit $exit
    }

    # Verify read-back
    $verified = $false
    foreach ($key in $AutoUpdateKeys) {
        $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($props -and $props.AutoUpdateCheck -eq $values['AutoUpdateCheck']) {
            Write-Log ("Verified: AutoUpdateCheck={0}, AutoUpdateStream={1}  ({2})" -f `
                $props.AutoUpdateCheck, $props.AutoUpdateStream, $key)
            $verified = $true
        }
    }
    if (-not $verified) {
        Write-Log 'Policy did not read back as expected.' 'ERROR'
        $exit = 2; exit $exit
    }

    if ($Mode -eq 'disabled') {
        Write-Log 'Update prompts are now off. Users with the prompt already on screen may need to sign out/in for it to clear.'
    } else {
        Write-Log 'Update checks remain enabled; non-admin users will still be unable to APPLY an update on a per-machine install.' 'WARNING'
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
