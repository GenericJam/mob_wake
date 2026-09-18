# Changelog

All notable changes to `mob_wake` are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added — MOB-262 iOS silent APNs receive
- `mob_wake_nif.m` gains two entry points: `+onPushFired:completionHandler:` (ObjC, called from AppDelegate's `didReceiveRemoteNotification:fetchCompletionHandler:`) and `complete_push/2` NIF (Elixir → native → `UIBackgroundFetchResult` completion).
- Native `g_push_completions` table keyed by `NSUUID` string per push (multiple simultaneous pushes for the same identifier are supported, unlike BGTasks where one identifier maps to one fire in flight).
- APNs payload is serialised to a JSON binary via `NSJSONSerialization` and delivered to Elixir as-is — mob_wake doesn't take on a JSON-library dep, handlers decode themselves.
- Payload routing: top-level `mob_wake_id` key in userInfo names the identifier. Pushes without it get `.noData` back to iOS (so the opportunistic scheduler doesn't overinvest).
- `Mob.Wake.Registry.handle_info({:push_fired, id_bin, push_id, payload_json}, _)` — spawns dispatch under `Mob.Wake.TaskSupervisor` and maps result to `UIBackgroundFetchResult`: `:ok` → `.new_data`, `{:ok, :no_data}` → `.no_data`, `{:error, _}` → `.failed`.
- README AppDelegate snippet extended with the silent-APNs handler + `UIBackgroundModes` `remote-notification` + server-side payload shape.

### Known limitation
- Cold-start-via-push (BEAM not yet up when the push arrives) fails fast with `.failed` rather than queueing. Silent APNs has a ~30s completion window that would frequently miss a cold BEAM boot; failing fast lets the sender's server see the miss clearly. A follow-up can add push queueing with a native timer if the cold-start-via-push case turns out to matter for real workloads.

### Added — MOB-261 iOS BGTaskScheduler NIF
- `priv/native/ios/mob_wake_nif.m` — ObjC NIF wrapping `BGTaskScheduler`. Four entry points: `set_dispatcher_pid/1`, `take_pending_wakes/0`, `complete_task/2`, `schedule/3`.
- Native-side state (mutex-guarded, mirrors mob's `g_launch_notification_json` pattern): dispatcher pid, `BGTask*` table keyed by identifier, pending-wake queue for cold-start-into-background firings.
- `MobWakeDispatcher` ObjC class — `+registerTaskWithIdentifier:trigger:` for `AppDelegate` to call at `didFinishLaunchingWithOptions`; `+onTaskFired:` is the launchHandler forwarder.
- `Mob.Wake.Registry` init handoff: `set_dispatcher_pid(self())` + drains `take_pending_wakes()`, all catches-guarded so host + Android-only builds still boot cleanly.
- `Mob.Wake.Registry.handle_info({:wake_fired, id}, _)` — spawns a task under `Mob.Wake.TaskSupervisor` that runs `dispatch/1` and calls `complete_task/2` so iOS's `setTaskCompleted(success:)` reflects the true return.
- `expirationHandler` on every `BGTask` — if iOS cancels early we `setTaskCompletedWithSuccess:NO` and drop the reference under the mutex; no dangling task pointer.
- Manifest declares the ObjC NIF (`platform: :ios`, `lang: :objc`).
- README AppDelegate snippet — the hand-wired integration until MOB-265's codegen lands.
- 2 registry tests exercising the `{:wake_fired, id}` handler through `Task.Supervisor` on host (NIF absent, catches hold, dispatch runs).

### Notes
- Not physical-device verified yet — that's MOB-268's dedicated harness.
- `schedule/3` ignores the `opts` keyword list (TODO: parse `:earliest`, constraints on `:processing`). Marked in the NIF source.
- Android side (MOB-263/264) still absent; NIF calls from Elixir Registry catch cleanly on those builds.

## [0.1.0] - 2026-09-18

Scaffold + Elixir dispatch surface. The native trigger paths (MOB-261..264) aren't landed yet, so `Mob.Wake.schedule/2` returns `{:error, :not_yet_implemented}` — hosts can wire everything up on the Elixir side and dispatch from tests, but a real OS-fired wake needs the NIFs. Kept private on GitHub, deliberately not published to Hex, until at least one native trigger path is physical-device-verified.

### Added
- Scaffold shape mirroring mob_sms 0.2.1: mix.exs, LICENSE, .credo.exs, .formatter.exs, .gitignore, .githooks/pre-push, .github/workflows/{release,test}.yml, plugin manifest.
- `MobWake.Application` — supervision tree with `Mob.Wake.Registry` (ETS-backed) + `Task.Supervisor` for handler execution.
- `Mob.Wake.register/3(identifier, trigger, mfa)` — runtime registration; the compile-time `config :mob_wake, :tasks` entries seed the same table at boot.
- `Mob.Wake.dispatch/1(identifier | %{identifier: _, payload: _})` — invokes the handler inside `Task.Supervisor.async_nolink` with a per-trigger timeout (`:refresh` 25s, `:processing` 240s, `:push` 8s; overrideable via `config :mob_wake, :timeouts`). Returns `:ok`, `{:error, reason}`, `{:error, :timeout}`, or `{:error, {:crashed, _}}` for the native side to translate to `setTaskCompleted(success:)` / `Result.*`.
- `Mob.Wake.schedule/2(identifier, opts)` — Elixir-side plumbing complete; catches `nif_not_loaded` from the future `:mob_wake_nif` and returns `{:error, :not_yet_implemented}` cleanly. `:push` identifiers can't be scheduled (returns `{:error, :cannot_schedule_push}`).
- `Mob.Wake.status/1` + `Mob.Wake.pending/0` — Elixir-side state (`:state`, `:last_fired_at`); `:platform_signal` is `%{}` until MOB-267.
- ADR: single cross-platform plugin (not per-platform split). See `decisions/2026-09-18-mob-wake-single-vs-split.md`.
- `MobWake` module @moduledoc — the honest-reliability story lives here canonically (iOS opportunistic scheduler, Android OEM battery killers, silent push more reliable than either).
- 21 tests covering the whole surface (4 manifest-shape + 17 dispatch/register/schedule/status/pending).

### Not yet
- iOS `BGTaskScheduler` NIF — MOB-261.
- iOS silent APNs receive NIF — MOB-262.
- Android `WorkManager` bridge — MOB-263.
- Android FCM data message bridge — MOB-264.
- mob_new template integration (config-driven codegen) — MOB-265.
- Push-relay reference implementation + docs — MOB-266.
- `Mob.Wake.status/1` platform-signal enrichment — MOB-267.
- Physical-device delivery verification harness — MOB-268.
- Coordination with `mob_push` (identifier schema, signing) — MOB-269.
