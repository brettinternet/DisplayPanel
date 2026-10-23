---
id: TASK-71
title: End a one-shot run when its rule is deleted
status: done
type: bug
rank: ace8ba2e8ba2e8b96
refs: [Sources/PanelCtlApp/AppModel.swift, Sources/PanelCtlApp/ProtectionCoordinator.swift]
created: 2026-10-08T05:43:00Z
updated: 2026-10-08T05:53:00Z
---

Review of TASK-55: deleting a rule that is running once keeps its helper active (reconciliation skips one-shot services) while AppModel.automationBlockingDisplayIDs only iterates saved rules, so Escape focus coverage for that display disappears. An untimed run then persists until CLI restore or quit, contradicting the deletion confirmation that any blackout or dimming from the rule ends.

## Acceptance criteria

- [x] Deleting a rule that is running once stops its one-shot helper and clears the running rule.
- [x] A fake-backed delete-during-run regression covers helper termination and focus membership.
- [x] Focus membership ends together with the stopped run, as with Restore.

## Plan

Stop one-shot services whose rule disappears from the rule set during coordinator reconcile. Derive blocking focus membership for the running one-shot from its captured mode rather than saved rules. Add regression.

## Notes

Delivered in 7a63faf. ProtectionCoordinator.reconcile stops one-shot services whose rule is no longer in the rule set, so deletion ends the run through the normal stop path (which clears blacked-out membership and Escape focus at once, exactly as Restore does). A model-side membership change was tried and reverted: stop clears membership synchronously, so it was unexercised. AC2 reworded accordingly. Regression testDeletingRuleDuringOneShotEndsTheRun times out on the previous source (helper never stops) and passes now.

## Summary

Deleting a rule that is running once now stops its helper and clears the running rule and focus membership, matching the deletion confirmation. Red-to-green fake-helper regression.
