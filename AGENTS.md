# Agent workflow

## Backlog

This repository uses native `bl` in `backlog/` as the authoritative task
source. Install the pinned CLI with `mise install`; invoke it as
`mise exec -- bl`. Read `mise exec -- bl instructions overview` and
`mise exec -- bl instructions workflow` before acting. Read and change tasks
only through `bl` (CLI or MCP); never edit task Markdown by hand. Reread each
task after writing it.

Pick and claim work in one step, with one stable session for the whole loop:
`mise exec -- bl next --claim --start --session SESSION --json`. A status
change is not a claim. Renew with `mise exec -- bl heartbeat --session SESSION`
before half the TTL. Keep backlog state on primary `main`, including when
implementation uses a worktree. Respect dependencies. Record each criterion's
command and result with `mise exec -- bl ac ID check N --evidence TEXT`, not
note lines; a status alone does not mean prerequisites or human gates are
satisfied. Finish with `mise exec -- bl done ID --session SESSION` only when
acceptance criteria and delivery evidence are met; if stopping incomplete, use
`mise exec -- bl release ID --session SESSION`. Do not push or open a PR
without explicit permission.

## Test selection

Start with `swift test --disable-sandbox --filter '<Suite>.<test>'` (or the
smallest affected suite); expand only for shared behavior or integration risk.
Do not repeatedly run the full suite for a focused fix. Native windows, menus
and sheets are skipped unless `DISPLAYPANEL_TEST_INTERACTIVE_UI=1`. Do not set that
flag for model/core changes. For changes requiring native interaction, get user
approval before presenting UI on their desktop, then opt in with a narrow
`--filter`; do not rerun focus-sensitive failures in a loop. CI opts in on its
dedicated runner. New tests that present UI must call `requireInteractiveUI()`
before setup; keep fake-backed model tests ungated. Fixture-output variables
alone do not enable interactive tests. See `docs/development.md`.

## Display-disable work

Read `docs/display-disable.md` for canonical direction and
`docs/display-disable-tool-survey.md` for evidence. Start with DP-1, bounded
offline ABI verification. The unadopted `recovery-enable`
research branch is preserved only as the tag `archive/recovery-enable`.

DP-1 through DP-8 authorize offline implementation/validation only, using
fake writers and no-write rehearsals. No private setter invocation (even enable
of an online display), live restoration trial, DDC write, or disruptive recovery
is authorized by a green test suite or task completion. DP-9 and DP-10 require
explicit scoped human approval before hardware writes. Preserve strict identity
refusal, unresolved journals and session-only transactions. Never guess IDs,
relax checks to unblock a trial, or silently escalate to logout/reboot.

Validation commands and opt-in no-write checks are in `docs/development.md` and
`docs/display-recovery.md`. Keep historical evidence separate from fresh results.
