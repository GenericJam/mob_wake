# Changelog

All notable changes to `mob_wake` are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- Scaffold: `Mob.Wake` public API surface as stubs (real bodies land in MOB-260).
- Plugin manifest, mix.exs, workflows, pre-push hooks, formatter, credo strict config — mirroring the mob_sms 0.2.1 shape.
- ADR: single cross-platform plugin (not `mob_wake_ios` + `mob_wake_android`). See `decisions/2026-09-18-mob-wake-single-vs-split.md`.

### Not yet
- `Mob.Wake.register/2`, `schedule/2`, `dispatch/1`, `status/1`, `pending/0` all raise `not yet implemented` — MOB-260.
- iOS `BGTaskScheduler` NIF — MOB-261.
- iOS silent APNs receive NIF — MOB-262.
- Android `WorkManager` bridge — MOB-263.
- Android FCM data message bridge — MOB-264.
- mob_new template integration (config-driven codegen) — MOB-265.
- Push-relay reference implementation + docs — MOB-266.
- `Mob.Wake.status/1` platform-signal enrichment — MOB-267.
- Physical-device delivery verification harness — MOB-268.
- Coordination with `mob_push` (identifier schema, signing) — MOB-269.
