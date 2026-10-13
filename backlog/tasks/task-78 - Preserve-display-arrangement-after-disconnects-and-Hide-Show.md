---
id: TASK-78
title: Preserve display arrangement after disconnects and Hide/Show
status: To Do
assignee: []
created_date: '2026-10-13 22:42'
labels: []
dependencies: []
references:
  - Sources/PanelCtlApp/AppDelegate.swift
  - Sources/PanelCtlApp/AppModel.swift
  - Sources/PanelCtlCore/DisplayMirroring.swift
  - Sources/PanelCtlCore/DisplayRecovery.swift
documentation:
  - docs/display-recovery.md
  - docs/display-hide-ux.md
type: feature
ordinal: 66010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
macOS sometimes unexpectedly rearranges surviving displays or changes the main display after monitors disconnect, reconnect, or are hidden. Users should not have to repair that arrangement manually. Display-change notifications describe what changed, not whether a person intended it, so this feature must use conservative transition-scoped protection rather than claim reliable user-intent detection or continuously fight System Settings.

Scope: opt-in arrangement preservation for PanelCtl Hide/Show and physical disconnect/reconnect, coordinated with existing wake recovery. TASK-76 already repairs a narrower pre-sleep mirror-hide session; TASK-58 covers guarded explicit Show recovery. Extend those protections without weakening their identity, mode, journal, or session boundaries. Window placement and Spaces, permanent display configuration, automatic input switching, and automatically re-enabling absent/hidden displays are outside scope.

Implementation and fake-backed validation can proceed offline. This task does not authorize live display writes, disruptive disconnect/sleep trials, DDC, or private setters. Hardware validation requires separate scoped human approval; record any remaining hardware limits explicitly.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Arrangement preservation is opt-in and disabled by default, with an explicit way to remember an intentional arrangement; unexpected transition output does not silently replace the saved intent.
- [ ] #2 After a supported Hide/Show, physical disconnect/reconnect, or wake transition settles, eligible layout drift is corrected to the saved relative placement and available preferred main display. When the preferred main is absent or hidden, a documented deterministic visible fallback is used; no absent or intentionally hidden display is enabled or shown merely to restore geometry.
- [ ] #3 A coordinate-origin shift alone is not classified as layout drift. Remaining-display layouts are valid, and reconnecting displays regain their intended placement only when existing strict identity checks permit it.
- [ ] #4 Ordinary user rearrangements outside the bounded transition window are not reverted. Ambiguous or conflicting changes produce no automatic correction and actionable status; documentation explains that macOS does not provide reliable user-versus-system attribution.
- [ ] #5 Correction waits for stable observations within a bounded window, revalidates at the write boundary, and makes at most one session-only correction attempt per eligible transition. Own-write notifications and repeated events cannot cause a feedback loop; a failed correction stops and reports recovery needs.
- [ ] #6 Existing Hide/Show and wake recovery remain authoritative: unresolved journals and hidden intent are preserved, concurrent recovery writers are prevented, and changed or ambiguous identities, incompatible modes, unrelated mirrors, or stale baselines are refused without weakening current safety checks. Arrangement protection performs no DDC or private enable/disable writes.
- [ ] #7 Focused fake-backed regressions cover survivor drift, main-display loss, coordinate rebasing, reconnect, manual/ambiguous changes, unstable topology, own-write notifications, identity refusal, and failed verification. Documentation records supported transitions, refusal behavior, explicit baseline adoption, and separately approved or still-unverified hardware behavior.
<!-- AC:END -->
