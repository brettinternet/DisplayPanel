---
id: TASK-67
title: Diagnose and fix Escape focus for persistent blackout
status: done
assignees: ['@pi']
rank: ac2e8ba2e8ba2e8ae
created: 2026-10-07T23:26:00Z
updated: 2026-10-07T23:28:00Z
---

OLED blackout Action leaves displays hidden and Escape does not restore the display under the pointer. Installed build 3fb2a55 has the existing focus controller. Read-only status shows completed Action and hidden displays; 15 fake-backed focus tests pass. User approved narrow native focus tests, not monitor input or hardware writes.

## Acceptance criteria

- [x] A native focus regression demonstrates the failure mechanism and verifies Escape restoration after the fix
- [x] Pointer reentry and focus transitions retain Escape restoration without changing display hardware settings

## Plan

1. Reproduce actual AppKit key-window routing with an opt-in native test, including Settings already open. 2. Apply only a small demonstrated focus/restoration fix. 3. Run focused model and approved native checks; record remaining live-app uncertainty.

## Notes

Native AppKit reproduction: initial Escape reached proxy, but making another same-app window key then polling left that window key and restoration count at 1 instead of 2. After reasserting proxy key focus during pointer polling, native test passed. Native show is a no-op when already key. User-approved interactive suite: 16 passed. Final noninteractive focused run: 18 passed, native test skipped as intended; includes Hide/Show/Escape and disabled persistent one-shot integration. Swift compilation and git diff --check pass; test LSP clean, source diagnostic report initially unknown. Initial native harness needed NSApplication event draining (existing DisplayHideAppTests pattern) rather than only XCTest run-loop waits. No real covers removed, hardware writes, installed-app replacement, commits, or pushes. Exact cause of the already-running installed app state remains unconfirmed; the demonstrated focus defect is fixed in source.

## Summary

Recover the Escape proxy key window on pointer polling even when PanelCtl remains active. Added native responder-chain and fake-backed focus regression coverage; focused tests pass. Installed application unchanged.
