# Hide and Show

Select a display in **Settings → Displays** and press **Hide**. The menu's
**Hide _display_** / **Show _display_** items and [scripts](#scripting) do the
same thing.

## Hide styles

| Style | What happens | How to choose it |
| --- | --- | --- |
| **Black out** (default) | A black window covers the display; its desktop stays put | Default, or `dp app hide --display UUID --style black-out` |
| **Remove from desktop** | The display [mirrors](display-mirroring.md) another, so windows move off it; optionally switches the monitor's input | Experimental features, then the display's **Remove from desktop** switch |

Neither style turns the monitor off or cuts its signal.

### Black out

The cover stays until Show, or Escape with the pointer on that display. Input
doesn't remove it. `--style black-out` forces this cover for one request, even
on a display set to **Remove from desktop**, without changing its settings. You
can black out several displays, but never the last visible one. Covers survive
sleep, wake and reconnects, and end on quit. Automation skips blacked-out
displays, and **Restore** doesn't show them.

### Keep windows off while hidden

| You want to | Use |
| --- | --- |
| Black out and leave windows alone | **Hide** (default) |
| Bring windows over once | An Action's **Move windows** step |
| Keep a blacked-out display clear | **Hide** with keep windows off |
| Stop using the display as desktop space | **Remove from desktop** (experimental) |

Keep windows off belongs to one blackout Hide, not to the display.

- **Settings → Displays → Windows → Also keep windows off** (default off) is
  remembered per display and applies to its next Hide from Settings, the menu
  or `app hide`.
- An Action's **Hide (black out)** step has its own option and ignores the
  remembered choice.
- While hidden, the **Keep windows off** switch pauses or resumes this Hide
  only. Show, a failed Hide and quit end it; relaunch never restores it.
- Automation rule blackouts never move windows, so a display they cover stays
  **Armed**. Remove from desktop doesn't need the option.

Choose **Automatic** (current main display, then stable UUID order) or one exact
destination. If that destination is asleep, disconnected, covered, mirrored,
removed or ambiguous, movement pauses instead of picking another.

While the Hide lasts, DisplayPanel rescans every second and moves new or returning
windows off the display, using the same rules as [Move windows](#named-manual-actions).
Windows that refuse or keep coming back are retried with backoff up to 30
seconds. The status reads **Armed** (on, not hidden), **Enforcing** (hidden and
moving windows) or **Paused** with a reason. Displays, the menu and the status
stream show it with the last moved and failed counts.

Sleep, display changes, losing permission, recovery or pausing cancel pending
moves. Show doesn't move windows back. Keep windows off never triggers Hide,
extends a blackout or counts as activity. See the
[window relocation contract](window-relocation.md) for timing bounds and
occupancy details.

## Experimental features

Turn on **General → Experimental features** and accept the prompt once. This
enables **Remove from desktop** with optional input switching.

Turning it off makes new Hides black out instead. Displays already removed stay
removed, and Show and recovery keep working.

### Remove from desktop

Turn on **Remove from desktop** for an external display, then set:

| Control | Meaning |
| --- | --- |
| **Mirror onto** | The display to mirror onto. Defaults to the main display; hiding the main display needs an explicit choice |
| **This Mac's input** | Detected over DDC (read-only) |
| **Switch monitor to** | Don't switch, a named input, or a custom input code |

```text
Hide: save layout → switch input (optional) → mirror
Show: restore layout → verify → switch input back (optional)
```

- Only awake external displays with a stable ID can be removed.
- You can remove several displays, in any order, onto shared or separate
  sources. A removed display can't be a source, and a source can't be removed
  until its targets are shown.
- Show returns one display and leaves the others removed. macOS may place it
  slightly off; the last Show restores the exact layout and main display.
- Hiding the main display lets macOS decide where the menu bar, Dock and
  windows go.
- Show restores layout and display modes, not HDR, color profiles, windows or
  Spaces.
- After sleep, or when a hidden monitor re-links to the Mac, DisplayPanel repairs
  lost mirrors and layout once without switching inputs or showing displays.
  Changed identities or failed checks leave the display in recovery. See
  [wake recovery](display-recovery.md#sleep-wake-and-reboot) and
  [input-return recovery](display-recovery.md#monitor-input-return-while-hidden).
- With **Don't switch**, Hide and Show send no DDC commands. Use the monitor's
  input button if needed.

### Full disconnect

**Full disconnect · Experimental** is a separate, manual action that drops the
Mac's signal using a private API. It is not a Hide style. It needs fresh
consent each time and reconnects automatically after 15 seconds. See
[private display disable](display-disable.md#app-controls).

## Arrangement protection

**Displays → Arrangement…** remembers a layout for each exact set of visible
displays, plus an optional preferred main display for unsaved sets. It is off by
default and corrects only after reconnect or wake, not your own layout edits.
Recovery suspends it. Each display's page also has a **Display mode** section for
[protected display modes](display-recovery.md#protected-display-modes). See
[remembered arrangements](display-recovery.md#remembered-arrangements) for
details.

## Named manual actions

**Automations → Actions** stores named workflows of 1–8 steps. Each step targets
a display with **Hide (black out)**, **Hide (remove from desktop)**, **Show** or
**Move windows**. **Restore arrangement** has no display target; put it before
steps that change the visible set. A display can appear once among Hide/Show
steps and once as a Move step, in either order. Hide never moves windows; Move
never changes Hide state.

```sh
dp app run-action --action ACTION_UUID --json
```

- Actions run only from **Run** or this command, never from rules, login or
  wake. `--style` doesn't apply to Actions.
- DisplayPanel checks every step first. A refusal names the step and changes
  nothing.
- Steps run in order. Disconnected targets and targets already hidden the other
  way are skipped with a reason. Other failures stop the run; earlier steps stay
  done.
- Ambiguous identities, unverified recovery and the last visible display still
  block.
- A Show-only Action can wait out an in-progress monitor input return (up to 15
  seconds), then check again and run once.
- A Remove step saves the display's setup. If that setup changes, review and
  save the Action again.
- A **Hide (black out)** step can **Keep windows off while hidden** with its own
  destination.
- **Move windows** moves ordinary windows on the display's current desktop once.
  It doesn't activate apps, switch Spaces or move windows back on Show.
  Full-screen, minimized and unmovable windows are skipped with reasons.
- Moving windows needs Accessibility permission, granted with **Allow
  Accessibility** in Displays or **Settings → Automations → Actions**. DisplayPanel
  never prompts on its own. Results give moved, skipped and failed counts;
  window titles aren't stored.
- Outcomes: `done` (finished, possibly with skipped steps), `no-op` (nothing to
  change) or `partial` (some steps changed, then the run stopped).

## Saved display identity

Saved settings follow a monitor across reconnects and restarts, even when macOS
gives it a new display ID. A match needs exactly one display with the same UUID,
vendor, model and serial; names and positions are never used. Duplicate or
changed identities stay blocked with a reason.

An Action captures display IDs when it starts; a connection change stops it
rather than picking new ones. Recovery journals are never moved to new IDs or a
new session. After reboot, recovery can archive the old journal and capture a
fresh baseline; it never replays the old operation.

## Rules and hidden displays

Automation rules never hide, show, mirror or switch inputs. Rules skip hidden
displays and keep running on the others. While a display is removed, rules use
a black window only: no DDC dimming, and **Sleep** becomes Restore.

## States

| Tile state | Meaning |
| --- | --- |
| On | Normal; Hide available |
| Hidden | Blacked out or removed; Show available |
| Hiding… / Showing… / Busy | In progress; no cancel or queue |
| Blacked out | An automation cover; **Restore** ends it |
| Asleep / Unavailable | Wake or reconnect the display |
| Mirrored | Mirrored outside DisplayPanel; fix in System Settings → Displays |
| Needs recovery | Read the reason; Show when allowed, or recover the previous session after reboot |

Removed displays stay listed even when disconnected. Reconnect the same
monitor, then **Check Again**. Recovery problems also appear as a banner and in
the menu as **Review Display Recovery…**.

After reboot, **Recover previous session** offers **Hide again** or **Keep
displays shown** for the whole previous Hide set. Both accept the current layout;
neither shows displays or switches inputs. Missing monitors must reconnect and
existing mirrors must be turned off first. See
[previous-session recovery](display-recovery.md#recovering-after-reboot).

If DisplayPanel can't confirm that dimmed brightness was restored, automation
pauses and **Retry Automation Cleanup** appears. It only restores saved
brightness.

## Results

Desktop and input results are reported separately on the selected display:

| Case | Desktop | Input |
| --- | --- | --- |
| Everything works | Hidden | Switched |
| Input can't be confirmed | Hidden | Check the monitor |
| No DDC | Hidden | Skipped; use monitor buttons |
| Input write fails | Not hidden | Failed, with a switch-back command |
| Mirroring fails after input switched | Failed; recovery offered | Switch-back command shown |
| Show: layout fails | Not restored; journal retained | May already have switched; outcome shown |
| Show: input fails | Restored only if fresh layout/mode checks pass | Failed |

Show switches the monitor back to the Mac first, then restores and verifies the
layout. A display coming online never triggers Show by itself. If a saved mode
is missing, the message names it; switch the input manually if DDC is
unavailable, then retry Show.

## Scripting

**Displays → Command** shows a copyable command for Stream Deck or Shortcuts:

```sh
/Applications/DisplayPanel.app/Contents/Helpers/dp app toggle-hide --display DISPLAY_UUID --json
```

Use `hide` or `show` for a specific state. Add `--style black-out` to `hide` or
`toggle-hide` to black out instead of removing, for that request only. The app
must be running. See [exit codes and status](usage.md#scripted-hide-and-show).

`app blackout-now` and the menu's Blackout Now item are retired. Use `app hide`
for one display, `app run-action` for a saved Action, or `app run-rule` (or the
menu's Run rule submenu) to run one Automation rule once.

## Keyboard

Cmd-, opens Settings; Cmd-1/2/3 switch tabs. In editors, Return saves and
Escape cancels. There is no global Hide hotkey.
