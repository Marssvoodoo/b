<#
.SYNOPSIS
    Detect-CitrixWorkspace.ps1 -- Workspace ONE / Intune custom detection script
    for Citrix Workspace app. Detects ANY build in the approved LTSR family, so
    a cumulative update does not make a managed install look uninstalled.

.DESCRIPTION
    Problem this solves: WS1 kept showing "Install" in the Hub catalogue on
    machines that already had Citrix Workspace -- including HCDL-B14YRW3, which
    had exactly the deployed build (25.7.1000.1025). An app WS1 cannot detect is
    an app WS1 cannot manage: it never reports as installed, it re-offers, and
    it will not service the machine.

    Two things commonly break CWA detection:

      1. CWA is installed by a BOOTSTRAPPER, not a single MSI. Auto-generated
         detection criteria often key off a ProductCode that is never
         registered, or off one of the component MSIs whose GUID changes
         between cumulative updates. Either way detection fails.
      2. WS1 requires exit code 0 *AND* non-empty STDOUT to consider an app
         detected. A script that exits 0 but prints nothing reads as NOT
         detected -- a silent, very easy mistake.

    This script keys off the stable uninstall entry Citrix writes for the suite
    (typically CitrixOnlinePluginPackWeb) rather than a component GUID, checks
    both registry views regardless of whether WS1 invoked 32- or 64-bit
    PowerShell, and compares by MINIMUM version so CU2/CU3/CU4 all satisfy a
    package built on CU1.

    WS1 UEM setup:
      Detection Criteria -> Add -> Criteria Type: Custom Script
      Script Type: PowerShell,  Success Exit Code: 0
      Paste this file's contents.

    Behaviour:
      installed    -> writes a description line to STDOUT and exits 0
      not installed-> writes nothing to STDOUT and exits 1

.PARAMETER MinimumVersion
    Lowest acceptable build. Default '25.7' matches the whole 2507 LTSR family,
    so any cumulative update counts as installed. Set a fuller version such as
    '25.7.2000' to require a specific CU or newer.

.PARAMETER ExactVersion
    Require this exact DisplayVersion instead of a minimum. Use only when a
    package must be pinned; it makes every future CU look uninstalled.

.PARAMETER RequireLtsr
    Reject Current Release builds even if they are newer. With the default
    MinimumVersion of 25.7, CR 26.3.x would otherwise satisfy the check and
    a drifted endpoint would report as compliant.

.PARAMETER LogPath
    Optional file to append a detection result to. Off by default -- detection
    scripts run often and should stay silent and fast.

.NOTES
    Author  : MEB -- Oak Street Health / CVS Health IT Operations
    Version : 1.0.0
    Date    : 2026-08-20
    Runs as SYSTEM under the WS1 agent. PowerShell 5.1 compatible.
    Read-only: inspects the registry and nothing else.
#>

[CmdletBinding()]
param(
    [string]$MinimumVersion = '25.7',
    [string]$ExactVersion = '',
    [switch]$RequireLtsr,
    [string]$LogPath = ''
)

function Write-DetectLog {
    param([string]$Message)
    if (-not $LogPath) { return }
    try {
        $dir = Split-Path -Path $LogPath -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        Add-Content -LiteralPath $LogPath -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME, $Message) -ErrorAction SilentlyContinue
    } catch { }
}

function Write-DetectionOutput {
    # WS1 treats an app as detected only when the script exits 0 AND writes
    # something to STDOUT -- exit 0 with no output reads as NOT detected.
    # Emit on BOTH the success stream and the host: which one a management
    # agent captures varies, and a detection script that cannot be observed
    # while it runs is not the place to bet on one of them.
    param([Parameter(Mandatory)][string]$Message)
    Write-Output $Message
    Write-Host   $Message
}

function ConvertTo-VersionOrNull {
    param([string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text.Trim(), '^\d+(\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    # [version] needs at least major.minor
    $v = $m.Value
    if ($v -notmatch '\.') { $v = "$v.0" }
    try { return [version]$v } catch { return $null }
}

function Get-CitrixWorkspaceInstall {
    # Read BOTH registry views explicitly. WS1 may launch this in 32-bit
    # PowerShell, where HKLM:\SOFTWARE\...\Uninstall is silently redirected to
    # WOW6432Node -- so a path-based lookup can miss a 64-bit registration (and
    # vice versa). OpenBaseKey with an explicit view avoids the redirection.
    $results = @()
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $base = $null
        try { $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view) }
        catch { continue }
        try {
            $uninstall = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $uninstall) { continue }
            foreach ($name in $uninstall.GetSubKeyNames()) {
                $sub = $null
                try { $sub = $uninstall.OpenSubKey($name) } catch { continue }
                if (-not $sub) { continue }
                try {
                    $display   = [string]$sub.GetValue('DisplayName')
                    $publisher = [string]$sub.GetValue('Publisher')
                    $version   = [string]$sub.GetValue('DisplayVersion')
                    # Match the SUITE entry, not the component MSIs (Web Helper,
                    # Authentication Manager, SSON, ...) whose GUIDs churn.
                    $isSuite = ($display -like 'Citrix Workspace*' -or $display -like 'Citrix Receiver*') -and
                               $display -notmatch '\((USB|DV|SSON)\)' -and
                               $display -notmatch 'Inside|Web Helper|Authentication Manager|Desktop Lock|Browser Content|Secure Access|Self-service'
                    if ($isSuite -and $version -and ($publisher -like '*Citrix*' -or $name -eq 'CitrixOnlinePluginPackWeb')) {
                        $results += [pscustomobject]@{
                            Key = $name; DisplayName = $display; Version = $version
                            Parsed = (ConvertTo-VersionOrNull $version); View = $view
                        }
                    }
                } finally { $sub.Close() }
            }
            $uninstall.Close()
        } finally { $base.Close() }
    }
    return $results
}

# ---------------------------------------------------------------------------
# Evaluate
# ---------------------------------------------------------------------------
try {
    $found = @(Get-CitrixWorkspaceInstall)

    if (-not $found) {
        Write-DetectLog 'NOT DETECTED: no Citrix Workspace suite entry in either registry view.'
        exit 1
    }

    # Prefer the highest version present.
    $best = $found | Where-Object { $_.Parsed } | Sort-Object Parsed -Descending | Select-Object -First 1
    if (-not $best) { $best = $found | Select-Object -First 1 }

    if ($ExactVersion) {
        if ($best.Version -eq $ExactVersion) {
            $msg = "Citrix Workspace $($best.Version) detected (exact match)"
            Write-DetectLog "DETECTED: $msg"
            Write-DetectionOutput $msg
            exit 0
        }
        Write-DetectLog "NOT DETECTED: found $($best.Version), required exactly $ExactVersion."
        exit 1
    }

    $min = ConvertTo-VersionOrNull $MinimumVersion
    if (-not $min) {
        Write-DetectLog "NOT DETECTED: MinimumVersion '$MinimumVersion' is not a valid version."
        exit 1
    }
    if (-not $best.Parsed) {
        Write-DetectLog "NOT DETECTED: DisplayVersion '$($best.Version)' could not be parsed."
        exit 1
    }

    # Compare on as many parts as MinimumVersion specifies, so '25.7' accepts
    # every 25.7.x.x build rather than demanding 25.7.0.0 or higher only.
    # Clamped to 1..4: a [version] has at most four parts, and indexing past
    # the end would build a malformed string like '25.7.0.0.'.
    $parts = [Math]::Min([Math]::Max((($MinimumVersion -split '\.').Count), 1), 4)
    $trim  = {
        param($v, $n)
        $s = @($v.Major, [Math]::Max($v.Minor,0), [Math]::Max($v.Build,0), [Math]::Max($v.Revision,0))[0..($n-1)] -join '.'
        if ($s -notmatch '\.') { $s = "$s.0" }
        [version]$s
    }
    $lhs = & $trim $best.Parsed $parts
    $rhs = & $trim $min $parts

    if ($lhs -lt $rhs) {
        Write-DetectLog "NOT DETECTED: $($best.Version) is below minimum $MinimumVersion."
        exit 1
    }

    if ($RequireLtsr -and $lhs -ne $rhs) {
        # Same leading parts = same release family. A higher family (e.g. 26.3
        # Current Release) is newer but off the approved track.
        Write-DetectLog "NOT DETECTED: $($best.Version) is outside the $MinimumVersion LTSR family (-RequireLtsr)."
        exit 1
    }

    $msg = "Citrix Workspace $($best.Version) detected [$($best.DisplayName)] (minimum $MinimumVersion)"
    Write-DetectLog "DETECTED: $msg"
    Write-DetectionOutput $msg
    exit 0
}
catch {
    Write-DetectLog "NOT DETECTED: detection script error: $($_.Exception.Message)"
    exit 1
}
