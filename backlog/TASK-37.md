---
id: TASK-37
title: Return to the Mac input when the current DDC input is unreadable
status: done
type: bug
assignees: [pi]
rank: a6ba2e8ba2e8ba2e2
created: 2026-10-05T23:05:00Z
updated: 2026-10-05T23:11:00Z
---

DELL S2721DGF Show restored topology after Hide selected empty HDMI 1, but a malformed Get VCP reply caused PanelCtl to skip Set VCP entirely. A known return input should not depend on reading the inactive input. Hardware responsiveness remains unqualified; offline tests only.

## Acceptance criteria

- [x] Show/back attempts at most one known return-input write after a failed current-input read, without weakening identity or topology checks; Hide and standalone selection still require a readable original.
- [x] Fake tests cover return success, unavailable readback, failed write, and unchanged safety refusals; docs distinguish hardware limitations from the pre-read gate.

## Plan

1. Reproduce the malformed pre-read with fake channels. 2. Permit unknown original input only for explicit Show/back, preserving strict Hide/standalone behavior, exact identity validation, one write and bounded readback. 3. Add regressions and document limitations; run offline tests/builds and commit only owned changes.

## Notes

Reproduced screenshot mechanism offline: testShowAttemptsKnownReturnInputWhenPreReadIsMalformed failed before patch (skipped, restore/read only, zero writes) and passes after patch. Show/back now permits unknown original after failed pre-read; optional original avoids inventing recovery input. Zero input and unavailable channel still skip. Hide/standalone read-first and identity checks unchanged. Focused 46 tests passed. Full warnings-as-errors suite passed: 247 core + 150 app tests, four expected skips. Both panelctl and PanelCtlApp warnings-as-errors builds and git diff --check passed. LSP DisplayHandoff clean; DDC diagnostic unknown, compiler evidence used. Independent verifier a8f68638-eab2-415b-a578-76387e9c586b pending. No hardware writes or live trials. User requested commit; unrelated dirty TASK-32 must remain untouched.

Independent verifier passed: 15 DDC tests and 19 mirroring tests, identity/topology guards, one-write behavior, honest unknown-original outcomes, and unchanged Hide/standalone read-first behavior. Hardware acceptance remains unqualified. Delivery is the scoped commit containing this task and its source/tests/docs; no worktree created.

## Summary

Removed the failed-pre-read gate only for explicit journal-backed Show/back. A known return input is attempted once after restoration and identity checks; no previous input is guessed. Regression reproduced before fix, 397 tests completed with four expected skips and no failures, both warnings-as-errors builds passed, and independent verification passed. No live hardware writes or qualification.
