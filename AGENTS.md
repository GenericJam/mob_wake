# AGENTS.md — orientation for AI agents working on mob_wake

You're in **mob_wake**, a Mob plugin for OS-triggered background execution. The OS wakes us (iOS `BGTaskScheduler` firing, iOS silent APNs, Android `WorkManager` firing, Android FCM data message), we RPC into `Mob.Wake.dispatch/1`, we run to completion, native calls `setTaskCompleted` / `Result.success`.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view — mob's three-repo topology, plugin manifest schema, `Mob.Composite` / `Mob.Sigil`, how to drive a running app from your session, and the cross-cutting pre-empt-failure rules. This file is mob_wake-specific.

> **Keep this file current.** When you change dispatch behaviour, add a trigger source, or hit a gotcha that would trip the next agent, fix it here in the same commit — not in a follow-up.

## What mob_wake is, in one paragraph

A cross-platform plugin whose only surface is the `Mob.Wake` module. Compile-time identifier → MFA table from `config :mob_wake, :tasks`. Four trigger sources — `:refresh`, `:processing`, `:push` (with `:push` split into iOS silent APNs and Android FCM data at the native layer) — all reduce to the same shape at the Elixir seam: native handler wakes BEAM, RPCs into `Mob.Wake.dispatch(identifier | %{identifier: _, payload: _})`, we look up the MFA and invoke it inside a timeout supervisor, we return `:ok | {:error, reason}`, native uses that to call the platform's completion API correctly so the OS's own reasoning about "should I fire this app again?" gets the right signal. Scaffold is live; the four native paths land per MOB-260..264.

## What mob_wake is NOT

* **Not `mob_background`.** That's the keep-alive pattern (silent-audio session on iOS, foreground service on Android). Already on Hex 0.1.0. Different lifecycle. If you're reading this because you want to keep a background task alive while the user is on another screen, you want `mob_background`.
* **Not the send-side of push.** `mob_push` (in progress) sends silent APNs / FCM. `mob_wake` receives. They share an identifier scheme but do not share code.
* **Not a schedule.** iOS `BGTaskScheduler` is opportunistic. Read [MOB-257's description](https://linear.app/mobframework/issue/MOB-257) or `Mob.Wake`'s @moduledoc for the honest-reliability story. Do not write "this task fires every hour" in the docs. It doesn't and you will regret writing it.

## The honest-reliability discipline

This is the single most important thing to hold onto while working here. It is very tempting to write docs that make the plugin sound more reliable than the OS actually is. Don't.

* **iOS BGTaskScheduler:** opportunistic. Apple decides. Do not call it a schedule; call it an *invitation to refresh*. Never write a doc that describes a fire cadence.
* **Android WorkManager:** reliable against constraints, but OEM battery killers (Samsung, Xiaomi, Huawei) intervene by default. `Mob.Wake.status/1` surfaces the platform signal so the app can prompt the user to whitelist us. Docs must call this out.
* **Silent push:** more reliable than either scheduler. `content-available: 1` on iOS, `priority: high` data messages on Android. When execution timing matters, docs should steer the reader toward `:push`.

The rule of thumb: whenever a doc claims a task will run, ask yourself "even for a user who opens this app once a week?" If the honest answer is "maybe, or maybe not, depending on iOS's mood," the doc needs to say that.

## Anatomy of the plugin

* `lib/mob_wake.ex` — top-level @moduledoc + type aliases. Reliability story lives here canonically.
* `lib/mob_wake/wake.ex` — `Mob.Wake` public API. All function bodies raise until the corresponding MOB-260..267 issue lands.
* `priv/mob_plugin.exs` — plugin manifest. Declares `BackgroundTasks` + `UserNotifications` frameworks on iOS, `POST_NOTIFICATIONS` on Android, empty `screens` / `nifs`. `nifs` gets populated per MOB-261..264.
* `priv/native/ios/` — iOS NIF sources (MOB-261 + MOB-262). Objective-C, wraps BGTaskScheduler + `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`.
* `priv/native/jni/` — Android JNI NIF sources (MOB-263 + MOB-264). Zig, exports the bridge symbols the Kotlin side calls.
* `priv/native/android/` — Kotlin bridge (MOB-263 + MOB-264). Registers a `CoroutineWorker` for WorkManager firings + an FCM `MessagingService` subclass for data messages, both call into the NIF.
* `decisions/` — ADRs. Read `2026-09-18-mob-wake-single-vs-split.md` first.

## Cross-repo work

**mob (framework):** may need small changes to expose `Mob.Application.main_supervisor/0` or similar so `Mob.Wake` can supervise its dispatch table. Check with Kevin before adding cross-repo dependencies.

**mob_dev:** template + codegen work for MOB-265 lands here. `mob_new` needs to write:
* iOS: `BGTaskSchedulerPermittedIdentifiers` into Info.plist per `:tasks` entries whose trigger is `:refresh` or `:processing`. `UIBackgroundModes` gets `"fetch"`, `"processing"`, `"remote-notification"` set per trigger.
* Android: WorkerFactory registration in the generated Application subclass, plus `google-services.json` scaffolding for FCM.

**mob_push:** identifier-scheme coordination in MOB-269. A task table entry `{:on_new_peer, MyApp, :handle_peer, :push}` names the identifier `mob_push` uses to route incoming messages here. Do NOT invent a second registration mechanism; the `config :mob_wake, :tasks` list is the single source of truth.

## Testing

Elixir suite:

```bash
mix deps.get
MIX_ENV=test mix test
```

Coverage priorities (as issues land):
* Plugin manifest loads + validates via `MobDev.Plugin.{Manifest, Validator}`.
* `Mob.Wake.register/2` populates the dispatch table; `dispatch/1` routes correctly.
* Trigger-source enforcement (`:push` identifiers can't be `schedule/2`'d locally).
* `status/1` returns the expected shape for each state.
* Timeout supervisor kills a handler that exceeds the platform's window.

Physical-device verification (MOB-268) is the real test — the harness there is what proves iOS actually fires and Android's OEM layer isn't killing us.

## The pre-empt-failure rules that matter here

1. **Never write a doc that names a fire cadence.** iOS opportunistic, Android OEM-blockable. Say "up to once per hour when the OS deems appropriate" not "hourly."
2. **Return values matter.** iOS's opportunistic scheduler learns from `setTaskCompleted(success:)`. Returning `:ok` from a failed handler teaches iOS to trust us less than it should not. Fail fast, return `{:error, _}`, let iOS learn correctly.
3. **Don't call `Mob.Wake.dispatch/1` from tests without a task table.** The scaffold raises; MOB-260's real implementation needs a registered handler. Tests that pretend a handler was registered without going through `register/2` will hide real bugs.
4. **When adding a trigger source: think Info.plist / AndroidManifest first, dispatch second.** The Elixir seam is easy. The permissions + entitlements + `google-services.json` are where users get stuck.

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

## Related issues

* [MOB-257](https://linear.app/mobframework/issue/MOB-257) — this epic.
* [MOB-258](https://linear.app/mobframework/issue/MOB-258) — the single-vs-split ADR (done: `decisions/2026-09-18-mob-wake-single-vs-split.md`).
* [MOB-259](https://linear.app/mobframework/issue/MOB-259) — this scaffold.
* [MOB-260..269](https://linear.app/mobframework/issue/MOB-257) — the ten implementation + integration + verification issues.
