---
id: TASK-85
title: Recover from obsolete mirror journals after reboot
status: Done
assignee:
  - '@pi'
created_date: '2026-10-21 22:45'
updated_date: '2026-10-21 23:07'
labels: []
dependencies: []
ordinal: 72010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
After logout/reboot with AW3425DW and DELL S2721DGF hidden, the previous-boot public mirror journal permanently blocks Hide/Show even when all monitors return. Strict boot and numeric-ID checks correctly prevent replay but also prevent recognizing recovery. Users need explicit Hide again and Keep displays shown outcomes directly from Needs recovery, including monitors still on another input but visible to macOS. Work on main with staged commits; offline/fake-backed validation only, no live display or DDC writes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Conservative automatic previous-boot retirement accepts only stable, uniquely identified complete separate desktop matching meaningful baseline properties; restoration write checks remain unchanged.
- [x] #2 Needs recovery offers Hide again and Keep displays shown with clear confirmations and exact blockers. Hide again captures a fresh baseline and uses fresh identities without Show or input switching; Keep displays shown makes no display writes.
- [x] #3 Original public-mirror journal is durably archived unchanged before replacement; locking, concurrent changes and interrupted archival fail safely. Private recovery evidence, missing or ambiguous displays and surviving mirrors cannot be discarded.
- [x] #4 CLI exposes guarded manual recovery outcomes; documentation explains other-input and reduced-mode behavior and no automatic re-hide after relaunch.
- [x] #5 Focused fake-backed regressions cover changed boot/IDs, reduced modes, unsafe identities, archive/race failures and zero unintended writes; independent safety review completed.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add guarded previous-session assessment and evidence-preserving journal retirement with fresh baseline; implement then verify fake-backed core tests and commit. 2. Add direct Keep displays shown and Hide again recovery UI/model actions and CLI, no DDC and no replay of old IDs; integrate conservative automatic acceptance after stable observations. Verify focused regressions and commit. 3. Update recovery guidance, conduct one independent safety review focused on stale identity, evidence loss and unintended writes, fix findings, run affected checks and finalize task. No hardware writes or native UI presentation without separate approval.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Core implementation added: previous-boot public-only assessment, two matching observations, strict unchanged write validation, evidence-preserving archive/replacement, and one fresh multi-target Hide transaction with no DDC. Six new fake-backed regressions pass, covering swapped IDs, reduced modes/manual acceptance, unsafe inventory, archive/confirmation failures and one-shot transaction failure. No live state was changed.

UI/model and CLI implemented: direct confirmed Hide again / Keep displays shown, whole-session scope, cleanup/lifecycle/busy gates, no configured input replay. Recovery CLI requires --consent-recovery. Independent reviewer 9d4d8b48 passed after fresh transport-evidence revalidation correction; focused settlement/staging regression passed. Affected suites: 201 tests, 10 native UI skips, zero failures (191 runnable); warnings-as-errors build and CLI help execution passed. SourceKit has stale cross-module diagnostics although compiler/tests pass. Settings snapshot fixture now includes eligible and unavailable previous-session states; native visual check awaits explicit user permission. No live journal or display writes performed.

User approved exactly SettingsWindowTests.testDisplaysFixtureSnapshots. Native fixture passed, screenshots inspected for eligible and unavailable recovery. Visual inspection caught misleading old Restore action when IDs survive reboot; fixed in 40f0e75, added model assertion, reran the two focused app recovery tests and approved native fixture successfully. Snapshot artifacts: /var/folders/jp/1mwx72h172955139pth4h8800000gn/T/panelctl-task85-ui.U39csfMhYd. AC1/3: fake core tests verify changed boot/IDs, exact semantic automatic acceptance, rejection of mode/layout/profile drift, missing/duplicate/private evidence, archived bytes, conflict retry, fresh connector evidence and cancelled/failed single commits. AC2: fake model tests verify both outcomes, cleanup/sleep cancellation and no old Restore; native snapshots verify visible/disabled controls. AC4: parser consent tests and built CLI help, updated recovery/Hide documentation. AC5: independent reviewer PASS with transport revalidation regression. Main commits fc239b5, c5a7a6d, 40f0e75. No live display/input writes, live journal retirement, app installation, push or worktree.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added guarded previous-boot public Hide recovery: conservative automatic no-write cleanup, direct confirmed Hide again / Keep displays shown, fresh identity/baseline capture, immutable archived evidence and consent-gated CLI. Verified 191 runnable affected-suite tests plus approved native Settings fixture, warnings-as-errors build and independent safety review; 10 other native tests intentionally skipped. Fixed stale transport revalidation and misleading Restore action. Live hardware behavior remains untried; installed app unchanged.
<!-- SECTION:FINAL_SUMMARY:END -->
