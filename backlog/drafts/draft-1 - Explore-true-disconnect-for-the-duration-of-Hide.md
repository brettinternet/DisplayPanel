---
id: DRAFT-1
title: Explore true disconnect for the duration of Hide
status: Draft
assignee: []
created_date: '2026-10-15 05:32'
labels:
  - display-disable
  - research
dependencies: []
references:
  - >-
    backlog/completed/task-9 -
    Qualify-one-supervised-display-disable-and-recovery-cycle.md
  - Sources/PanelCtlCore/RecoveryLifecycle.swift
  - Sources/PanelCtlCore/RecoveryJournal.swift
  - Sources/PanelCtlCore/RecoveryWatchdog.swift
  - Sources/PanelCtlCore/RecoveryCLI.swift
  - Tests/PanelCtlCoreTests/RecoveryProductionProviderTests.swift
  - >-
    https://betterdisplay.pro/guide/faq/connections/keep-disconnected-after-wake/
  - 'https://cdn.cs.1worldsync.com/5b/fd/5bfd7ca5-0e0a-4fb7-94fa-62840b961f9f.pdf'
documentation:
  - docs/display-disable.md
  - docs/display-disable-tool-survey.md
  - docs/ddc-input.md
type: spike
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Hide currently removes the separate Mac desktop through mirroring but leaves the video signal active. When the other computer restarts or loses signal, the monitor can auto-select the Mac and display the mirror. The user wants the two right-hand monitors, AW3425DW and DELL S2721DGF, to remain unavailable to the Mac until explicitly shown, while Dell AW3423DW and Acer K272HUL remain usable.

Investigate whether a session-long true-disconnect Hide can safely meet that expectation, including hiding both targets and showing either independently. This is a bounded feasibility/design investigation, not authorization to implement or ship indefinite disconnect. Existing private disconnect is single-target, CLI-limited to 1–60 seconds (15 seconds in the app), and accepts macOS-initiated reconnection rather than automatically disconnecting again.

Evidence baseline: completed TASK-9 records one supervised S2721DGF/M3T101 cycle on Mac17,14, build 26A434, USB-C@3/DP. HDMI auto-selection and retained-ID restoration succeeded; visible Mac output needed manual DP selection. Electrical link shutdown, long-duration operation, other-computer reboot, sleep/wake and two-target recovery were not established. A read-only RecoveryProductionProviderTests.testCurrentHostNoWriteConnectedTargetAndSurvivorRehearsal on 2026-10-14 found both requested targets individually eligible with native drivers, matching identities and usable survivors; this is not hardware qualification. AW3425DW disconnect remains untested.

Scope is repository/source research, read-only qualification and fake-backed or no-write validation. Any private setter invocation, live restoration, DDC write or disruptive recovery requires separate fresh scoped approval covering the exact target, bounded duration, usable survivor, user presence and fallback. Do not relax identity checks, discard unresolved journals, use permanent configuration or infer permission from this task. Monitor Auto Select Off is a documented alternative for both models, but its reboot/standby behavior and DDC return availability are not yet verified on this setup.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Publish an evidence-backed feasibility verdict for each target and the two-target workflow, separating historical observations, fresh read-only results, documented behavior and untested assumptions; distinguish desktop removal from physical signal loss and monitor input selection.
- [ ] #2 Define the proposed Hide/Show safety contract and unresolved decisions for long sessions, independent target restoration, partial failure, app/helper exit or crash, loss of surviving displays, Mac sleep/wake, other-computer reboot, hotplug and identity changes. State where strictly remaining hidden until Show cannot be guaranteed.
- [ ] #3 Assess the existing journal, watchdog, lifecycle, input-return and restoration constraints without merely removing the timeout. Identify the minimum required changes and validation evidence, preserving strict identity refusal, session-only writes and unresolved recovery state.
- [ ] #4 Document a bounded hardware-validation proposal with explicit per-trial approval gates and observable success/failure criteria for signal behavior, input return and desktop restoration. No live trial is required to complete this investigation; unperformed trials remain unqualified.
- [ ] #5 Recommend proceed, defer or reject with concrete reasons and scoped follow-up work. Compare Auto Select Off plus current Hide, supported third-party disconnect behavior and a hardware switch/KVM as alternatives, including recovery limitations.
<!-- AC:END -->
