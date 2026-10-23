---
id: TASK-70
title: Prevent automatic rules from combining with a running one-shot to cover every display
status: done
type: bug
rank: acba2e8ba2e8ba2dc
refs: [Sources/PanelCtlApp/AppModel.swift, Sources/PanelCtlApp/ProtectionCoordinator.swift]
created: 2026-10-08T05:43:00Z
updated: 2026-10-08T05:53:00Z
---

Review of TASK-55: automatic scheduling during a one-shot only checks display overlap. With disabled rule A running once (blocking, until activity) on one display, enabling disjoint rule B (until activity) on the other lets B start, so together they can black out every display indefinitely — the configuration combined-coverage validation normally rejects. Admission validation ignores A because it is saved as disabled.

## Acceptance criteria

- [x] While a one-shot runs, an automatic rule whose validation fails when the one-shot rule is counted as enabled does not start, and its status explains it is waiting for the one-shot to finish.
- [x] The deferred rule starts automatically after the one-shot finishes, and saved preferences are unchanged.
- [x] A fake-backed regression covers enabling a disjoint untimed rule during a disabled untimed one-shot.

## Plan

In AppModel.reconcileProtection, gate each enabled automatic rule on a second validation in which running one-shot rules count as enabled; keep normal arguments when it passes, otherwise withhold arguments and report a waiting reason. One-shot completion already reconciles and resumes rules. Add regression in ProtectionRuleRunOnceTests.

## Notes

Delivered in 9f8051d. AppModel.reconcileProtection revalidates each runnable automatic rule with the running (saved-disabled) one-shot rule counted as enabled; failures withhold the rule's arguments and set a waiting reason (“<name>” is running once; this rule starts when it finishes.). Normal arguments are kept when the gate passes, so non-conflicting rules are unaffected. Existing one-shot completion reconcile/resume starts the deferred rule. Regression testDisjointUntimedRuleCannotCombineWithUntimedOneShotToCoverEveryDisplay fails on the previous source (rule B launched) and passes now; it also checks the row headline, later automatic start and unchanged preferences apart from the user's enable.

## Summary

Automatic rules can no longer combine with a running disabled one-shot to black out every display indefinitely; they wait with an explanatory status and start after it ends. Red-to-green fake-helper regression.
