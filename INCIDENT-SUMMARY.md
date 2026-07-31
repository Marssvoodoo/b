# Citrix Workspace failure — incident summary

**Status:** Resolved. Endpoint returned to service.
**Affected endpoint:** HCDL-BP0WCW3 (one user). Two other endpoints touched during
investigation, both healthy.
**Date:** 30–31 July 2026

---

## Summary

A user could not launch Epic through Citrix. The investigation found **four
separate faults stacked on top of each other**, three of which produced the same
symptom from the user's side and none of which showed up in the standard checks —
the software reported itself as correctly installed throughout.

The endpoint is fixed and verified. A health-check tool now detects all four
conditions in a single pass, so a recurrence is a minutes-long job rather than a
day-long one.

One of the four faults was caused by our own cleanup tooling, and that carries a
fleet-wide risk that needs a decision (see *Recommended actions*).

---

## What the user experienced

1. Citrix prompted for **administrator credentials** when launching a published
   app — a standard user cannot supply these, so the app never opened.
2. After the first round of fixes, the prompt stopped but **nothing happened at
   all** when launching — no error, no window, no message.
3. Sign-in to Citrix worked normally throughout, which is why the problem
   initially looked like an application issue rather than a workstation issue.

---

## Root causes

**1. Citrix auto-updater was pointed at the wrong release track.**
The built-in updater defaults to Citrix's *Current Release* channel. Our fleet is
standardised on *LTSR* (long-term service release). The updater therefore saw a
"newer" version available and repeatedly tried to install it. Because Citrix is
installed machine-wide, a standard user cannot apply an update — hence the
administrator prompt. Had an administrator ever accepted that prompt, the machine
would have silently left the LTSR track.
*Scope: fleet-wide configuration gap, not machine-specific.*

**2. The `.ica` file association was linked to a repairable installer component.**
Opening a Citrix launch file triggered a Windows Installer self-repair, which a
standard user has no rights to complete — producing the same administrator
prompt from a different cause. This is a documented Citrix defect (CTX267718),
and Citrix notes it occurs even when the configuration *appears* correct.
Reinstalling does not fix it; the reinstall recreates the same link.

**3. The machine's Visual C++ runtime was below Citrix's minimum.**
Citrix 2507 requires version 14.42 or later; this machine had 14.22, dating from
2019. Citrix installed successfully and reported itself healthy, but its
components crashed instantly on launch. Citrix produced no error message of any
kind — the only evidence was in the Windows event log. This is what caused
"nothing happens".

**4. Windows Installer database damage blocked the fix for #3.**
Every attempt to update the Visual C++ runtime failed. The cause: the product was
registered in Windows, but its installer source files had been deleted from the
Windows Installer cache. In that state Windows cannot repair, upgrade, **or**
uninstall the product — every route fails.

The deletion came from our own Citrix remnant-cleanup script, which clears
installer cache entries as part of its sweep. Resolution required clearing the
orphaned registration (with a full registry backup) so a clean installation could
proceed.

---

## Resolution

The endpoint now has Citrix Workspace 2507 LTSR (25.7.2000.2020), the current
LTSR release, with:

- auto-updates disabled and the release track pinned to LTSR,
- the `.ica` association rebuilt so it no longer triggers installer self-repair,
- the Visual C++ runtime updated from 14.22 to 14.44,
- the damaged installer registration repaired.

The user has confirmed Citrix is working.

---

## Why this took as long as it did

Each fault masked the next. Fixing the administrator prompt revealed the silent
crash; diagnosing the crash revealed the stale runtime; fixing the runtime
revealed the installer database damage. Standard verification — "is Citrix
installed, is the version right, is the file association correct" — returned a
clean result at every stage, including while the machine was completely unusable.

---

## Risk to the wider fleet

**Any endpoint the Citrix remnant-cleanup script has run against may carry the
same installer database damage.** The damage is not limited to Citrix: it affects
every application whose installer cache entry was removed, and those applications
cannot be patched, repaired, or uninstalled until it is corrected. The symptom is
a generic installation failure with no obvious link back to the cleanup, so it is
likely to be diagnosed as unrelated.

The auto-updater misconfiguration (#1) is also fleet-wide. Every machine with
Citrix installed will produce the same administrator prompt the next time a user
launches an app, and each one is a candidate to drift off the LTSR track.

---

## Recommended actions

| Priority | Action |
|---|---|
| **High** | Remove the installer-cache section from the remnant-cleanup script before it runs on any further machines. |
| **High** | Apply the auto-update policy fleet-wide (a seconds-long script, no reinstall or reboot required). |
| Medium | Run the health check across the estate to identify machines already carrying installer database damage or a stale runtime. |
| Medium | Add a prerequisite check to the Citrix deployment package, so a machine with an out-of-date runtime is caught before deployment rather than after. |
| Low | Confirm that store configuration is re-pushed automatically, as a full Citrix removal wipes it. |

---

## Delivered

Seven scripts, documented and version-controlled:

- **`Test-CitrixHealth.ps1`** — single-pass check covering all four faults plus
  eight related conditions, reporting the specific remedy for anything it finds.
  Can apply the fixes automatically.
- Targeted repair scripts for each fault, usable independently.
- A diagnostic collector for cases that do not match a known pattern.
- A runbook documenting each failure mode and its distinguishing symptom.

All log to a consistent location and return standard exit codes for Workspace ONE
reporting.
