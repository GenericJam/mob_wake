# ADR: mob_wake as a single cross-platform plugin, not `mob_wake_ios` + `mob_wake_android`

**Date:** 2026-09-18
**Status:** Accepted
**Linear:** [MOB-258](https://linear.app/mobframework/issue/MOB-258)

## Context

Kevin's precedent has favoured per-platform libs for some plugins on the grounds that most apps target only one platform and would prefer the smaller dependency graph. Before starting the mob_wake scaffold, we needed to decide whether this plugin follows that split shape or the single cross-platform shape used by mob_camera / mob_location / mob_biometric.

## Decision

**Single cross-platform plugin.**

The plugin ships one Hex package (`mob_wake`) with per-platform NIFs, a single Elixir dispatch surface (`Mob.Wake`), and per-platform reliability signals surfaced via `Mob.Wake.status/1` rather than via a split API.

## Rationale

### Dispatch shape is genuinely identical across platforms

All four trigger sources — iOS BGTaskScheduler, iOS silent APNs, Android WorkManager, Android FCM data — reduce to the same shape at the Elixir seam:

    identifier → MFA table
    native handler wakes BEAM → Mob.Wake.dispatch/1
    Elixir runs to completion → native calls setTaskCompleted / Result.success

The differences live in the *setup* code (Info.plist entries vs AndroidManifest.xml + WorkerFactory registration), not in the dispatch code. A split package would duplicate the dispatch table implementation and force the host app to keep two parallel task-identifier lists in sync — the exact bookkeeping problem the plugin exists to remove.

### Reliability asymmetry belongs in `status/1`, not in the API shape

The honest-reliability story (iOS opportunistic, Android OEM battery killers, silent push more reliable than either scheduler) is real, and it must be visible to consumers. Making the API itself asymmetric ("use these functions on iOS, those on Android") hides the asymmetry inside build-time gates that read `Mix.target/0`. Making it visible through `status/1` returning platform-specific signals under the same key surface — `%{platform_signal: %{background_refresh_status: :denied}}` on iOS, `%{platform_signal: %{battery_optimized: true}}` on Android — puts the honesty in the runtime path where the app actually has to react to it.

### Silent-push receive belongs alongside scheduler triggers

If we split by platform we still have to decide where the push-receive code lives. It's the same "OS wakes us, we run to completion, we call setTaskCompleted" shape as BGTaskScheduler — the only difference is the wake signal source. Keeping it in `mob_wake` alongside `:refresh` / `:processing` means `Mob.Wake.dispatch/1` is the one entry point for OS-triggered execution, whether the trigger was scheduled locally or arrived from a server.

### Consistency with the rest of the plugin family

`mob_camera`, `mob_location`, `mob_biometric`, `mob_video`, `mob_screencast`, `mob_touch`, `mob_midi`, `mob_bluetooth` — all cross-platform. mob_sms 0.2.1 (published today) — cross-platform. The one existing per-platform-split precedent lives outside the OS-integration plugin family; the pattern for OS integrations here is single cross-platform, and mob_wake fits that pattern cleanly.

### Small-graph consumers still get most of the benefit

An iOS-only host targeting only iOS will pull in `mob_wake` and its dev/test deps but zero Android bytecode — the Kotlin bridge and Android NIF are gated on `platform: :android` in the manifest and skipped by the host's build. The download-size delta between a split `mob_wake_ios` and the single `mob_wake` is a few kilobytes of Elixir source. The delta of NOT having to teach every user "which of the two variants am I after" is bigger.

## What we're giving up

* An Android-only OEM-battery-killer regression can delay a release that iOS users don't need. Mitigation: iOS-only fixes still ship as patch releases; Android-only regressions get triaged like any other cross-platform gotcha and the plugin doesn't hold up iOS releases waiting on the Android side.
* A user who only ever wants push-receive still pulls in the scheduler code paths. Mitigation: the code paths are small and the module docs explicitly steer push-only users toward `:push` triggers.

## Consequences

* `mob_wake` ships as a single Hex package with per-platform NIFs.
* `Mob.Wake` is the single public API surface. Doctests + module docs live there.
* `Mob.Wake.status/1` surfaces platform-specific reliability signals under a single `:platform_signal` key so the honest-reliability story is programmatically inspectable, not just documented.
* If we ever hit a case where the split makes sense (an Android-only bytecode graph blowup, a licensing constraint on the Google Play Services SMS Retriever style), we revisit. Nothing about this decision is irreversible.
