---
id: TASK-77
title: Resume enabled automation after display wake settles
status: Done
assignee:
  - '@agent'
created_date: '2026-10-13 04:41'
updated_date: '2026-10-13 04:45'
labels: []
dependencies: []
type: bug
ordinal: 65010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Live inspection of PanelCtl 0.8.0 found enabled OLED protection with no helper after sleep/wake. A status query restarted the helper by refreshing runtime state. The ordinary lifecycle completion path clears its transition gate without reconciling automation; recovery-specific paths already rearm. Keep validation offline and do not change the installed app or force sleep.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Enabled automation resumes after normal sleep/wake and display configuration transitions without a status query or settings change.
- [x] #2 Disabled and snoozed automation remain inactive, and existing recovery/lifecycle guards remain intact.
- [x] #3 Fake-backed regression checks cover restart and fresh idle rearming; focused affected suites pass.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reconcile ordinary automation when the display lifecycle gate clears, preserving existing recovery rearm paths and guards. 2. Extend fake-helper lifecycle regressions for normal wake, configuration changes, idle rearming and disabled/snoozed states. 3. Run focused model suites, record evidence, and commit without installing or exercising live display changes.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Added a five-line ordinary lifecycle-completion reconciliation in AppModel, leaving journal-backed recovery rearming untouched. Reuses coordinator rearm-on-launch and all existing pause/cleanup/lifecycle gates. One fake-helper regression exercises system wake before screen wake, settled screen wake, display configuration changes, unmatched wake, persisted preferences, fresh idle rearm, disabled state and snooze. After implementation, temporarily removed the source fix and reran the same regression: five assertions failed, with only the initial helper launch instead of four. Restored the fix and verified affected suites: swift test --disable-sandbox --filter AutomationRulesTests|DisplayHideAppTests|DisplayActionAppTests|DisplayDisconnectIntegrationTests|BlackoutHideTests selected 182 tests, 171 passed, 11 interactive tests skipped, zero failures. Logs: /tmp/panelctl-task77-focused.log, /tmp/panelctl-task77-before.log, /tmp/panelctl-task77-validation.log. Test-file LSP diagnostics clean; AppModel report unknown, compiler/tests passed. git diff --check clean. No installed-app replacement, live sleep/wake, display write, or push; real hardware behavior remains unvalidated.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Resume enabled automation when the ordinary display lifecycle gate clears, without a status query or preference change. Fake-backed regression fails on old source and passes with the fix; 171 affected tests passed, 11 interactive tests skipped. Disabled/snoozed settings and existing recovery guards remain intact.
<!-- SECTION:FINAL_SUMMARY:END -->
