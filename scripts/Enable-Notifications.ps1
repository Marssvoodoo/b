<#
.SYNOPSIS
    Enables Windows notifications (Notification Center + toast pop-ups).

.DESCRIPTION
    Reverses the policy that disables the Notification Center:

        [HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows\Explorer]
        "DisableNotificationCenter"=dword:00000001

    and ensures toast notifications are enabled for the current user.

    Steps performed:
      1. Sets DisableNotificationCenter = 0 (policy explicitly disabled,
         Notification Center ENABLED) in every location it can live in:
            HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer
            HKLM\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows\Explorer
            HKCU\Software\Policies\Microsoft\Windows\Explorer
         Only existing values are changed; the value is not created where
         it is absent (absent = Not Configured = enabled already).
      2. Sets NoToastApplicationNotification = 0 ("Turn off toast
         notifications" policy disabled) where present.
      3. Sets the user preference ToastEnabled = 1 so toasts are on even
         if a user (or the image) had switched them off in Settings.

    Changes take effect at the next logon.

    NOTE: HKCU steps apply to the user running the script. If these values
    are delivered by GPO or Intune, the next policy refresh will overwrite
    them — change them at the source as well.

.PARAMETER WhatIf
    Show what would be changed without changing anything.

.EXAMPLE
    .\Enable-Notifications.ps1
    .\Enable-Notifications.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param()

$changed = $false

# HKLM writes need elevation
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning 'Not running elevated - HKLM policy values cannot be changed. Re-run as Administrator.'
}

# --- 1 + 2: set notification-disabling policy values to 0 ------------------
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
        Write-Host "[OK]      $($v.Path) : $($v.Name) not present (Not Configured = enabled)"
        continue
    }
    if ($current.$($v.Name) -eq 0) {
        Write-Host "[OK]      $($v.Path) : $($v.Name) already 0"
        continue
    }

    Write-Host "[FOUND]   $($v.Path) : $($v.Name) = $($current.$($v.Name))"
    if ($PSCmdlet.ShouldProcess("$($v.Path)\$($v.Name)", 'Set to 0')) {
        try {
            Set-ItemProperty -Path $v.Path -Name $v.Name -Value 0 -Type DWord -ErrorAction Stop
            Write-Host "[SET]     $($v.Path) : $($v.Name) = 0" -ForegroundColor Green
            $changed = $true
        }
        catch {
            Write-Warning "Failed to set $($v.Path)\$($v.Name) : $_"
        }
    }
}

# --- 3: turn toasts ON in the user's own preferences ------------------------
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

# --- Verification ------------------------------------------------------------
Write-Host "`n--- Verification ---"
$problem = $false
foreach ($v in $policyValues) {
    $current = Get-ItemProperty -Path $v.Path -Name $v.Name -ErrorAction SilentlyContinue
    if ($null -ne $current -and $current.$($v.Name) -ne 0) {
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
    Write-Host 'Notifications are enabled: no disabling policies remain in effect, toasts are on.' -ForegroundColor Green
}

if ($changed) {
    Write-Host 'Changes take effect at the next logon.'
}
