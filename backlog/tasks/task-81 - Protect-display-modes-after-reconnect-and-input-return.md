---
id: TASK-81
title: Protect display modes after reconnect and input return
status: Done
assignee: []
created_date: '2026-10-13 23:03'
updated_date: '2026-10-14 01:02'
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
- [x] #1 Mode protection is opt-in for each display and off by default. Remember current mode saves the exact mode (resolution, refresh rate and scale) for a display, identified by the saved-display identity rule. Only an explicit Remember or Forget changes the saved mode.
- [x] #2 After a transition settles, a protected visible display whose current mode differs from its saved mode is switched to the exact saved mode once, session-only, and verified. PanelCtl never approximates the mode. If the saved mode is not offered yet, it waits until a bounded deadline, then reports that the mode is unavailable without writing.
- [x] #3 Changes without a transition are never reverted, so user changes in System Settings stand. Displays in an unresolved journal or mirrored by PanelCtl are skipped, and existing recovery keeps owning their modes. Protection is suspended during PanelCtl operations, wake resume and TASK-78 repair, and runs before arrangement correction so that arrangement checks see final sizes.
- [x] #4 Writes take the operation lock, revalidate identity and topology at the write boundary, make at most one attempt per transition, and do not loop on their own notifications. Failures are reported with the reason.
- [x] #5 Focused fake-backed regressions cover restoring a reduced mode after input return, a late-arriving mode, a missing mode at the deadline, a user change without a transition, skipping journaled and mirrored displays, ordering with arrangement correction, own-write notifications and failed verification. Docs describe the protected fields, the exclusion of HDR and color, and hardware status.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add exact-mode capture/restore with saved-display identity checks, operation/journal locks, session-only transaction and verification. 2. Persist explicit per-display Remember/Forget and opt-in settings; run bounded mode settlement before arrangement correction, sharing transition suppression and lifecycle guards. 3. Add fake-backed regression coverage for transition timing, exclusions, boundaries and verification; document fields and untested hardware status. 4. Run focused checks and one independent safety review, commit, merge to main, finalize task and remove the owned worktree.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented explicit per-display saved modes and opt-in controls, exact session-only locked writer, bounded transition settlement before arrangement, and documented excluded fields/hardware status. Validation: 41 focused fake-backed tests passed (17 core arrangement/mode + 24 app arrangement/mode/input-return/wake/action); 5 mode app tests passed again after adding a journal-lock reentrancy regression. AppModel LSP diagnostics clean; core diagnostics initially unknown, compiler successful. Independent read-only safety review in progress. Worktree receipt: .git/worktrees/task-81-mode-protection/agent-creation.json; owner session 01a137b5-5073-7416-ab28-28396639a5f2. No live display writes or native UI trials.

Delivered as 9a1a220 (Protect saved display modes after transitions), fast-forward merged into primary main. Independent reviewer found two concrete lost-transition cases (staggered reconnect and reconnect during launch settlement); both fixed with focused regressions. Final verification: swift test --disable-sandbox --filter "ArrangementProtectionTests|DisplayArrangementTests|DisplayHideAppTests.testInputReturn|DisplayHideAppTests.testSleepWake|DisplayReconfiguration" passed 43 tests (17 core, 26 app), no failures. All changed production source files have clean LSP diagnostics; git diff --check and commit formatting/secret checks pass. AC1: explicit Remember/Forget, default-off persistence regression. AC2/4: exact session-only commit, offered-mode deadline, lock/identity/topology races, verification failure and own-notification regressions. AC3/5: user-edit no-op, journal/mirror skips, wake/input-return safety, and mode-before-arrangement ordering tests; docs describe protected fields and exclusions. Owned worktree and branch task-81-mode-protection removed via Worktrunk after receipt and pane checks; post-remove workspace cleanup verified separately. No remaining implementation blocker or resumable step; no push, hardware write or native UI trial performed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added opt-in per-display exact mode protection after reconnect/input return/wake, before arrangement correction, with bounded waiting, strict identity and operation-lock checks, session-only writes and failure reporting. Merged implementation 9a1a220 to main; 43 focused tests pass. Both independent review findings fixed. Hardware and native Settings interaction remain unverified and are documented; HDR/color/rotation excluded. Worktree and branch cleaned up.
<!-- SECTION:FINAL_SUMMARY:END -->
