---
id: TASK-42
title: Generalize experimental disconnect eligibility beyond one monitor
status: done
labels: [reviewed]
rank: a7a2e8ba2e8ba2e84
created: 2026-10-06T15:48:00Z
updated: 2026-10-06T17:34:00Z
---

Users should opt into private disconnect based on runtime safety, not certification of an exact physical monitor. Implement offline only; no hardware writes authorized.

## Acceptance criteria

- [x] Any otherwise eligible non-main external display can request a bounded disconnect without a physical-unit or host qualification allowlist; genuine ABI compatibility remains enforced.
- [x] UI exposes disconnect with general risk consent and retains recovery access, strict identity, survivor, helper, journal and lifecycle safeguards.
- [x] Fake-backed regressions, documentation, builds and independent safety review pass; changes committed.

## Plan

1. Inspect all qualification gates and distinguish ABI requirements from hardware allowlists. 2. Generalize policy and UI with regression tests and current docs. 3. Run offline checks, independent review and commit.

## Notes

Implemented runtime monitor/host eligibility, generalized native Apple DCP inventory, and all-monitor UI visibility with explicit risk consent. ABI image UUID/origin checks retained; OS labels are no longer a separate certification gate. Full warnings-as-errors offline suite passed; both products and release-version checks passed. Native fake-backed ready/main-refused/lease controls rendered and inspected; no real display, DDC or private setter writes. Independent safety review pending.

Independent review found consent-time transport drift could be rebased at confirmation. Fixed by passing the original request snapshot to confirmation preflight and helper arming. Added production-shaped regression: it failed before the fix (writer construction and helper arming occurred), then passed after; unchanged evidence still completes a fake disconnect/reconnect. Reviewer reported no other validated delta-introduced findings. Final full warnings-as-errors suite, both product builds, release-version checks and diff check pass. Source LSP reports clean on final changed safety files. No hardware writes; no worktree created.

## Summary

Replaced single-monitor qualification with runtime eligibility and general per-operation risk consent. All selected monitors expose the control; unsafe targets remain blocked. Preserved exact consent-time identity, journal/helper recovery and ABI binary verification. Independent review finding fixed with a red/green regression. Verified 282 core + 221 app tests (7 expected skips, zero failures), both warnings-as-errors builds, release-version checks and native synthetic ready/refused/lease UI. Delivered in the Generalize experimental disconnect eligibility commit on main; no hardware writes or push.
