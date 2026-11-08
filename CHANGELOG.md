# Changelog

## Unreleased

- Add a **Turn off** Hide style (experimental) for monitors with no other input: the Mac stops sending a signal until Show turns the display back on and restores its layout. Works on the main display; one display at a time, and not while Hide mirrors another display.
- Split Remove from desktop into the **Mirror** and **Switch input** Hide styles. Switch input waits until you choose the input.
- Actions get a **Turn off** step, and their Show steps turn a turned-off display back on. Steps read Black out, Mirror (or Switch input), Turn off and Show.
- **Dismiss** a Hide or Show failure or input warning to clear the display's badge and menu line.
- Settings no longer starts a Full disconnect; use Turn off, or `dp recovery disable`. Settings still offers Reconnect for an unresolved one.
- Clear a hidden display's failed Hide or Show error once it's back on the desktop, including when another display's Show restored it.
- Choose each display's Hide style from a Style menu in Settings → Displays → Hide.
- Full disconnect recognizes the macOS 27.2 (26B123) setter; it reported the setter unavailable after the update.

## 0.9.9

- Showing the hidden main display while other displays stay hidden makes it main again; Restore repairs one that came back without the main role.
- Keep other hidden displays marked Hidden while one needs recovery; their Show says which display to restore first.

## 0.9.8

- Hide another display while a hidden monitor on another input doesn't offer its saved mode.

## 0.9.7

- Print readable `dp` output: tables for `list`, `probe` and `app status`, named displays in steps and DDC results, and plain mirror and handoff messages. `--json` is unchanged.
- Name displays hidden by mirroring instead of "Display 1".
- Say why arrangement protection is paused, such as "Paused while displays sleep or are off.", instead of recovery errors.
- Warn when `dp app` talks to a newer DisplayPanel; the README shows how to link the app's bundled `dp`.
- Hide a display that other hidden displays mirror onto; their mirrors move to its source.

## 0.9.6

- Explain display recovery problems in Settings without CLI advice such as "inspect recovery".
- Say when arrangement protection is paused because the main display is blacked out.
- Show one recovery explanation for displays hidden in a previous session.

## 0.9.5

- Choose a display's refresh rate in Settings or with `dp app refresh-rate`; mode protection keeps the choice.
- Run Hide, Show and protected-mode changes off the main thread, so the app stays responsive and no longer reports a false "mode unavailable".
- Keep Show, wake re-hide and mode protection working when macOS renumbers displays or their modes after a relink.
- Restore protected modes after the final Show.
- Keep running an Action's later Shows after one fails, and return a sibling display's input when an earlier step restored it.
- Don't ask to switch inputs for a Show already confirmed on the Mac, and leave removed displays unchanged while they sleep.
- Show recovery problems in Settings without CLI text or repeated controls.
- Add `dp app quit`, which keeps an unresolved display journal. The installer uses it and reopens the app.

## 0.9.4

- Run Actions from the menu bar under Run action.
- Re-send a dropped DDC input write once, and re-select a quiet Show input return once while waiting for a late saved mode.
- Continue Actions past an unconfirmed input step.
- Name the monitor blocking Show and re-offer its Mac input.
- Recover a Hide journal after macOS renumbers displays.

## 0.9.3

- Give displays that need recovery a working click action instead of a dead menu item.
- Open Settings when Show is blocked instead of dimming it.
- Tell you to switch inputs by hand for off-input hidden monitors.

## 0.9.2

- Clear a failed wake recovery journal when its exact hidden layout returns, instead of leaving the display flagged for recovery.
- Publish the app archive as `DisplayPanel.app.zip` so its download URL stays stable across releases.

## 0.9.1

- Wait for monitor input switches to settle before Show restores the desktop.
- Keep off-input hidden displays marked Hidden instead of incorrectly reporting Needs recovery.
- Offer Switch to Mac input in Settings when a monitor is on its configured alternate input.
- Remove repeated recovery error prefixes and persist Hide/Show outcomes and input-return traces for troubleshooting.

## 0.9.0

- Rename PanelCtl to DisplayPanel and the `panelctl` CLI to `dp`. The bundle ID, Application Support folder, defaults domain and release asset names change too; re-grant privacy permissions after upgrading.
- Sign releases with Developer ID and the hardened runtime, and notarize them, instead of a self-signed certificate. Downloads open without Open Anyway.
- Protect remembered display arrangements and a preferred main display after reconnects and wake, adapting to display size changes.
- Protect each display's saved mode after reconnects and wake.
- Preserve hidden displays and their names across monitor re-links.
- Add Show All Displays to the menu, and offer recovery for displays left hidden by a previous session.
- Let Show wait for an in-progress monitor input switch before restoring displays, without retrying failed writes.
- Resume enabled automation after display wake or configuration changes without requiring a manual refresh.
- Shorten Settings, menu, dialog and error copy, and show each display's Keep windows off status once in the menu.
- Fix Move windows refusal reasons reported to scripts, and offer Open Displays Settings after a failed re-hide on monitor re-link.
- Report Action recovery blockers as `recovery-needed` from typed causes, and restore rule review after an unconfirmed automation stop.

## 0.8.1

- Show hidden, paused, and attention states on the menu-bar mark.

## 0.8.0

- Redesign the app icon and menu-bar mark.
- Preserve hidden displays across wake layout drift.
- Build and test releases with Xcode 26.6 on macOS 26 runners.

## 0.7.0

- Add a standalone Move windows action and opt-in Keep windows off for individual hides, with explicit Accessibility permission controls.
- Sign app and CLI releases with a stable self-signed identity so privacy grants can survive updates. The first upgrade from ad-hoc signing requires re-granting permissions.
- Improve Settings layout, window-moving controls, and copyable CLI commands.
- Fix Show recovery after monitor input return, Escape focus recovery, and Run now with verified hidden displays.
- Fix one-shot automation lifecycle and failure reporting, prevent combined full-display coverage, and handle larger status-stream frames.
- Add local development initialization, formatting and lint hooks, and signing settings in `.env`.

## 0.6.2

- Add `panelctl app status --watch` for live status integrations.
- Add `panelctl app run-rule` and per-rule Run now, Copy CLI command, and menu controls.
- Fix status-stream test hangs on constrained CI runners.

- Retire `panelctl app blackout-now` and the broadcast Blackout Now menu action. Use `panelctl app hide --display UUID` for one display, `run-action` for saved Hide/Show steps, or `run-rule` to run one Automation rule.
- Add `--style black-out` to `panelctl app hide` and `toggle-hide` to force a black cover without changing a display's configured Hide style or preferences. Styled requests use protocol 2 so older running apps safely refuse them; ordinary requests remain protocol 1.
