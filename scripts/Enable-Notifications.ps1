<#
.SYNOPSIS
    Enables Windows notifications (Notification Center + toast pop-ups).

.DESCRIPTION
    Reverses the policy that disables the Notification Center:

        [HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows\Explorer]
        "DisableNotificationCenter"=dword:00000001

    and ensures toast notifications are enabled for the current user.

    Steps performed:
      1. Removes DisableNotificationCenter from every policy location it
         can live in (removing the value returns the policy to
         "Not Configured" — the Windows default, notifications ENABLED):
            HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer
            HKLM\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows\Explorer
            HKCU\Software\Policies\Microsoft\Windows\Explorer
      2. Removes the "Turn off toast notifications" policy value
         (NoToastApplicationNotification) if present.
      3. Sets the user preference ToastEnabled = 1 so toasts are on even
         if a user (or the image) had switched them off in Settings.

    Takes effect at next logon, or immediately with -RestartExplorer.

    NOTE: HKCU steps apply to the user running the script. If this value
    is delivered by GPO or Intune, it will be re-applied on the next
    policy refresh — remove it at the source as well.

.PARAMETER RestartExplorer
    Restart explorer.exe after the change so it takes effect immediately
    (the taskbar briefly disappears and reloads).

.PARAMETER WhatIf
    Show what would be changed without changing anything.

.EXAMPLE
    .\Enable-Notifications.ps1
    .\Enable-Notifications.ps1 -RestartExplorer
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$RestartExplorer
)

$changed = $false

# HKLM writes need elevation
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning 'Not running elevated - HKLM policy values cannot be removed. Re-run as Administrator.'
}

# --- 1 + 2: remove notification-disabling policy values -------------------
$policyValues = @(
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer';             Name = 'DisableNotificationCenter' }
    @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows\Explorer'; Name = 'DisableNotificationCenter' }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer';             Name = 'DisableNotificationCenter' }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'NoToastApplicationNotification' }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'NoToastApplicationNotification' }
)

foreach ($v in $policyValues) {
    $current = Get-ItemProperty -Path $v.Path -Name $v.Name -ErrorAction SilentlyContinue
    if ($null -eq $current) {
        Write-Host "[OK]      $($v.Path) : $($v.Name) not present"
        continue
    }

    Write-Host "[FOUND]   $($v.Path) : $($v.Name) = $($current.$($v.Name))"
    if ($PSCmdlet.ShouldProcess("$($v.Path)\$($v.Name)", 'Remove policy value')) {
        try {
            Remove-ItemProperty -Path $v.Path -Name $v.Name -ErrorAction Stop
            Write-Host "[REMOVED] $($v.Path) : $($v.Name)" -ForegroundColor Green
            $changed = $true
        }
        catch {
            Write-Warning "Failed to remove $($v.Path)\$($v.Name) : $_"
        }
    }
}

# --- 3: turn toasts ON in the user's own preferences ----------------------
$prefPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'
$pref = Get-ItemProperty -Path $prefPath -Name 'ToastEnabled' -ErrorAction SilentlyContinue
if ($null -ne $pref -and $pref.ToastEnabled -eq 1) {
    Write-Host "[OK]      $prefPath : ToastEnabled already 1"
}
elseif ($PSCmdlet.ShouldProcess("$prefPath\ToastEnabled", 'Set to 1')) {
    if (-not (Test-Path $prefPath)) {
        New-Item -Path $prefPath -Force | Out-Null
    }
    New-ItemProperty -Path $prefPath -Name 'ToastEnabled' -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Host "[SET]     $prefPath : ToastEnabled = 1" -ForegroundColor Green
    $changed = $true
}

# --- Verification ----------------------------------------------------------
Write-Host "`n--- Verification ---"
$problem = $false
foreach ($v in $policyValues) {
    $current = Get-ItemProperty -Path $v.Path -Name $v.Name -ErrorAction SilentlyContinue
    if ($null -ne $current) {
        Write-Warning "$($v.Path) : $($v.Name) still = $($current.$($v.Name))"
        $problem = $true
    }
}
$pref = Get-ItemProperty -Path $prefPath -Name 'ToastEnabled' -ErrorAction SilentlyContinue
if ($null -ne $pref -and $pref.ToastEnabled -ne 1) {
    Write-Warning "$prefPath : ToastEnabled = $($pref.ToastEnabled) (expected 1)"
    $problem = $true
}
if (-not $problem) {
    Write-Host 'Notifications are enabled: no disabling policies remain, toasts are on.' -ForegroundColor Green
}

# --- Apply now (optional) ----------------------------------------------------
if ($changed -and $RestartExplorer -and $PSCmdlet.ShouldProcess('explorer.exe', 'Restart')) {
    Write-Host 'Restarting Explorer...'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    # Explorer normally auto-restarts; start it if it does not
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
}
elseif ($changed) {
    Write-Host 'Change takes effect at next logon (or run again with -RestartExplorer).'
}
