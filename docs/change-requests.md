# Change Request Document

**Date:** 2026-07-13
**Prepared by:** IT / Endpoint Configuration
**Status:** New

This document contains three separate change requests, each formatted for
entry into the change-management system. Fields marked **[To be completed]**
are organization-specific (people, groups, dates) and should be filled in by
the requester/approver before submission.

---

## Change Request 1 — Disable Toast Notifications

| Field | Value |
|-------|-------|
| Impact | 3 - Low |
| Model | Normal |
| Type | Normal |
| State | New |
| Conflict status | Not Run |
| Conflict last run | — |
| Assignment group | End User Computing / Desktop Support *(confirm)* |
| Assigned to | [To be completed] |
| Business/Product User 1 | [To be completed] |
| Business/Product User 2 | [To be completed] |
| Security Team Approval | Not required — endpoint UX setting, no security control affected *(confirm)* |

**Short description**
Disable Windows toast (pop-up) notifications on end-user workstations.

**Description**
Toast notifications currently appear on user screens throughout the workday.
Because they pop up over the task a user is actively working on, users often
confirm or dismiss them without realizing what was asked, causing accidental
confirmations. This change disables toast notifications fleet-wide.

### Planning

**Justification**
Toast pop-ups interrupt daily work and cause accidental confirmations because
users click them without reading. Disabling them removes a recurring
interruption and prevents unintended actions.

**Implementation plan**
1. Configure policy to disable toast notifications via GPO or Intune
   (User Configuration → Administrative Templates → Start Menu and Taskbar →
   Notifications → "Turn off toast notifications", or the Intune equivalent).
2. Scope the policy to a pilot device group first.
3. Validate on the pilot group.
4. Roll out to the remaining user/device groups in rings.
5. Confirm application through management reporting.

**Risk and impact analysis**
Low risk. Users will no longer receive on-screen toast pop-ups, which also
suppresses some legitimate app/system notifications. No data loss and no
change to application functionality. Fully reversible through policy.
Mitigation: critical notifications are delivered through email/other channels.

**Backout plan**
Remove or disable the policy setting and force a refresh
(`gpupdate /force` or Intune sync). Notifications are restored at the next
policy refresh or logon.

**Test plan**
On a pilot device, apply the policy and confirm no toast notifications appear
during normal use of common applications, and that application functionality
is unaffected.

### Schedule

| Field | Value |
|-------|-------|
| Planned start | [To be completed] |
| Planned end | [To be completed] |
| Maintenance window | [To be completed] |

### Conflicts

Conflict check not yet run (status: Not Run). No known conflicting changes.

### Notes

None.

### Closure Information

**Production Validation Details**
After rollout, confirm on a sample of production machines that toast
notifications no longer appear during normal work.

**Major User Impact Details**
Users will no longer see on-screen toast pop-ups. Minimal impact expected;
this directly addresses complaints about interruptions and accidental clicks.

**Monitoring Details**
Monitor the service desk for any "missed notification" reports and verify the
policy is applied via Intune/GPO reporting.

---

## Change Request 2 — Stop Password Expiration Warnings

| Field | Value |
|-------|-------|
| Impact | 3 - Low |
| Model | Normal |
| Type | Normal |
| State | New |
| Conflict status | Not Run |
| Conflict last run | — |
| Assignment group | End User Computing / Desktop Support *(confirm)* |
| Assigned to | [To be completed] |
| Business/Product User 1 | [To be completed] |
| Business/Product User 2 | [To be completed] |
| Security Team Approval | Recommended — touches password/logon experience *(confirm)* |

**Short description**
Disable the on-screen password-expiration warning notification.

**Description**
Users receive an on-screen warning that their password is about to expire.
This warning is disruptive and redundant, because users already receive a
password-expiration reminder by email from CVS. This change suppresses the
on-screen warning only. Passwords continue to expire on the existing schedule
and users continue to receive the CVS email reminder.

### Planning

**Justification**
The on-screen warning is annoying and duplicates the CVS email reminder that
users already receive. Removing it eliminates a repeated interruption without
removing the reminder itself.

**Implementation plan**
1. Configure GPO/Intune to suppress the expiration prompt
   ("Interactive logon: Prompt user to change password before expiration"
   set to 0, or disable the corresponding notification mechanism).
2. Scope to a pilot group first.
3. Validate on the pilot group.
4. Roll out to remaining groups in rings.
5. Confirm application through management reporting.

**Risk and impact analysis**
Low risk. Users lose the advance on-screen warning, but passwords still expire
on schedule and the CVS email reminder is unchanged. Residual risk: a user who
misses the email could let a password expire and be locked out. Mitigation:
the CVS email reminder continues to notify users ahead of expiration.

**Backout plan**
Restore the setting to its previous value (e.g., the prior warning window) and
force a policy refresh. The on-screen warning returns at the next refresh or
logon.

**Test plan**
Apply the policy to a pilot account approaching expiration; confirm no
on-screen warning appears and that the CVS email reminder is still received.

### Schedule

| Field | Value |
|-------|-------|
| Planned start | [To be completed] |
| Planned end | [To be completed] |
| Maintenance window | [To be completed] |

### Conflicts

Conflict check not yet run (status: Not Run). No known conflicting changes.

### Notes

Scope is limited to the on-screen warning. Password expiration policy and the
CVS email reminder are intentionally unchanged.

### Closure Information

**Production Validation Details**
Confirm on a sample of production machines that the on-screen expiration
warning no longer appears and that the password-expiry policy is unchanged.

**Major User Impact Details**
Users lose the on-screen expiration countdown but retain the CVS email
reminder. Expected to reduce annoyance with no loss of notice.

**Monitoring Details**
Track account-lockout and expired-password tickets after rollout to confirm
the email reminder remains sufficient notice.

---

## Change Request 3 — Restore Windows Taskbar / Start Menu to Center

| Field | Value |
|-------|-------|
| Impact | 3 - Low |
| Model | Normal |
| Type | Normal |
| State | New |
| Conflict status | Not Run |
| Conflict last run | — |
| Assignment group | End User Computing / Desktop Support *(confirm)* |
| Assigned to | [To be completed] |
| Business/Product User 1 | [To be completed] |
| Business/Product User 2 | [To be completed] |
| Security Team Approval | Not required — cosmetic desktop layout setting *(confirm)* |

**Short description**
Restore Windows 11 taskbar / Start menu alignment to Center.

**Description**
During the Windows 10 → Windows 11 migration, the taskbar and Start button
defaulted to the center (the Windows 11 default). Because users were not yet
accustomed to the centered position, it was moved to the left to match the
familiar Windows 10 layout. Users have since adjusted to Windows 11, and this
change restores the taskbar/Start menu to the standard centered position.

### Planning

**Justification**
Users have acclimated to Windows 11, and the centered taskbar is the standard,
intended layout for the operating system.

**Implementation plan**
1. Set taskbar alignment to Center via Intune/registry
   (`TaskbarAl = 1` under
   `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced`;
   1 = Center, 0 = Left).
2. Deploy via policy/script and restart Explorer (or apply at next logon).
3. Pilot group first, then broad rollout in rings.
4. Confirm application through management reporting.

**Risk and impact analysis**
Low risk, cosmetic only. No functional or data impact. Fully reversible.

**Backout plan**
Set `TaskbarAl = 0` (Left) and refresh policy; restarting Explorer or logging
back on restores the left-aligned layout.

**Test plan**
Apply the setting on a pilot device and confirm the Start button and taskbar
icons are centered after logon, with no other changes to the desktop.

### Schedule

| Field | Value |
|-------|-------|
| Planned start | [To be completed] |
| Planned end | [To be completed] |
| Maintenance window | [To be completed] |

### Conflicts

Conflict check not yet run (status: Not Run). No known conflicting changes.

### Notes

Recommend a brief user communication ahead of rollout so the moved Start
button is expected.

### Closure Information

**Production Validation Details**
Confirm on a sample of production machines that the taskbar/Start menu is
centered after the change.

**Major User Impact Details**
Visual change — the Start button and taskbar icons move to the center of the
taskbar. Communicate to users beforehand to avoid confusion.

**Monitoring Details**
Monitor the service desk for confusion reports and confirm the setting applied
via Intune/GPO reporting.

---

## Summary

| # | Change | Impact | Reason |
|---|--------|--------|--------|
| 1 | Disable toast notifications | 3 - Low | Interrupts work; causes accidental confirmations |
| 2 | Stop password-expiration warnings | 3 - Low | Annoying and redundant with CVS email reminders |
| 3 | Restore taskbar / Start menu to center | 3 - Low | Standard Windows 11 layout; users have adjusted |
