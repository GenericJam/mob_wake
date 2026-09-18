# mob_wake — Agent Instructions

**Read [`AGENTS.md`](AGENTS.md) first**, then [`~/code/mob/AGENTS.md`](../mob/AGENTS.md) for the system view. Together they cover the plugin anatomy, the honest-reliability discipline, and the cross-repo work with mob / mob_dev / mob_push. This file goes deeper on Claude Code-specific workflow detail.

> **Keep AGENTS.md up to date** when you change dispatch behaviour, add a trigger source, or hit a new gotcha. Out-of-date guidance there causes wrong decisions downstream — fix it in the same commit, not in a follow-up.

## What this repo is

A cross-platform Mob plugin. One public surface (`Mob.Wake`), per-platform NIFs, an identifier → MFA dispatch table shared across four trigger sources: iOS `BGTaskScheduler`, iOS silent APNs, Android `WorkManager`, Android FCM data. Scaffold is live; the four native paths land per MOB-260..264.

## Worktrees

**Default assumption: work happens in a git worktree.** Kevin runs multiple agents in parallel; each task in its own worktree prevents conflicts.

If a task is assigned to you and worktree usage isn't mentioned, ask:

> "Should I use a worktree for this?"

Yes for anything non-trivial or that touches native code. In-place is fine for a single-file doc edit, one-line config change, or a version bump.

The git stash stack is shared across worktrees — never bare `git stash` / `git stash pop`.

## Pre-commit checklist

Before committing, run all in this order:

```bash
mix test                            # full suite must pass
mix format                          # apply formatting
mix credo --strict                  # whole tree, includes ExSlop
```

Pre-push hook adds format + credo strict + fast tests on every push. Activate once:

```bash
git config core.hooksPath .githooks
```

### Tests are part of the change

New behaviour ships with a test unless the change is small enough that a test would only restate it. The bar is: **would this test fail if the fix were reverted?** Check by reverting it.

For mob_wake specifically:

* Any code that manipulates the dispatch table needs a test that asserts routing to the right MFA.
* Any change to the timeout supervisor needs a test that a slow handler gets killed.
* Any docs change that names a fire cadence gets reverted (see honest-reliability discipline).

### Decision log — check both directions

Before committing, ask two questions:

**Does this need a new record?** Anything non-obvious: a tradeoff, a workaround, a convention. The commit message explaining a decision means that decision belongs in `decisions/` where it's findable.

**Does this INVALIDATE an existing record?** More dangerous half. A record asserting a property the code no longer has is worse than no record. Grep `decisions/` for the mechanism you are changing before you commit. Correct in place with a note about what was wrong, don't quietly delete.

### Adversarial review — before every non-trivial commit

Spawn a subagent, point it at the diff, tell it to find defects rather than approve.

Especially for this plugin:

* **Timeout supervisor semantics.** iOS gives ~30s for `:refresh` and ~10min for `:processing`; Android's window is different again. If the supervisor kills a handler at the wrong time, we mis-report completion to the OS and it learns to distrust our app for future fires.
* **`setTaskCompleted(success:)` return-value plumbing.** Elixir returns `:ok | {:error, _}`; native must translate correctly. Off-by-one on this is silent and cumulative.
* **`:push` identifier validation.** `schedule/2` on a `:push`-triggered identifier is nonsensical (the trigger comes from a server) — enforce with a clear `ArgumentError` at compile-time where possible, runtime otherwise.
* **Native-side re-entrancy.** BGTaskScheduler and FCM can fire twice for the same identifier if the app is slow. Dispatch must be idempotent or explicitly reject concurrent fires.

Skip only for: formatting, a typo, a version bump, a changelog edit.

### Before the merge — a second review, on the PR

Same as mob_sms. Give the reviewer the PR, what it claims, what you're least sure of, and ask for MERGE / DO NOT MERGE with reasons.

**Mechanical preconditions you check yourself:**

* CI is green AND the run is newer than the last commit.
* The branch is not behind master.
* The `mob` floor pin is a version that actually exists on Hex.

## Release flow

Canonical process in [`~/code/mob/RELEASE.md`](../mob/RELEASE.md). mob_wake specifics:

* `@version` in `mix.exs` is the trigger. Push it to master, `.github/workflows/release.yml` handles tag / GH-release / hex-publish, each step idempotent.
* The `mob` floor pin is load-bearing. Do not bump if the plugin uses a new mob feature that hasn't shipped yet.
* **Never ship without physical-device verification.** Simulators lie for this plugin — iOS Simulator doesn't run BGTaskScheduler on a realistic schedule; Android emulators don't have OEM battery killers so they mask the real reliability story. Kevin has both a Moto G Power 5G 2024 and an iPhone SE for device verification (see MOB-268).

## When you're flailing

Not a mob_wake-specific issue but worth mentioning here: the wake mechanisms are hard to instrument because the process may be dead when the fire arrives. Do NOT reach for `IO.puts` — the BEAM isn't up. Instrument by having the native handler write a timestamped line to `Application.app_dir(:mob_wake, "priv/wake_log")` before it boots the BEAM, and have the Elixir side log after `dispatch/1` returns. That gives you a clean before/after record even when nothing else is running.
