---
id: TASK-83
title: Show all hidden displays from the menu bar
status: Done
assignee:
  - '@agent'
created_date: '2026-10-15 04:43'
updated_date: '2026-10-15 04:44'
labels: []
dependencies: []
ordinal: 71010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Users need a quick way to bring back hidden displays without opening Settings or selecting each display individually.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Show All Displays appears below the menu display list only when there are hidden displays.
- [x] #2 The action restores hidden displays sequentially through existing Show safeguards and surfaces failures without continuing.
- [x] #3 Focused fake-backed tests verify bulk restoration and conditional menu visibility.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Reuse per-display Show with a snapshot of hidden targets and sequential completion callbacks; wire a conditional menu item; verify with fake-backed tests without desktop UI or hardware writes.
<!-- SECTION:PLAN:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added conditional Show All Displays below the menu display list. Sequential Show calls preserve existing guards and stop on failure, opening the affected display in Settings. Verified with swift test --disable-sandbox --filter BlackoutHideTests: 15 passed, including mixed removal/blackout restoration, menu visibility/order, and stop-on-failure coverage. Tests use fake writers; no desktop UI or hardware writes performed.
<!-- SECTION:FINAL_SUMMARY:END -->
