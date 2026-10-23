---
id: TASK-72
title: Show one-shot failures that happen after installation
status: done
type: bug
rank: ad1745d1745d17450
refs: [Sources/PanelCtlApp/AppModel.swift, Sources/PanelCtlApp/ProtectionCoordinator.swift]
created: 2026-10-08T05:44:00Z
updated: 2026-10-08T05:53:00Z
---

Review of TASK-56: if a one-shot helper reports its effect installed and then exits unsuccessfully, the per-rule feedback keeps the .done installation response and says the last run started, because ProtectionCoordinator discards the one-shot completion result and disabled rules' row status hides service state.

## Acceptance criteria

- [x] A one-shot that fails after installation shows the failure in the rule's run feedback, including for disabled rules.
- [x] A late installation acknowledgment cannot overwrite a recorded post-install failure.
- [x] A fake-helper regression covers install then unsuccessful exit.

## Plan

Pass one-shot completion success/message through onOneShotFinished; record a failed response for the rule when unsuccessful. In runProtectionRule clear the rule's result before dispatch and keep any failure recorded while awaiting. Add a fake-helper mode that installs then exits non-zero.

## Notes

Delivered in c3df9a2. ProtectionCoordinator passes one-shot completion success/message to onOneShotFinished; AppModel records an unsuccessful completion as the rule's failed run result (any entry point, disabled rules included). runProtectionRule clears the rule's result before dispatch and keeps a failure recorded while it awaited installation, so the .done installation response cannot overwrite it. Failure summary uses the helper message verbatim, so installation failures still match the CLI response exactly (existing testSettingsRunPresentsSameRefusalAndFailureAsCLI). New fake-helper mode crash-after-install; testSettingsRunShowsFailureAfterInstallation fails on the previous source and passes now. AC2 ordering is guaranteed by code structure; the regression exercises the common ordering. Combined verification across TASK-69..72: ProtectionRuleRunOnceTests 21 passed; AutomationRules/Cleanup/Safety, SettingsWindow, AppStatusStream, AppControlServer, DisplayHideApp, BlackoutFocusController, ProtectionPreferences, DisplayActionApp, AppControl and CLIParser suites: 255 executed, 29 native UI skipped, 0 failures. git diff --check clean. No hardware writes or desktop UI.

## Summary

Run feedback now shows one-shot failures that occur after installation, for CLI, menu and Settings runs, without masking installation failures. Red-to-green fake-helper regression; affected suites green.
