---
id: TASK-80
title: Keep remembered arrangements valid across resolution and scale changes
status: To Do
assignee: []
created_date: '2026-10-13 23:03'
labels: []
dependencies:
  - TASK-79
references:
  - 'https://betterdisplay.pro/guide/tutorials/protect-monitor-arrangement/'
documentation:
  - docs/display-recovery.md
priority: low
type: feature
ordinal: 68010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-79 saves exact display positions and refuses to act when a display's logical size or rotation changed, for example after a resolution or HiDPI scale change, or when a monitor returns at a different mode. Protection then stops helping until the user remembers the arrangement again. BetterDisplay avoids this with relative rules: a display placed beside or above a reference display, with chosen edges aligned. Preserving these relationships instead of fixed coordinates keeps the intended arrangement usable when sizes change. This task tolerates size changes in a remembered set without requiring the user to write rules, and keeps TASK-79's safety model.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Remembering an arrangement also records how the displays relate to each other: which side each display sits on relative to its neighbor, and which edges are aligned or by how much they are offset. Existing remembered arrangements remain usable.
- [ ] #2 When a remembered set returns with a changed logical size or rotation, PanelCtl computes a layout that keeps those relationships and the saved main display. It applies the layout only if the result is contiguous and non-overlapping, and otherwise refuses with a reason.
- [ ] #3 Sets whose sizes are unchanged produce exactly the positions TASK-79 saved. TASK-79's transition, suspension, identity, one-attempt and verification rules are unchanged.
- [ ] #4 Focused fake-backed regressions cover a resolution change, a scale change, a rotation change, mixed edge alignments, an unrepresentable result and the unchanged-size path. Docs describe tolerance for size changes and its limits.
<!-- AC:END -->
