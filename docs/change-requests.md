# Change Request Document

**Date:** 2026-07-13
**Prepared by:** IT / Endpoint Configuration
**Status:** Requested

This document describes three separate change requests. Each change is
independent and can be reviewed, approved, and rolled out on its own.

---

## Change 1 — Disable Toast Notifications

**Category:** Desktop / OS notifications

### Current behavior
Toast (pop-up) notifications appear on users' screens throughout the day
while they are actively working.

### Problem
The pop-ups interfere with users' daily work activity. Because they appear
in the middle of active tasks, users frequently click or confirm them
without realizing what the notification was asking — leading to accidental
confirmations and unintended actions.

### Requested change
Turn off toast notifications so they no longer pop up during normal work.

### Rationale
- Removes a recurring interruption to daily work.
- Prevents accidental confirmations caused by pop-ups appearing over the
  task a user is focused on.

---

## Change 2 — Stop Password Expiration Warnings

**Category:** Authentication / password policy notifications

### Current behavior
Users receive on-screen warnings that their password is about to expire.

### Problem
The warnings are disruptive and annoying, and they are redundant — users
already receive a separate password-expiration reminder by email from CVS.

### Requested change
Stop the on-screen password-expiration warnings.

### Rationale
- The email reminder from CVS already notifies users that their password is
  expiring, so the on-screen warning duplicates information users are
  getting through another channel.
- Removes an unnecessary, repeated interruption.

> **Note:** This change only suppresses the *on-screen expiration warning*.
> Passwords will continue to expire on the existing schedule, and users will
> still be reminded by email from CVS.

---

## Change 3 — Restore the Windows Start Menu / Taskbar to the Center

**Category:** Windows desktop layout

### Background
When the environment was migrated from Windows 10 to Windows 11, the Start
button and taskbar icons defaulted to the **center** of the taskbar (the
Windows 11 default). At the time, users were not used to the centered
position, so it was moved to the **left** to match the familiar Windows 10
layout.

### Requested change
Move the Start menu / taskbar icons back to the **center** (the standard
Windows 11 position).

### Rationale
- Users have now adjusted to Windows 11, and the centered layout is the
  intended, standard position for the operating system.

---

## Summary

| # | Change | Reason |
|---|--------|--------|
| 1 | Disable toast notifications | Interrupts work; causes accidental confirmations |
| 2 | Stop password-expiration warnings | Annoying and redundant with CVS email reminders |
| 3 | Restore Start menu / taskbar to center | Standard Windows 11 layout; users have adjusted |
