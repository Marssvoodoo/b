# Citrix Workspace LTSR toolkit

Scripts built while fixing Citrix Workspace app (CWA) 2507 LTSR on WS1-managed
endpoints, July 2026. All of them log to `C:\drop\citrix\` with 30-day rotation,
run under `NT AUTHORITY\SYSTEM` (WS1 Device context) or elevated admin, and are
PowerShell 5.1 compatible.

## Start here

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-CitrixHealth.ps1
```

`Test-CitrixHealth.ps1` is read-only and checks every failure mode below in one
pass, printing the exact remedy for each problem it finds. Add `-Fix` to have it
invoke the relevant repair scripts in dependency order.

Exit codes across the toolkit: `0` healthy, `1` warnings, `2` action needed,
`3` timeout / unsupported (varies by script — see each header).

## Scripts

| Script | Purpose |
|---|---|
| `Test-CitrixHealth.ps1` | One-pass health check of everything below. `-Fix` delegates repairs. |
| `Reinstall-CitrixLTSR.ps1` | Forced reinstall of CWA LTSR. Sources the installer from `-InstallerPath` → payload beside the script → `-SharePath` → winget. Sets auto-update policy. |
| `Install-CitrixPrerequisites.ps1` | Verifies/repairs VC++ and .NET Desktop runtimes. Escalates install → repair → source-repair → `-RemoveOrphanedRegistration`. `-ShimAppLocal` unblocks Citrix without touching the system runtime. |
| `Repair-IcaAssociation.ps1` | Republishes `.ica` under a non-advertised ProgID to stop MSI self-repair prompting non-admins for credentials. |
| `Set-CitrixAutoUpdate.ps1` | Pins the Citrix Workspace Updater (default: disabled, stream LTSR). No reinstall needed. |
| `Repair-Winget.ps1` | Makes winget usable under SYSTEM (fixes `0xC0000135`), including a portable extraction fallback. |
| `Get-CitrixLaunchDiagnostics.ps1` | Read-only dump of everything that decides whether a published app launches. Run while the affected user is signed in. |

## Failure modes, and what they look like

Several of these present identically to the user ("nothing happens") while every
obvious registry check passes. That is why the health check exists.

**1. `.ica` association bound to an advertised MSI component.**
User is prompted for *administrator credentials* when launching an app.
Windows Installer runs a self-repair that a non-admin cannot complete on a
per-machine install. Citrix documents the association as corrupt "despite
appearing intact within the Windows registry"
([CTX267718](https://support.citrix.com/external/article/CTX267718/workspace-app-for-windows-shows-fatal-er.html)) —
so a passing registry check proves nothing. Reinstalling does **not** fix it;
it recreates the same advertised association. → `Repair-IcaAssociation.ps1`

**2. Auto-update offering Current Release to an LTSR machine.**
Same admin-credential prompt, different cause. The updater's default stream is
Current Release, so an LTSR endpoint is offered CR — and if an admin ever
accepts, the machine silently leaves the LTSR track. → `Set-CitrixAutoUpdate.ps1`

**3. VC++ runtime below CWA's minimum.**
CWA installs fine and the registry looks perfect, but `wfcrun32.exe` /
`SelfService.exe` access-violate (`0xc0000005`) the instant they start. Citrix
logs nothing; the only evidence is Application event 1000. **Judge the DLL on
disk, not the redist registry key** — they disagree in the field, and the loader
binds the DLL. → `Install-CitrixPrerequisites.ps1`

**4. Orphaned MSI registration (System Error 1612).**
A product registered with `LocalPackage` pointing at a file no longer in
`C:\Windows\Installer` cannot be repaired, upgraded **or** uninstalled — every
attempt dies in `RemoveExistingProducts` with 1714/1603. Caused by cleanup that
deletes Installer cache entries, and it breaks servicing for *every* affected
product, not just Citrix. → `Install-CitrixPrerequisites.ps1 -RemoveOrphanedRegistration`
(exports each key to `.reg` before clearing)

**5. winget unusable under SYSTEM.**
`winget.exe` exits `-1073741515` (`0xC0000135`) before printing anything, which
breaks winget-based installer sourcing. Windows blocks LocalSystem from Appx
`Register` (`0x80073CF9`), so per-user registration cannot fix it either — the
portable extraction path is the reliable cure. → `Repair-Winget.ps1`

**6. Per-user CWA install alongside the machine-wide one.**
At logon Windows replaces the user version with the admin version; the removal
often half-fails (`1603`, `1730`). Cleanup run as SYSTEM while the user is
signed out never sees their `HKCU`, so the per-user install survives the wipe.
Run cleanup while the affected user is signed in.

**7. Stores wiped by a clean reinstall.**
Everything verifies correctly but users land on "Add Account". Confirm GPO/WS1
re-pushes the StoreFront URL before relying on `-CleanInstall` or a full wipe.

## Cautions

- **Do not delete `C:\Windows\Installer` cache entries** in any cleanup script.
  That is what causes failure mode 4, and the damage extends well beyond Citrix.
- `-CleanInstall` and full removal wipe configured stores (failure mode 7).
- `-ShimAppLocal` is a workaround, not a fix. App-local DLLs are never serviced
  by Windows Update, so once the system runtime is repaired the shim becomes the
  stale copy — remove it and re-test.
- Per-user checks only see users who are currently signed in.
- There is no Citrix evergreen URL for LTSR builds (CTX338523). winget's
  `Citrix.Workspace.LTSR` manifest lags Citrix releases by weeks; stage the exe
  as WS1 payload when a CU needs to land faster.
