# mob_wake

**Status: scaffold.** The public API contract is stable enough to code against but function bodies raise `not yet implemented` until the native trigger paths land. Follow [MOB-257](https://linear.app/mobframework/issue/MOB-257) for shipping order.

OS-triggered background execution for [Mob](https://github.com/GenericJam/mob) apps. Cross-platform surface (`Mob.Wake`), per-platform NIFs, one dispatch mechanism regardless of trigger source: a compile-time identifier → MFA table, native wakes the BEAM, we run to completion, native marks the task done.

## What this is (and isn't)

**Is:** handlers the OS wakes on our behalf.

* iOS `BGTaskScheduler` — `BGAppRefreshTask`, `BGProcessingTask`
* iOS silent APNs push — `content-available: 1`
* Android `WorkManager` — `OneTimeWorkRequest`, `PeriodicWorkRequest`
* Android FCM data messages — high-priority, bypass Doze

All four dispatch through the same `Mob.Wake.dispatch/1` entry point.

**Isn't:**

* Not `mob_background` (keep-alive pattern — silent-audio session on iOS, foreground service on Android). Different lifecycle, different entitlements, different user-visibility rules.
* Not the send-side of push. `mob_push` (in progress) handles the server-to-device push; `mob_wake` receives it. They coordinate on identifier schemes; they don't overlap.

## Read this before you commit to a background flow

**The reliability story is not what most people assume.**

* **iOS BGTaskScheduler is opportunistic.** No guaranteed schedule. iOS learns each user's per-app usage pattern and decides IF and WHEN to fire. Users who open your app once a week get almost nothing. Apple's docs are explicit: not a schedule.
* **Android WorkManager delivers against constraints...** until Samsung's DeviceCare, Xiaomi's MIUI Autostart, or Huawei's Protected Apps kill your background work. Default-on on all three. Users have to whitelist manually.
* **Silent push is the more reliable wake mechanism on both platforms.** APNs `content-available: 1` gives you a real ~30s window; FCM data at priority high bypasses Doze. When timing matters, prefer push over scheduler.
* **Direction of travel:** both platforms have been moving away from scheduled polling and toward event-driven wake since ~2015. Scheduler APIs won't disappear but they get more discretionary each release.

If your feature genuinely requires guaranteed periodic execution — accounting reconciliation, medical dose reminders — a background wake plugin is the wrong shape and you should be talking to a server-side scheduler with a push relay.

## Install (once shipped)

```elixir
def deps do
  [
    {:mob,      "~> 0.9.1"},
    {:mob_wake, "~> 0.1"}
  ]
end
```

In `mob.exs`:

```elixir
config :mob, :plugins, [:mob_wake]

# The task table drives both codegen (Info.plist, AndroidManifest.xml,
# WorkerFactory registration) and runtime dispatch.
config :mob_wake, tasks: [
  {:sync_notes,   MyApp.BackgroundJobs, :sync_notes,   :refresh},
  {:cleanup,      MyApp.BackgroundJobs, :cleanup,      :processing},
  {:on_new_peer,  MyApp.BackgroundJobs, :handle_peer,  :push}
]
```

Then write the handlers as normal functions:

```elixir
defmodule MyApp.BackgroundJobs do
  def sync_notes do
    # Runs when iOS BGAppRefreshTask fires or Android OneTimeWorkRequest fires.
    # Return :ok on success, {:error, term} on failure. The native side reads
    # the return value to call setTaskCompleted(success:) correctly, so iOS's
    # opportunistic scheduler learns to trust (or distrust) us for future fires.
    :ok
  end

  def cleanup, do: :ok

  def handle_peer(%{payload: payload}) do
    # :push-triggered handlers can accept a %{payload: _} map — that's the
    # APNs/FCM message body. Otherwise called with no args, same as
    # :refresh / :processing handlers.
    IO.inspect(payload)
    :ok
  end
end
```

## AppDelegate wiring (iOS, until MOB-265 codegen lands)

Until `mob_new`'s codegen (MOB-265) writes this automatically from your `config :mob_wake, :tasks` table, add the following to your generated `ios/AppDelegate.m`:

```objc
// Near the top of the file:
#import <BackgroundTasks/BackgroundTasks.h>
@interface MobWakeDispatcher : NSObject
+ (void)registerTaskWithIdentifier:(NSString *)identifier trigger:(NSString *)trigger;
@end

// Inside `application:didFinishLaunchingWithOptions:`, BEFORE `return YES;`:
if (@available(iOS 13.0, *)) {
  // One line per identifier in your `config :mob_wake, :tasks`. iOS
  // rejects registration attempted after `didFinishLaunching` returns.
  [MobWakeDispatcher registerTaskWithIdentifier:@"com.myapp.sync_notes" trigger:@"refresh"];
  [MobWakeDispatcher registerTaskWithIdentifier:@"com.myapp.cleanup"    trigger:@"processing"];
}

// For silent APNs (:push-triggered identifiers), also add:
- (void)application:(UIApplication *)application
    didReceiveRemoteNotification:(NSDictionary *)userInfo
        fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
  // mob_wake routes on the top-level "mob_wake_id" key in userInfo.
  // Your server's silent-push payload MUST include it (mob_push, when
  // shipped, will enforce this convention on the send side).
  [MobWakeDispatcher onPushFired:userInfo completionHandler:completionHandler];
}
```

And in your `Info.plist`, add each identifier to `BGTaskSchedulerPermittedIdentifiers`:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
  <string>com.myapp.sync_notes</string>
  <string>com.myapp.cleanup</string>
</array>
<key>UIBackgroundModes</key>
<array>
  <string>fetch</string>                 <!-- for :refresh triggers -->
  <string>processing</string>            <!-- for :processing triggers -->
  <string>remote-notification</string>   <!-- for :push triggers -->
</array>
```

For silent APNs, the server-side payload must include a top-level `mob_wake_id` key naming the identifier, plus `aps.content-available: 1`:

```json
{
  "aps": { "content-available": 1 },
  "mob_wake_id": "com.myapp.sync_from_peer",
  "peer": "abc"
}
```

`Mob.Wake.dispatch/1` will invoke the registered handler with the whole payload as a JSON binary — decode with `Jason.decode!/1` or `:json.decode/1` (Elixir 1.18+) in your handler if you want a map.

## Public API

Under the `Mob.Wake` namespace. Full contract in the module's @moduledoc.

* `Mob.Wake.register/2` — usually called from generated boot code
* `Mob.Wake.schedule/2` — enqueue a fire (BGTaskScheduler / WorkManager)
* `Mob.Wake.dispatch/1` — called by the native side when the OS fires
* `Mob.Wake.status/1` — health + platform-specific reliability signals
* `Mob.Wake.pending/0` — inventory of currently pending fires

## Related plugins

* [`mob_push`](https://github.com/GenericJam/mob_push) (in progress) — the *send* side of silent APNs / FCM. When you want deterministic wake timing, `mob_push` sends the trigger and `mob_wake` receives it. Identifier schemes coordinate.
* `mob_background` (already on Hex, 0.1.0) — the *keep-alive* pattern. Different concept, different lifecycle. Read its README if you're trying to decide which one you want.

## Cross-references

* [MOB-257](https://linear.app/mobframework/issue/MOB-257) — the mob_wake epic and its 12 children.
* [`decisions/2026-09-18-mob-wake-single-vs-split.md`](decisions/2026-09-18-mob-wake-single-vs-split.md) — why this is one cross-platform package, not two per-platform packages.

## License

MIT.
