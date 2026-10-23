---
id: TASK-49
title: Include hidden displays in Automation editors
status: done
assignees: ['@pi']
rank: a8e8ba2e8ba2e8b9a
created: 2026-10-06T21:45:00Z
updated: 2026-10-06T21:49:00Z
---

Users cannot configure future actions or rules for monitors removed from the desktop because editors only list active displays. Selection must not show a hidden monitor or weaken execution safety.

## Acceptance criteria

- [x] Action and rule editors include hidden monitors after visible monitors and label them Hidden.
- [x] Saving hidden monitor selections preserves their UUIDs without showing them; existing runtime safety remains unchanged.
- [x] Focused regression tests and app build pass.

## Plan

Use a shared editor-only display inventory including hidden display records, ordered after visible displays and labeled Hidden. Update action defaults and unavailable-rule selections to use it. Leave runtime eligibility unchanged. Add fake-backed selection/save and native editor regression tests; run tests and build, then commit.

## Summary

Both Automation editors now use existing display tiles, include hidden monitors last with a Hidden label, and retain journaled targets even when absent from inventory. UUID-backed drafts and saves do not show monitors; runtime eligibility is unchanged. Verified with fake-backed inactive/disconnected/blackout regressions, native Action and Rule editor Cancel/Save tests, full swift test --disable-sandbox (zero failures; opt-in/accessibility skips), swift build --product PanelCtlApp, and git diff --check. No hardware writes performed.
