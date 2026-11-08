# Private display disable

Drop the Mac's signal to one monitor so a multi-input monitor can switch to
another computer, then reconnect it safely. Mirroring and DDC input switching
can't do this: the Mac's signal stays on.

> [!WARNING]
> This uses a private macOS API with no compatibility promise. Some monitors
> don't reconnect automatically; you may need to select the Mac's input with
> the monitor's buttons or replug the cable. Blackout is the safe alternative.

## Mechanism

```c
CGDisplayConfigRef config;
CGBeginDisplayConfiguration(&config);
CGSConfigureDisplayEnabled(config, displayID, false);   // true to reconnect
CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
```

- The setter is loaded at runtime (`CGSConfigureDisplayEnabled`, falling back
  to SkyLight's `SLSConfigureDisplayEnabled`) with the signature
  `@convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError`.
  If macOS changes, the feature reports unavailable instead of breaking.
  Verified builds: `26A434` and `26B123` (macOS 27.2), each by read-only
  disassembly of the setter, `SLSBeginDisplayConfiguration` and its config
  check (`xcrun dyld_info -uuid -exports`, then static `lldb disassemble`
  against a binary that links CoreGraphics; nothing runs).
- **Session scope only.** App scope strands displays after a force quit;
  permanent scope survives reboot. No scope reconnects a display when the
  process dies, so a separate helper owns recovery.
- Reconnect uses the display ID saved before disconnecting. A disconnected
  display usually disappears from the online list, so it can't be looked up.
- No retries. Completion consumes the transaction even on error.

## CLI

```sh
dp recovery disable --display UUID --consent-disable --timeout 15s
dp recovery status
dp recovery enable
dp recovery panic
```

- `disable` takes one display, explicit consent and a 1–60 second timeout. No
  `--all` and no indefinite mode.
- The command stays attached until the timeout. Exit, Ctrl-C or a killed parent
  ends it early, and the helper reconnects the display.
- `enable` and `panic` reconnect only the display recorded in the journal, even
  if it's offline. `status` only reads.
- All take `--journal <path>`. Exit 0 on success, 1 on refusal or failure, 2
  on bad arguments.

## App controls

**Settings → Displays → Full disconnect · Experimental** appears for the
selected display while Experimental features are on (or while a disconnect is
unresolved).

1. Show any hidden displays and resolve any recovery first.
2. Choose **Disconnect…**. DisplayPanel pauses automation and restores dimmed
   brightness.
3. Confirm you're present, a named display stays usable, and you accept manual
   recovery. Consent expires after 30 seconds and covers one 15-second
   disconnect.
4. The display reconnects at the deadline, or earlier with **Reconnect…**.
   Automation resumes once reconnection is verified.

Main and built-in displays are refused. **Reconnect…** stays available after
relaunch, with the display absent, and with Experimental features off.
Scripts, rules, startup and wake never disconnect a display.

## Turn off

The **Turn off** [Hide style](display-hide-ux.md#turn-off) uses the same
setter, but the display stays off until Show instead of a deadline. It shares
the public Hide journal, so it can coexist with displays removed by mirroring.

- Main displays are allowed; another usable physical display must stay on.
  Built-in, mirrored, hidden and mirror-source displays are refused, as are the
  driver, architecture, setter and awake checks below. One display at a time.
- The journal entry (`publicMirrorSession.disconnects`) is written before the
  setter runs:

  ```text
  turningOff ─ commit ─→ off ─ Show ─→ reconnecting ─ back ─→ restored
       └─ nothing written ─→ cancelled    └─ not back ─→ needsAttention
  ```

- macOS may apply its saved layout for the remaining displays, including a
  different main. Turn off gives main back with one public write and leaves
  the rest of that layout until Show. A turned-off main has no role to keep;
  macOS picks the next one.
- Show reconnects only the saved ID after the same exact identity checks,
  waits up to 10 seconds for the display to return, then restores its mode,
  position and main role (the whole saved layout when it's the last hidden
  display). It never retries.
- No helper or deadline. Wake, relaunch, quit and rules never turn a display
  off again. A display macOS reconnects itself is accepted; Show restores its
  layout without a private write.
- Logout or reboot ends it. Previous-session recovery offers only **Keep
  displays shown** when nothing else was removed.

### Trial: 26B123, 2026-11-07

Four external displays on Apple Silicon, nothing else hidden, one Turn off
and one Show per display. Each made one private write each way.

| Display | Turn off | Show |
| --- | --- | --- |
| Dell AW3423DW (main, no DDC) | Turned off; macOS picked another main | Back without the monitor's buttons; mode, origin and main role matched the capture taken before |
| DELL S2721DGF | Turned off, but macOS made another display main, so DisplayPanel reported "The display didn't turn off." (fixed above) | Back without the monitor's buttons |

Not tried live: Turn off alongside displays hidden by mirroring, app quit and
relaunch, display sleep and wake, and macOS reconnecting the display itself.
Fake-writer tests cover each.

## Safety checks

Every check reruns before each step. Any change cancels the operation.

| Required | Refused |
| --- | --- |
| Apple Silicon and a recognized macOS setter | Intel, unknown macOS builds |
| One external, physical, non-main target | Main, built-in, mirrored, virtual, headless |
| Another awake physical display stays usable | Only virtual, headless or DisplayLink displays left; closed lid |
| No mirroring | Any mirror |
| Only Apple display drivers | DisplayLink, virtual displays, third-party extensions |
| System, session and displays awake | Asleep or unknown |

Sleep, wake and display changes pause the operation; if it can't settle in 5
seconds, the journal is marked `needsAttention` instead of forcing a write.

### Identity

The display being reconnected must match the saved one exactly: vendor, model,
serial, connector, transport, boot session, OS build and user. Missing,
duplicate or changed evidence refuses. An offline display keeps its saved ID;
another ID is never substituted.

DisplayPanel can't detect an identical monitor swapped onto the same port, or a
reused display ID.

## Journal

```text
disabling ─ setter OK ─→ staged ─ final check ─→ commitStarted ─ complete ─→ disabled
    └──────── any failure: cancel ─────────┘
```

Every recovery path (deadline, exit, signal, `enable`, `panic`, relaunch) runs
the same steps:

```text
lock → reload journal → check identity → one reconnect → up to 6 checks → verified | needsAttention
```

- An interrupted reconnect is never repeated.
- If macOS reconnects the display itself (for example on wake), DisplayPanel
  accepts it and doesn't disconnect again.

## If it doesn't come back

1. `dp recovery status`, then `dp recovery enable`.
2. `dp recovery panic` (same checks, can't bypass a refusal).
3. Select the Mac's input with the monitor's buttons.
4. Log out or restart (not guaranteed to help).
5. Replug the cable, or try another port. A new port may give the display a
   new ID.

DisplayPanel never escalates automatically. Windows, Spaces, HDR and color are not
restored.

## Tests

Tests use fake writers and never call the private setter:

```sh
swift test --disable-sandbox --filter 'Recovery|DisplayTurnOffTests'
swift test --disable-sandbox --filter RecoveryProductionProviderTests   # read-only checks on this Mac
```

Out of scope: DDC power as a fallback, link stop/start, permanent scope,
scanning for IDs, and automatic logout or reboot. See the
[tool survey](display-disable-tool-survey.md) for how other apps do this.
