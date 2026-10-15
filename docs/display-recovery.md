# Display recovery

Before changing the display layout, PanelCtl saves it to a journal so it can
verify and restore it later. [Mirroring](display-mirroring.md),
[handoff](display-handoff.md), app Hide/Show and
[private disable](display-disable.md) share this journal.

## Commands

Run these from your logged-in desktop session.

| Command | Changes displays? | Effect |
| --- | --- | --- |
| `recovery status` | No | Print the journal and every removed display as JSON |
| `recovery verify [--display UUID]` | No | Check the current layout against the journal |
| `recovery capture` | No | Save the current layout |
| `recovery rehearse --timeout 5s` | No | Save, start the helper, verify at the deadline |
| `recovery restore [--display UUID]` | **Yes** | Restore one removed display (or a saved layout), then verify |
| `recovery guard --timeout 15s` | **Yes** | Save, then restore on deadline, exit or signal |

```text
~/Library/Application Support/PanelCtl/Recovery/current.json   # default --journal
```

- A custom journal's folder must be yours, mode `0700`, not a symlink.
- An unresolved journal blocks the next capture; verify or restore it first.
  Resolved journals are archived, never deleted.
- `--display` is required when more than one display is removed.
- Exit 2 for bad arguments, 1 for refusals or failures.

## Restore

```text
already matches → no-op
otherwise       → one write → up to 6 checks, 200 ms apart → verified | needsAttention
```

Restore refuses, without writing, when:

- displays are missing, extra or ambiguous, or an ID changed
- a display's hardware identity, connector, rotation or color profile changed
- the Mac rebooted, changed OS build or switched user
- a saved mode is no longer available

It never retries, guesses IDs, resets firmware, writes permanent configuration
or reboots. There is no force flag. Fix the cause by hand, then run
`recovery verify`. If the Mac rebooted, keep the old journal and use a new
`--journal` path.

If restore can't succeed, turn off mirroring in **System Settings → Displays**,
drag the menu bar back to the original display, then run `recovery verify`.

## Multiple removed displays

```sh
panelctl recovery status
panelctl recovery verify --display UUID
panelctl recovery restore --display UUID
```

Each removed display has its own entry. Restoring one leaves the others
removed. While others are removed, macOS may place it slightly off its saved
position; the last restore verifies the exact original layout and main display.
A display that needs attention blocks new removals until it's fixed.

## Sleep, wake and reboot

macOS may undo mirroring on wake and return an off-input monitor late, with a
changed main display or arrangement. The running app retains the set verified
hidden before sleep and waits up to 15 seconds for those displays to return.
If the original layout came back exactly, it mirrors the hidden displays again.
For a multi-display journal with layout drift, it reapplies the captured mirrors
and saved visible-display origins/main together in one session transaction.
It never switches inputs on wake. Follower modes are negotiated by mirroring;
a missing saved follower mode does not prevent re-hide, but still blocks Show
until that exact mode returns. The original layout and modes remain journaled.

Changed identities, unrelated mirrors, changed visible-display modes, interrupted
Show operations or failed verification remain in recovery. There is no write
retry, and explicit Hide/Show cancels pending wake resume. Resume requires intent
captured by this running app before sleep; relaunch never starts it. A monitor
that returns after the bounded window still needs explicit recovery. This path
is covered by fake-writer regressions; live monitor/driver acceptance and timing
remain hardware-validation limits.

A monitor on another computer's input may reconnect with a reduced mode list
(for example, 60 Hz instead of the saved 240 Hz). Explicit app **Show** or
`back --input` validates the captured identities, attempts the configured Mac
input once, waits for modes/topology to settle, then restores and verifies the
journaled desktop. This input-return path accepts online mirror followers that
macOS marks inactive; ordinary DDC controls remain active-only. Identity and
connector checks still apply, and the monitor must accept DDC on the Mac's link.
Returning to mirroring alone does not count as shown.
Without a configured return input, use the monitor's input button first.

If explicit **Show** arrives while the app is settling a monitor input return,
it waits for two quiet matching observations within that transition's original
15-second deadline, then revalidates and runs once. This applies to individual
Show (including `app show`) and saved Actions containing only Show steps for
journaled displays. It replaces pending background re-hide, not a failed write.
Other requests remain busy while it waits; mixed Actions and Toggle do not wait.
Actual sleep, unlock, app shutdown, changed identities/journal or an expired
window cancel the request without showing anything. A failure never replays the
request or retries a hardware write; the unresolved journal remains available.
Fresh normal Show checks still require the exact saved modes and identities.

This timing path is verified with fake-backed tests only; monitor/driver timing
and a live power-off/input-return trial still require separate approval.

Recovery reports the current identity, lifecycle or exact saved-mode blocker
rather than hiding it behind an earlier generic layout error. Failed restoration
retains the unresolved journal. An online display is not evidence that its Mac
input is selected and never causes automatic Show or an input write.

Hide is session-only: after logout or reboot, macOS loads its own layout. If
macOS brings back a mirror itself, PanelCtl shows that display as **Mirrored**;
turn off mirroring in System Settings → Displays.

## Monitor input return while hidden

While the app stays running, a hidden monitor returning to the Mac's input can
cause macOS to drop mirrors or shift the visible desktop without a Mac sleep.
PanelCtl preserves the last verified hidden set before inspecting that change.
Repair is on by default: after quiet notifications and two matching topology
samples, within a fixed 15-second window, it reapplies the hidden set and saved
visible origins/main together in at most one session transaction. Intact mirrors
with a shifted layout are repaired too; an already-correct layout is a no-op.
There are no DDC/input writes, automatic Shows or permanent configuration writes.

Attribution is conservative. A CoreGraphics **add (16)** or **remove (32)** flag
must name a captured hidden target or its source. Begin, mirror/unmirror, mode,
move, main, enabled/disabled and desktop-shape flags alone are not link evidence:
enable/disable can accompany manual unmirroring. Without add/remove evidence,
normal inspection still accepts an exact system restoration, including turning
off mirroring in **System Settings → Displays**. macOS cannot identify whether a
person or the system caused a re-link; a simultaneous manual change with link
evidence may therefore be repaired. No hidden session means no repair.

Callbacks received during app Hide/Show and the following one-second guard,
or queued across an operation boundary, cannot authorize repair. Sleep/wake owns
its lifecycle. Explicit Hide/Show cancels pending repair. Changed/ambiguous IDs,
a changed journal or baseline, unrelated mirrors, changed visible modes,
unrepresentable origins, interrupted operations, missing displays and unsettled
topology cause no write. A failed or unverified transaction stops without retry.
The journal is retained, and the display's result directs you to correct the
layout in System Settings and inspect recovery. A late return does not revive
expired intent; use explicit recovery. Settlement and the background automation
observer inspect without reconciling away journal intent or interruption evidence.

Per-display numeric flags, attribution/suppression and repair outcomes are in the
`display-reconfiguration` unified-log category. Observing this log is read-only:

```sh
log stream --level info --style compact --predicate 'subsystem == "com.brettinternet.panelctl" AND category == "display-reconfiguration"'
```

Fake-backed tests cover baseline restoration, lost/intact mirror drift, manual
unmirror, own notifications, timeout, changed identities/journals and failed
verification without feedback loops. **Hardware limit:** the reported monitor's
actual input-return flags and driver timing remain unverified. A return that emits
only mode/mirror/move flags is intentionally not repaired. Passive logging needs
no display writes; a live repair trial still requires separate scoped approval.
No live trial was performed for TASK-78.

## Protected display modes

Each display's page in **Displays** has a **Display mode** section; protection is
off by default for every display. Choose **Remember Current Mode**, then turn on
**Restore saved mode**. Remember captures the exact logical resolution, pixel dimensions (scale), refresh rate,
mode ID and flags. Identity is the saved-display rule: one matching UUID plus
vendor/model/serial; a numeric display address is rebound only from that identity.
Only **Remember Current Mode** or **Forget** replaces or removes a saved mode. Turning protection off keeps it. Ordinary System Settings edits stand and
never silently update the saved choice.

After reconnect/input return or wake, PanelCtl waits for stable inventory and
restores a differing exact mode once, before sampling the arrangement for
correction. The saved mode must appear in CoreGraphics' offered list, including
its ID and flags; no nearest resolution, refresh rate or scale is substituted.
A late mode can arrive within the original 15-second transition deadline, and
arrangement correction waits for it. At the deadline, protection reports the
unavailable mode (or other blocking reason) without writing it; arrangement
correction still gets its one attempt with the current sizes. A protected display
that is not connected does not delay arrangement correction; its own later
reconnect is a new transition. Protection does not apply on launch, even when
arrangement protection does.

Hidden and mirrored displays are skipped. An unresolved recovery journal suspends
mode protection; Hide/Show recovery keeps owning those modes. PanelCtl operations,
wake resume and hidden-display input-return repair suspend correction. Each write
holds the operation and default-journal locks, rechecks identity and topology at
staging and commit, uses a public session-only CoreGraphics transaction, and verifies
the resulting exact mode. A failed write or verification is reported and never
retried in that transition. Own-operation notifications cannot start another pass.
Results and refusal reasons appear beside the saved mode in Settings.

Rotation is not changed (the public mode setter does not set rotation). HDR,
color profiles, gamma, firmware and private display-enable setters are excluded.
Saved mode IDs may cease to be offered after a reboot or driver change; explicitly
remember the desired current mode again rather than allowing an approximation.

Hardware status: fake-backed tests cover reduced-mode input return, late/missing
modes, exclusions, ordering, lock and topology races, own notifications, and failed
verification. No live mode-write, monitor-input, wake or native Settings interaction
trial was performed for TASK-81; hardware behavior remains unverified.

## Remembered arrangements

**Displays → Arrangement…**, under the display tiles, is separate from recovery.
It covers every display, so it appears once rather than on each display's page.
Protection is off by default, as is **Also apply on launch**. **Remember Current
Arrangement** saves origins and the main display for the exact visible display set. Save each set you use separately,
for example three monitors and the two that remain when one is away. Remembering
requires at least two visible displays, no mirrors and no unresolved journal.
Only Remember updates a saved set. Forget removes it; turning protection off
keeps saved sets and the preferred main choice.

A **Preferred main display** is independent of saved sets. When a set has no saved
arrangement and that display is visible, PanelCtl makes it main by translating
all origins equally. Relative placement stays unchanged. A saved arrangement
always takes precedence, even if its geometry no longer matches. An absent or
hidden preferred main causes no change. PanelCtl never invents positions for an
unsaved set.

Protection waits for two matching samples after a CoreGraphics add/remove
notification (including a re-link) or a completed wake, within 15 seconds. Apply
on launch optionally starts the same settlement. Each transition allows one
attempt, followed by up to six verification reads. Failures are reported without
retry. Ordinary move, mode and main-display notifications do not start correction,
so a layout edit in System Settings is left alone. macOS cannot distinguish a
manual edit made during the same reconnect window from system drift.

**Restore** in the Arrangement sheet runs the same checks explicitly, even with
protection off. **Restore arrangement** is also a global Action step and a CLI
command through the running app.
It does not launch the app or retry a lost response.

```sh
panelctl app restore-arrangement --json
panelctl app status --json
```

Status reports `remembered`, `preferred-main`, `unprotected` or `suspended`, the
reason, whether the saved layout differs, and the last result. When it differs,
Remember Current Arrangement replaces that set with the new layout. Put Restore before Action
steps that change the visible set. Actions preflight every step and freeze the
arrangement plan; a later topology change stops the run rather than rebinding it.

Saved identities require exactly one matching UUID and identical vendor, model
and serial. A new numeric display ID is allowed between operations, never during
one. Resolution, HiDPI scale and rotation changes are tolerated using the current
logical sizes; PanelCtl does not restore modes or rotation. Remember also saves a
neighbor tree rooted at the saved main display. Each neighbor keeps its side and
top/left or bottom/right edge alignment; other alignments keep their top/left
offset in logical points. Equal-size alignment ties choose top/left. Neighbor
selection is deterministic (breadth-first, UUID order), not a guess about ports.
Older saves infer the same relationships from their saved geometry when needed.
Unchanged geometry uses the exact saved origins, including older unusual layouts.

Resized layouts must retain each selected shared edge, remain contiguous and
non-overlapping, and have integer origins in the CoreGraphics range. Disconnected,
overlapping or corner-only saved layouts cannot adapt. Large offsets or conflicting
branches can make a resized layout impossible; PanelCtl refuses with a reason
rather than moving displays arbitrarily or falling back to Preferred main. Extra
contacts outside the neighbor tree are not constrained. Remember Current
Arrangement can replace a refused layout. A mode change alone still does not trigger protection;
use Restore arrangement explicitly or wait for a reconnect/wake transition.
Duplicate or ambiguous identities are refused. If macOS swaps UUIDs between identical monitors
with no serial, PanelCtl cannot detect that swap and will not guess using ports,
names or positions. Show a blacked-out main display before remembering/restoring
an arrangement; it must belong to the visible set.

Unresolved journals, pending display operations, wake resume and hidden-input
repair suspend protection. The writer takes the shared operation and journal
locks, rechecks topology and identities immediately before completion, writes
only public CoreGraphics origins with session scope, and verifies the result.
It does not write modes, mirroring, private setters, DDC, permanent preferences,
windows or Spaces. Recovery journals are never overwritten by Remember.

**Hardware status:** TASK-79 and TASK-80 have fake-backed writer, lifecycle, CLI,
Action and resized-layout coverage only. Real reconnect/wake timing, input-return flags and CoreGraphics
layout acceptance remain unverified. No live arrangement trial was performed;
hardware writes still require separate scoped approval.

## Snapshot

| Saved | Not saved or restored |
| --- | --- |
| OS build, boot session, user, host model | HDR, variable refresh |
| UUID, display ID, vendor/model/serial | Color calibration |
| Main, active and built-in flags | DDC brightness, power or input |
| Mode, refresh rate, position, rotation (checked only) | Windows and Spaces |
| Mirror source | |
| Color space and ICC profile digests | |
| Connection and transport details | |

ICC profiles that differ only in their creation date (bytes 24–35) still match.

## Helper

`rehearse`, `guard` and private disable start a helper process that outlives
the command:

```text
parent: save journal → start helper → wait for READY
helper: lock journal → verify → arm deadline → READY
        … deadline, parent exit (even SIGKILL) or signal → verify (rehearse) | restore (guard)
```

The timeout is 1–60 seconds. The helper can't survive its own SIGKILL, logout,
reboot, or a hung WindowServer.

## Testing

```sh
swift test --disable-sandbox --filter DisplayRecoveryTests
```

Opt-in checks against a built CLI that never change displays (needs a desktop
session):

```sh
swift build --product panelctl
swift scripts/test-display-recovery.swift "$(swift build --show-bin-path)/panelctl"
```

The script covers capture, deadline verification, parent and helper signals,
lock contention and stale-boot refusal. It never runs `guard` or `restore`.
