---
id: TASK-81
title: Protect display modes after reconnect and input return
status: To Do
assignee: []
created_date: '2026-10-13 23:03'
labels: []
dependencies:
  - TASK-79
references:
  - Sources/PanelCtlCore/DisplayRecovery.swift
  - >-
    https://betterdisplay.pro/guide/technical-reference/configuration-protection/
documentation:
  - docs/display-recovery.md
priority: low
type: feature
ordinal: 69010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A monitor returning from another computer's input can come back with a reduced mode list and a different active mode, for example 60 Hz instead of the saved 240 Hz (see display-recovery.md). macOS may also pick a different resolution or refresh rate after a reconnect or wake. Explicit Show already waits for the exact saved mode of a hidden display. For visible displays, nothing restores the user's chosen mode. BetterDisplay's Configuration Protection covers resolution, refresh rate and rotation. Public CoreGraphics can set modes for the session, using the same exact-mode resolution PanelCtl recovery already uses. HDR and color profiles have no supported public setter and stay excluded.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Mode protection is opt-in for each display and off by default. Remember current mode saves the exact mode (resolution, refresh rate and scale) for a display, identified by the saved-display identity rule. Only an explicit Remember or Forget changes the saved mode.
- [ ] #2 After a transition settles, a protected visible display whose current mode differs from its saved mode is switched to the exact saved mode once, session-only, and verified. PanelCtl never approximates the mode. If the saved mode is not offered yet, it waits until a bounded deadline, then reports that the mode is unavailable without writing.
- [ ] #3 Changes without a transition are never reverted, so user changes in System Settings stand. Displays in an unresolved journal or mirrored by PanelCtl are skipped, and existing recovery keeps owning their modes. Protection is suspended during PanelCtl operations, wake resume and TASK-78 repair, and runs before arrangement correction so that arrangement checks see final sizes.
- [ ] #4 Writes take the operation lock, revalidate identity and topology at the write boundary, make at most one attempt per transition, and do not loop on their own notifications. Failures are reported with the reason.
- [ ] #5 Focused fake-backed regressions cover restoring a reduced mode after input return, a late-arriving mode, a missing mode at the deadline, a user change without a transition, skipping journaled and mirrored displays, ordering with arrangement correction, own-write notifications and failed verification. Docs describe the protected fields, the exclusion of HDR and color, and hardware status.
<!-- AC:END -->
