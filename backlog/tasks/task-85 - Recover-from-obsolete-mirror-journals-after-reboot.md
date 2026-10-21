---
id: TASK-85
title: Recover from obsolete mirror journals after reboot
status: In Progress
assignee:
  - '@pi'
created_date: '2026-10-21 22:45'
updated_date: '2026-10-21 22:58'
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
- [ ] #1 Conservative automatic previous-boot retirement accepts only stable, uniquely identified complete separate desktop matching meaningful baseline properties; restoration write checks remain unchanged.
- [ ] #2 Needs recovery offers Hide again and Keep displays shown with clear confirmations and exact blockers. Hide again captures a fresh baseline and uses fresh identities without Show or input switching; Keep displays shown makes no display writes.
- [ ] #3 Original public-mirror journal is durably archived unchanged before replacement; locking, concurrent changes and interrupted archival fail safely. Private recovery evidence, missing or ambiguous displays and surviving mirrors cannot be discarded.
- [ ] #4 CLI exposes guarded manual recovery outcomes; documentation explains other-input and reduced-mode behavior and no automatic re-hide after relaunch.
- [ ] #5 Focused fake-backed regressions cover changed boot/IDs, reduced modes, unsafe identities, archive/race failures and zero unintended writes; independent safety review completed.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add guarded previous-session assessment and evidence-preserving journal retirement with fresh baseline; implement then verify fake-backed core tests and commit. 2. Add direct Keep displays shown and Hide again recovery UI/model actions and CLI, no DDC and no replay of old IDs; integrate conservative automatic acceptance after stable observations. Verify focused regressions and commit. 3. Update recovery guidance, conduct one independent safety review focused on stale identity, evidence loss and unintended writes, fix findings, run affected checks and finalize task. No hardware writes or native UI presentation without separate approval.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Core implementation added: previous-boot public-only assessment, two matching observations, strict unchanged write validation, evidence-preserving archive/replacement, and one fresh multi-target Hide transaction with no DDC. Six new fake-backed regressions pass, covering swapped IDs, reduced modes/manual acceptance, unsafe inventory, archive/confirmation failures and one-shot transaction failure. No live state was changed.

UI/model and CLI implemented: direct confirmed Hide again / Keep displays shown, whole-session scope, cleanup/lifecycle/busy gates, no configured input replay. Recovery CLI requires --consent-recovery. Independent reviewer 9d4d8b48 passed after fresh transport-evidence revalidation correction; focused settlement/staging regression passed. Affected suites: 201 tests, 10 native UI skips, zero failures (191 runnable); warnings-as-errors build and CLI help execution passed. SourceKit has stale cross-module diagnostics although compiler/tests pass. Settings snapshot fixture now includes eligible and unavailable previous-session states; native visual check awaits explicit user permission. No live journal or display writes performed.
<!-- SECTION:NOTES:END -->
