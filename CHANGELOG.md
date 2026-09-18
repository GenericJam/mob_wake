# Changelog

All notable changes to `mob_wake` are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

Nothing yet — next in flight is MOB-261 (iOS BGTaskScheduler NIF).

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
