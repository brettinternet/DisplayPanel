---
id: TASK-79
title: Protect remembered display arrangements after reconnect and wake
status: Done
assignee: []
created_date: '2026-10-13 22:54'
updated_date: '2026-10-13 23:58'
labels: []
dependencies:
  - TASK-78
references:
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/DisplayHidePreferences.swift
  - Sources/PanelCtlCore/DisplayRecovery.swift
  - 'https://betterdisplay.pro/guide/tutorials/protect-monitor-arrangement/'
  - Sources/PanelCtlCore/AppControl.swift
  - Sources/PanelCtlApp/DisplayActions.swift
documentation:
  - docs/display-recovery.md
  - docs/display-hide-ux.md
priority: low
type: feature
ordinal: 67010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
macOS sometimes restores a different arrangement or main display when monitors disconnect, reconnect or wake, even with no PanelCtl-hidden display involved. The usual cause is identical monitors or stale WindowServer state. BetterDisplay sells Layout Protection for this, which shows demand. PanelCtl already has public, session-scoped CoreGraphics origin and main-display writes, the saved-display identity rule and a bounded settle pattern. TASK-78 adds re-link attribution from reconfiguration flags, which this task reuses.

Chosen design: remember arrangements per exact display set, for example all three monitors, or the two that remain when one is away. A separate preferred main display covers sets with no remembered arrangement. Making that display main shifts every origin by the same offset, so relative placement is unchanged. Never synthesize positions for a set that has no remembered arrangement. This keeps behavior deterministic, avoids layouts macOS may reject, and matches BetterDisplay's 'all members connected' activation. macOS cannot report whether a person or the system changed the layout, so correction is limited to settling after a transition. A drag in System Settings is never reverted. Unlike BetterDisplay, protection does not re-apply on every configuration change.

Deliberately excluded after comparing with BetterDisplay: display groups, priority and exclusive groups (exact-set keys cannot overlap), and per-port identification of identical monitors (it would weaken the strict identity rule). If macOS swaps UUIDs between identical monitors that report no serial, the swap cannot be detected. Treat it as an identity limit; don't guess. Follow-ups: TASK-80 (tolerate resolution/scale changes) and TASK-81 (mode protection).

Out of scope: displays in an unresolved PanelCtl journal (TASK-78 and existing recovery own those), window/Spaces placement, permanent configuration, automatic input switching. Offline implementation only; live display writes need separate scoped human approval.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Protection is opt-in and off by default. Remember current arrangement saves the origins and main display for the current exact visible set, identified by exactly one matching UUID with the same vendor, model and serial. Remembering requires at least two visible displays, no mirrors and no unresolved journal. Remembered sets can be listed and forgotten, and only an explicit Remember updates them. Turning protection off keeps them.
- [x] #2 After a transition settles within a bounded window, if the current exact set has a remembered arrangement and its placement or main display differs, PanelCtl applies the saved origins and main once. The write is session-only, uses public CoreGraphics only and is then verified. Transitions are a display add, remove or re-link, or a wake. An optional Apply on launch setting, off by default, also treats app launch as a transition.
- [x] #3 A preferred main display can be chosen independently of remembered arrangements. When the current set has no remembered arrangement and that display is visible but not main, PanelCtl makes it main after a transition without changing relative placement. A remembered arrangement for the set takes precedence, and a preferred main that is absent or hidden causes no change.
- [x] #4 No change is made when a display's logical size or rotation differs from the remembered one, or when identities are duplicate or ambiguous. Changes without a transition are never reverted.
- [x] #5 Status shows whether the current set is protected by a remembered arrangement, covered only by the preferred main, unprotected or suspended, and the reason. When the current arrangement differs from the remembered one, it offers Remember current. The same status is available through app control.
- [x] #6 An explicit Restore arrangement command is available from the app, from the CLI through app control, and as an Action step. It applies the same identity, size, suspension and verification checks, and reports refused or failed results with the reason.
- [x] #7 Protection is suspended while any journal is unresolved or a PanelCtl operation, wake resume or TASK-78 repair is running. Writes take the operation lock and revalidate at the write boundary. Each transition allows at most one attempt, own-write notifications cannot loop, and a failure stops and is reported.
- [x] #8 Focused fake-backed regressions cover drift after reconnect, a main-display change, preferred main without a remembered arrangement, an absent preferred main, apply on launch, a size change, manual rearrangement without a transition, explicit Restore through the app and the CLI, suspension during recovery, own-write notifications and failed verification. Docs describe the per-set and preferred-main model, Restore, its limits including identical-monitor swaps, and hardware status.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add a public-CoreGraphics, origin-only arrangement planner/writer with strict saved identity, logical-size/rotation, journal/operation-lock and post-write verification checks.
2. Persist opt-in exact-visible-set arrangements and preferred main; integrate bounded transition-only settlement, status, explicit Restore, CLI/app-control and Action steps. Add Settings controls and docs.
3. Exercise fake-backed critical regressions, run affected suites/build, perform one independent safety review, then commit, merge main, finalize task and remove the owned worktree.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Claimed on main. Implementation worktree /Users/brett/dev/me/panelctl/.worktrees/task-79, branch task-79, base 49dba49c9a8333ff4f097529982afd8754c282c2. Creation receipt .git/worktrees/task-79/agent-creation.json; session 01a1379c-531c-7416-ab28-2821cf15a6f2. Offline fake-backed validation only; no live display writes authorized.

User approved narrowly filtered fake-display Settings native UI testing in this session. No display or DDC hardware writes are authorized.

Implemented exact-visible-set persistence, opt-in transition settlement, independent preferred main, public session-only origin writer with operation/journal locks and fresh boundary checks, app/control/CLI/global Action Restore, Settings controls and docs. AC1: persistence/exact-set/explicit Remember/Forget/off-retains tests and native Remember click. AC2-4: reconnect, wake, launch opt-in, main drift, preferred-main translation/absent/hidden/precedence, manual edits, identity and geometry regressions. AC5-6: all status states and drift prompt, actual app-control socket Restore and Action round-trip/run/refusal, parser/no-launch/no-retry tests. AC7: journal and both locks, boundary topology/ID and excluded-display races, recovery/wake suspension, own callbacks and failed verification/no retry. AC8: docs now describe model, commands, identical-monitor identity limits and offline hardware status.
Verification passed: DisplayArrangementTests 10; ArrangementProtectionTests 8; AppControlTests 17; AppControlServerTests 7; DisplayActionAppTests 56; CLIParserTests 26; AppStatusStreamTests 7; affected DisplayHideAppTests sleep/wake/input-return regressions 18; SettingsWindowTests.testArrangementSettingsRememberAndOptInDoNotWriteDisplays 1 (150 selected tests total). The approved native fixture uses screenshot-verified mouse events because SwiftUI renders its buttons without NSButton peers; it waits for disclosure animation before clicking. Final screenshot /tmp/panelctl-task79-settings/remembered-arrangement.png inspected. Final warnings-as-errors build including tests, docs Prettier check, git diff --check and direct CLI help passed. LSP clean for new settings/preferences; other reports unknown, not treated as clean. Independent read-only reviewer b198519a reported no validated findings. No live CoreGraphics, private setter, DDC or hardware trial was run. Remaining delivery: commit implementation, integrate main, remove session-owned worktree and record receipts.

Delivery complete. Implementation commit d7eeba8569ad6e9e472143fadef7215192a2cb31 fast-forward merged into primary main. Worktrunk verified the original session creation receipt and clean merged checkout before removal. wt remove task-79 --foreground --format=json removed /Users/brett/dev/me/panelctl/.worktrees/task-79 and deleted branch task-79. Its Herdr workspace w8C was inspected (one idle zsh pane at the exact checkout path); post-remove hook closed it, and a fresh workspace list confirmed it disappeared. Workbench plugin was unavailable, so cleanup inspection used the installed Herdr CLI. Only primary main remains; no owned worktrees/workspaces retained. No push or PR. All acceptance criteria and requested delivery obligations met; claim released. Hardware validation remains intentionally unperformed and requires a separate scoped request, not a blocker for this offline task.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added opt-in per-set arrangement protection, preferred main and verified Restore from Settings, app-control CLI and Actions. It uses public session-only origins, strict identities/geometry, bounded transition-only settlement and shared recovery locks. Verified with 150 selected fake-backed/native-fixture tests, a warnings-as-errors build including tests, formatting and an independent review with no validated findings. Committed and merged to main; implementation worktree, branch and Herdr workspace removed. No live display writes or push.
<!-- SECTION:FINAL_SUMMARY:END -->
