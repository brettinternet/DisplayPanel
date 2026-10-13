---
id: TASK-79
title: Protect remembered display arrangements after reconnect and wake
status: To Do
assignee: []
created_date: '2026-10-13 22:54'
labels: []
dependencies:
  - TASK-78
references:
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlApp/DisplayHidePreferences.swift
  - Sources/PanelCtlCore/DisplayRecovery.swift
  - 'https://betterdisplay.pro/guide/tutorials/protect-monitor-arrangement/'
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

Chosen design: remember arrangements per exact display set, for example all three monitors, or the two that remain when one is away. Never synthesize a layout for a subset that has no remembered arrangement; macOS's choice stands. This keeps behavior deterministic, avoids layouts macOS may reject, and matches BetterDisplay's 'all members connected' activation. macOS cannot report whether a person or the system changed the layout, so correction is limited to settling after a transition. A drag in System Settings is never reverted.

Known limit: if macOS swaps UUIDs between identical monitors that report no serial, the swap cannot be detected. Treat it as an identity limit; don't guess. Out of scope: displays in an unresolved PanelCtl journal (TASK-78 and existing recovery own those), window/Spaces placement, permanent configuration, mode or resolution protection, automatic input switching. Offline implementation only; live display writes need separate scoped human approval.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Protection is opt-in and off by default. Remember current arrangement saves the origins and main display for the current exact visible set, identified by exactly one matching UUID with the same vendor, model and serial. Remembering requires at least two visible displays, no mirrors and no unresolved journal. Remembered sets can be listed and forgotten, and only an explicit Remember updates them.
- [ ] #2 After a transition settles within a bounded window, if the current exact set has a remembered arrangement and its placement or main display differs, PanelCtl applies the saved origins and main once. The write is session-only, uses public CoreGraphics only and is then verified. Transitions are a display add, remove or re-link, or a wake.
- [ ] #3 No change is made when the current set has no remembered arrangement, when a display's logical size or rotation differs from the remembered one, or when identities are duplicate or ambiguous. Status names the reason and suggests remembering again where that applies.
- [ ] #4 Changes without a transition are never reverted. When the current arrangement differs from the remembered one, status shows it and offers Remember current and an explicit Restore arrangement command. The command applies the same checks.
- [ ] #5 Protection is suspended while any journal is unresolved or a PanelCtl operation, wake resume or TASK-78 repair is running. Writes take the operation lock and revalidate at the write boundary. Each transition allows at most one attempt, own-write notifications cannot loop, and a failure stops and is reported.
- [ ] #6 Focused fake-backed regressions cover drift after reconnect, a main-display change, a set without a remembered arrangement, a size change, manual rearrangement without a transition, explicit Restore, suspension during recovery, own-write notifications and failed verification. Docs describe the per-set model, its limits including identical-monitor swaps, and hardware status.
<!-- AC:END -->
