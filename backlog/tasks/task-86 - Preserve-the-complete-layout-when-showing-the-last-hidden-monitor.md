---
id: TASK-86
title: Preserve the complete layout when showing the last hidden monitor
status: Done
assignee:
  - '@agent'
created_date: '2026-10-22 22:13'
updated_date: '2026-10-22 22:14'
labels: []
dependencies: []
type: bug
ordinal: 73010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
On 2026-10-22 at 15:59:11, the second Show unmirrored display 2 but macOS moved already-shown display 3 to the main origin and display 4 to x=4880. Full restoration skipped those initially unchanged origins. User authorized implementation, commit, push and task copy:release, not a live hardware trial.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Full restoration stages every saved origin when mirror topology changes, with the saved main last; unchanged topology retains minimal writes.
- [x] #2 Offline regression covers initially matching survivors during final unmirror, and focused recovery tests pass.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reuse closure-injected staging conventions to test full-restore origin requests without hardware. 2. Stage all saved origins on mirror changes, main last. 3. Run focused recovery suites, commit, push and install the release.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Verified TargetRestoreTransactionTests (6 passing), then DisplayRecoveryTests, DisplayMirroringTests and TargetRestoreTransactionTests with warnings as errors (60 passing). Regression exercises the production origin-staging closure: all saved origins on final unmirror, saved main last, exact saved coordinates, no writes for unchanged layout, minimal layout-only writes. LSP test diagnostics clean; source diagnostics unknown, compiler checks passed. No live hardware trial. Commit/push and signed release installation requested by user follow implementation verification.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Full restoration anchors all saved display origins when mirroring changes, including initially matching survivors, with the original main last. Existing identity, session-only and verification safeguards are unchanged. Offline regression and 60 focused tests passed; live monitor return remains unverified.
<!-- SECTION:FINAL_SUMMARY:END -->
