---
id: TASK-78
title: Keep hidden displays hidden when their monitor input returns to the Mac
status: To Do
assignee: []
created_date: '2026-10-13 22:42'
updated_date: '2026-10-13 22:54'
labels: []
dependencies: []
references:
  - Sources/PanelCtlApp/AppDelegate.swift
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlCore/DisplayMirroring.swift
  - Sources/PanelCtlCore/DisplayHide.swift
documentation:
  - docs/display-recovery.md
  - docs/display-hide-ux.md
priority: high
type: feature
ordinal: 66010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported scenario: displays are hidden with PanelCtl Hide (public mirror + DDC input away) so another computer can use them. When that computer's display sleeps, the monitor auto-switches back to the Mac's input. The Mac never lost the display, but the re-link makes macOS change the layout: the hidden monitor can reappear as an extended desktop, the main display can move, and visible displays can shift. The user then repairs it by hand.

Current behavior (verified in code): wake resume (TASK-76) only runs inside the sleep lifecycle with intent captured at willSleep. A screen-parameter change outside sleep refreshes and inspects the journal right away. If macOS restored the exact original baseline, MirrorController.reconcileSession accepts it as a system restoration and retires every removal, so the display is treated as shown without the user asking. If the layout drifted, the journal goes to recovery and nothing repairs it. If mirrors survive but visible displays move with the main display unchanged, the session still verifies and nothing is reported.

Design direction: extend the wake-resume guarantees to transitions caused by a monitor re-linking. Capture intent from the last verified hidden state before inspecting the new topology. Attribute the change from CoreGraphics reconfiguration flags, because NSApplication screen notifications carry no flags. Wait for the topology to settle within a bounded window, then reuse the existing guarded wake transaction. Repair is on by default, like wake resume: it preserves the user's explicit Hide and never shows a display or switches inputs. macOS does not say whether a person or the system made a change, so changes without re-link evidence stay under current behavior. One example is turning off mirroring in System Settings, the documented manual recovery path. Which flags a real input return produces is unverified; logging them read-only resolves that.

Out of scope: arrangement protection when no display is hidden (TASK-79), automatic Show or input switching, window/Spaces placement, permanent display configuration. Implementation and fake-backed validation proceed offline. Live display writes or disruptive trials need separate scoped human approval; passive event logging does not.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 While a verified mirror-hide session exists and PanelCtl is not running an operation, a hidden target or its source that re-links (for example by auto-switching input back to the Mac) triggers repair after the topology settles within a bounded window. The repair restores the hidden set, the session's saved visible arrangement and the main display, with the same reference layout and transaction guarantees as wake resume. It sends no DDC or input writes and never shows a hidden display.
- [ ] #2 Hidden intent is captured from the last verified state before the post-transition inspection, so an exact baseline restoration caused by a re-link is re-hidden rather than accepted as Show. Mirror, move or main-display changes without re-link evidence for a hidden target or its source keep current behavior, including System Settings manual recovery.
- [ ] #3 Per-display reconfiguration flags, the attribution decision and the repair outcome are logged without display writes, so the reported scenario can be characterized on real hardware.
- [ ] #4 Repair makes at most one write per transition, under the operation lock, and revalidates the journal, baseline, identities and topology at the write boundary. PanelCtl's own Hide/Show/recovery writes and repeated or own-write notifications cannot trigger or loop it, and the sleep/wake path stays authoritative during the sleep lifecycle.
- [ ] #5 Changed or ambiguous identities, unrelated mirrors, changed visible modes, unrepresentable origins, interrupted operations, stale journals and monitors that do not return within the window cause no write. The journal is retained, and the status explains the recovery step. A failed or unverified write stops without retry.
- [ ] #6 Focused fake-backed regressions cover: re-link with exact baseline restoration, lost mirror with drift, visible drift with intact mirrors, manual unmirror without re-link evidence, re-links from PanelCtl's own Hide/Show, unsettled topology and timeout, identity change, failed verification and no feedback loop. Wake-resume regressions still pass.
- [ ] #7 display-recovery.md and display-hide-ux.md describe the input-return behavior, attribution limits and refusals. Live validation of the reported scenario is either recorded with explicit approval or listed as an unverified hardware limit.
<!-- AC:END -->
