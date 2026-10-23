---
id: TASK-80
title: Keep remembered arrangements valid across resolution and scale changes
status: done
type: feature
priority: low
blocked_by: [TASK-79]
rank: ae8ba2e8ba2e8ba20
refs: ['https://betterdisplay.pro/guide/tutorials/protect-monitor-arrangement/', docs/display-recovery.md]
created: 2026-10-13T23:03:00Z
updated: 2026-10-14T00:05:00Z
---

TASK-79 saves exact display positions and refuses to act when a display's logical size or rotation changed, for example after a resolution or HiDPI scale change, or when a monitor returns at a different mode. Protection then stops helping until the user remembers the arrangement again. BetterDisplay avoids this with relative rules: a display placed beside or above a reference display, with chosen edges aligned. Preserving these relationships instead of fixed coordinates keeps the intended arrangement usable when sizes change. This task tolerates size changes in a remembered set without requiring the user to write rules, and keeps TASK-79's safety model.

## Acceptance criteria

- [x] Remembering an arrangement also records how the displays relate to each other: which side each display sits on relative to its neighbor, and which edges are aligned or by how much they are offset. Existing remembered arrangements remain usable.
- [x] When a remembered set returns with a changed logical size or rotation, PanelCtl computes a layout that keeps those relationships and the saved main display. It applies the layout only if the result is contiguous and non-overlapping, and otherwise refuses with a reason.
- [x] Sets whose sizes are unchanged produce exactly the positions TASK-79 saved. TASK-79's transition, suspension, identity, one-attempt and verification rules are unchanged.
- [x] Focused fake-backed regressions cover a resolution change, a scale change, a rotation change, mixed edge alignments, an unrepresentable result and the unchanged-size path. Docs describe tolerance for size changes and its limits.

## Plan

1. Persist deterministic neighbor relationships with backward-compatible decoding; adapt only remembered arrangements, retaining strict low-level restoration checks. 2. Solve size/rotation changes from the saved main display and refuse invalid geometry; preserve exact unchanged-size positions. 3. Add focused fake-backed geometry, persistence, and app regressions; update recovery docs. 4. Run focused core/app tests and one independent safety review, commit, merge main, finalize task, and remove the owned worktree.

## Notes

Implemented optional persisted neighbor rules with legacy inference, exact unchanged-geometry restoration, and resize/rotation adaptation before the unchanged strict writer. Deterministic BFS from saved main preserves selected sides and start/end/offset alignments; invalid shared edges, overlap, disconnected layouts, and noninteger/out-of-range origins refuse. Focused fake-backed DisplayArrangementTests (14) and ArrangementProtectionTests (9) pass; warnings-as-errors build passes. No live writes or interactive tests. Independent safety review pending. Worktree /Users/brett/dev/me/panelctl/.worktrees/task-80-relative-arrangements; branch task-80-relative-arrangements; receipt .git/worktrees/task-80-relative-arrangements/agent-creation.json belongs to session 01a1379e-14e8-70ca-a9f7-614b7e9fd143, created at dd0def4d4bc6e0fb2a307eecdad627f20db814d6.

Delivered commit 49d953366680b6a7fa2c4112d54508c875c44880 and fast-forward merged into primary main. Independent reviewer completed one general safety pass: no validated findings. Verification: swift test --disable-sandbox --filter "DisplayArrangementTests|ArrangementProtectionTests" passed 14 core and 9 app tests; swift build --disable-sandbox -Xswiftc -warnings-as-errors passed; Prettier docs check and commit hooks passed. AC1: persistence/legacy decode and app reload regressions. AC2: mixed edge/main preservation, overlap/shared-edge/range refusals, strict fake writer. AC3: exact legacy geometry, mode-race rejection, existing lifecycle/identity/one-attempt/verification suites. AC4: resolution, scale, rotation, mixed alignments and refusal regressions plus docs/display-recovery.md. Worktrunk removed the verified session-owned worktree and branch; Herdr workspace w8E is confirmed absent. No remaining blocker or resumable step; no hardware writes, push, or PR.

## Summary

Remembered arrangements now tolerate logical size and rotation changes through persisted neighbor relationships, with legacy inference and strict geometry refusal. Unchanged geometry preserves exact origins and all existing writer/lifecycle safety rules remain. Merged 49d9533 into main; 23 focused fake-backed tests, warnings-as-errors build, formatting/hooks and independent review passed. Worktree, branch and associated Herdr workspace removed.
