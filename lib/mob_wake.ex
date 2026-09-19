defmodule MobWake do
  @moduledoc """
  OS-triggered background execution for Mob apps.

  A cross-platform plugin for handlers the OS wakes on our behalf:

  * **iOS BGTaskScheduler firings** — `BGAppRefreshTask`, `BGProcessingTask`
  * **iOS silent APNs pushes** — `content-available: 1`
  * **Android WorkManager firings** — `OneTimeWorkRequest`, `PeriodicWorkRequest`
  * **Android FCM data messages** — high-priority, bypass Doze

  Same dispatch mechanism regardless of trigger source: a compile-time
  identifier → MFA table, the native side wakes the BEAM and RPCs into
  `Mob.Wake.dispatch/1`, we run to completion inside the platform's task
  window, native marks the task done.

  ## Which plugin do I actually want?

  The push/background/wake/notify quartet sits next to each other in the
  catalog and gets mixed up regularly. Four distinct concerns:

  | I want to…                                             | Plugin                                                            |
  |--------------------------------------------------------|-------------------------------------------------------------------|
  | **Send** a push from my server                         | [`mob_push`](https://hexdocs.pm/mob_push) (server-side; no device code) |
  | **Receive** a push token on the device and register it | [`mob_notify`](https://hexdocs.pm/mob_notify) (device-side)       |
  | Run a handler when the OS wakes my app opportunistically or via silent push | **`mob_wake`** (this plugin) |
  | Keep my app alive while the user is on another screen  | [`mob_background`](https://hexdocs.pm/mob_background) (silent-audio on iOS, foreground service on Android) |

  * **`mob_wake` vs `mob_background`:** wake is *event-driven* — the OS
    (or a silent push) fires a specific handler, it runs to completion,
    the platform reports done. Background is a *keep-alive* — the app
    stays running while backgrounded so *your own* code (an active
    upload, a walking tracker, a music player) can keep going. They
    stack: an app can use both, and often should.
  * **`mob_wake` vs the send side:** `mob_push` builds and sends the
    push; `mob_wake` receives and dispatches it on-device. Both
    coordinate on the identifier scheme so a task scheduled here can be
    triggered via push there without duplication (see `wake_payload/2`).
  * **`mob_wake` vs the scheduler API alone:** iOS's `BGTaskScheduler`
    is deliberately opportunistic — it fires when iOS decides the user
    is likely to open the app soon and the device has energy budget to
    spare. Do not treat it as cron. See the reliability story below.
    When timing matters, prefer a `:push`-triggered handler over a
    `:refresh` / `:processing` one.

  ## The honest reliability story

  Read this before writing anything the app depends on running on a
  schedule.

  ### iOS BGTaskScheduler is opportunistic

  No guaranteed schedule. iOS learns each user's usage pattern per-app and
  decides IF and WHEN to fire. Users who open the app once a week get
  almost nothing. Apple's own documentation is explicit: do not treat it
  as a schedule. It is the OS's guess at when the user will next look at
  your app anyway, offered as an opportunity to make that experience
  fresher.

  ### Android WorkManager delivers against constraints

  ...until the OEM battery-killer layer intervenes. Samsung's DeviceCare,
  Xiaomi's MIUI Autostart, Huawei's Protected Apps: all kill background
  work aggressively by default and users often need to manually whitelist
  the app for scheduled work to run at all. `Mob.Wake.status/1` surfaces
  the platform signal that says whether we've been suspended so the app
  can offer the user the "enable us in Battery Optimization" prompt.

  ### Silent push is the more reliable wake mechanism on both platforms

  APNs silent push (`content-available: 1`) fires
  `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`
  with a real ~30-second execution window. FCM data messages at priority
  `high` bypass Doze and call `onMessageReceived`. Both give the same
  execution model as the scheduler API, but the wake signal is "your
  server sent this exact push" instead of "the OS felt like it."

  When execution timing matters, prefer push over scheduler.

  ### iOS silent APNs — first-time setup prerequisites (MOB-271)

  The `mob_new` template ships the code side of push wired: the
  AppDelegate forwards the device token to Elixir via
  `mob_send_push_token`, the AppDelegate logs
  `didFailToRegisterForRemoteNotificationsWithError:`, the Info.plist
  declares `UIBackgroundModes.remote-notification`, and `mob_dev`'s
  codesign step calls `codesign --entitlements` with a file that mirrors
  `aps-environment` from the embedded provisioning profile.

  The out-of-band Apple Developer work stays on the host-app owner's
  plate. Do all three before expecting a push token to ever arrive:

    1. **Enable Push Notifications capability** on the App ID in Apple
       Developer Portal (Certificates, Identifiers & Profiles → App IDs
       → your app → Capabilities → Push Notifications).
    2. **Regenerate the provisioning profile** used for signing. Xcode
       may cache the old one; a "download all profiles" from Apple
       Developer settings, or a manual profile download, is the
       reliable path.
    3. **Provision an APNs authentication key (or certificate)** and
       configure `mob_push` on the send side with it. Without this the
       server can't send anything even if the device would receive it.

  Symptom when any of these three is missing: `MobNotify.register_push/1`
  succeeds silently, no `{:push_token, :ios, _}` message ever arrives
  at the calling process, and `MobPush.send/3` for that identity fails
  with `:device_token_not_found`. Look at the iOS system log (Xcode
  Console, `xcrun devicectl device console`, `idevicesyslog`) for the
  `[Mob] Failed to register for remote notifications:` line — the
  underlying `NSError` names which of the three is missing.

  ### Silent push — three device states (both platforms verified on hardware)

  For a `:push`-triggered handler, the wake fires end-to-end when the
  app is in one of the first two states below; the third state is a
  documented drop-through-no-fault-of-mob_wake. Verified 2026-09-19 on
  a Moto G Power 5G 2024 (Android FCM data messages) and an iPhone SE
  3rd-gen (iOS silent APNs, sandbox environment):

  | Device state              | Silent-push wake result                                   |
  |---------------------------|----------------------------------------------------------|
  | **Foreground**            | Handler runs immediately. Verified 0 → 2 (two consecutive fires bumped a persisted counter). |
  | **Backgrounded** (home button / another app on top, BEAM alive or suspended) | Handler runs — the primary use case mob_wake exists for. iOS specifically: BEAM may already be suspended when the push arrives; iOS wakes it long enough for the completion handler, then re-suspends. Verified via a DETS counter that only the on-device handler writes — pulled off the device with `xcrun devicectl device copy from`. |
  | **Force-stopped** (Settings → Force Stop / user swipe from recents on some Android launchers / user swipe-up-off-top-of-recents on iOS) | Wake is **dropped**. Both platforms refuse to deliver silent pushes to a user-terminated app: FCM (Android) queues as `FcmRetry` and does not deliver even after the user relaunches; APNs (iOS) treats a force-quit app the same. This is Google's and Apple's design; mob_wake cannot work around it. |

  ### Cold-start-via-push on Android — the rarer failure mode

  A wake that arrives while BEAM is dead (not force-stopped — Android
  killed the BEAM process for memory / OEM battery reasons but the
  app itself is not force-stopped) causes Android to relaunch the app
  process just to run `FirebaseMessagingService`. In that state:

    * The Kotlin `MobWakeBridge` class is loaded (JVM sees the class
      via the DEX) but its `native` methods have no JNI implementation
      — the mob native library is loaded from `mob_boot_runtime()` on
      Activity start, and there is no Activity in a service-only
      relaunch.
    * A naive `MobWakeBridge.onPushFired` call throws
      `UnsatisfiedLinkError` on `nativeDeliverPush`, which crashes the
      service and makes Android keep retrying it.

  The host app's `MobFirebaseService` — which is where FCM messages
  actually land, because Android only allows one service registered
  per `com.google.firebase.MESSAGING_EVENT` — must catch
  `java.lang.reflect.InvocationTargetException` around the reflective
  call and swallow it. The wake is lost (this cold-start-into-service
  case is a real limitation; loading the native library from the
  service side is a mob-framework change, not a plugin change), but
  the service stays alive and subsequent visible-push deliveries via
  mob_notify continue to work.

  See `MobFirebaseService.kt` in mob_new's Android template (or in a
  hand-wired host app) for the exact catch pattern; commit `b040949`
  in `~/code/sloppy_joe` is the reference implementation.

  ### Direction of travel

  Since ~2015 both platforms have been moving away from scheduled
  polling and toward event-driven wake. `BGTaskScheduler` won't go away
  — too much ecosystem depends on it — but each release makes it more
  discretionary. WorkManager gets tighter constraints each Android
  release. Push gets more capable each release. Design accordingly.

  ## Configuration

  Task table lives in the host app's `mob.exs` (compiled-in, not runtime
  config):

      config :mob_wake, tasks: [
        {:sync_notes,   MyApp.BackgroundJobs, :sync_notes,   :refresh},
        {:cleanup,      MyApp.BackgroundJobs, :cleanup,      :processing},
        {:on_new_peer,  MyApp.BackgroundJobs, :handle_peer,  :push}
      ]

  The fourth element is the *trigger source*:

  * `:refresh` — iOS `BGAppRefreshTask` / Android `OneTimeWorkRequest`.
    Short (~30s), meant for content refresh.
  * `:processing` — iOS `BGProcessingTask` / Android `PeriodicWorkRequest`
    with charging + unmetered constraints. Longer (~10 min iOS,
    unlimited Android under constraints), meant for heavier housekeeping.
  * `:push` — iOS silent APNs / Android FCM data message. Execution
    window ~30s. Wake signal comes from a server (see `mob_push` for the
    send side).

  This table drives:

  * The Info.plist / AndroidManifest.xml codegen at build time
    (mob_new integration, MOB-265)
  * The runtime dispatch table `Mob.Wake` uses to route incoming
    OS-fired events to the right MFA

  ## Public API

  All under the `Mob.Wake` namespace — see that module's @moduledoc for
  full contract:

  * `Mob.Wake.register/2` — usually called from generated boot code
  * `Mob.Wake.schedule/2` — enqueue a fire (`BGTaskScheduler.submit` on
    iOS, `WorkManager.enqueue` on Android)
  * `Mob.Wake.dispatch/1` — called by the native side when the OS fires
  * `Mob.Wake.status/1` — health signals per identifier, including
    platform-specific reliability signals
  * `Mob.Wake.pending/0` — inventory of pending fires

  ## Requirements

  * mob `~> 0.9.1`
  * iOS: BackgroundTasks + UserNotifications frameworks (declared in the
    plugin manifest). BGTaskScheduler identifiers land in Info.plist
    from mob_new codegen based on `config :mob_wake, :tasks`.
  * Android: WorkManager available in every recent AndroidX. FCM data
    messages need `google-services.json` in the app (see mob_push docs
    for the receive-side setup).
  """

  @typedoc "A task identifier — the atom used in `config :mob_wake, :tasks` and referenced by `Mob.Wake.schedule/2` / `Mob.Wake.dispatch/1`."
  @type identifier_t :: atom()

  @typedoc "A trigger source — decides which native API delivers the fire."
  @type trigger :: :refresh | :processing | :push

  @typedoc "A registered task: identifier plus the MFA the plugin invokes when the OS fires."
  @type task_entry :: {identifier_t, module(), atom(), trigger()}

  @doc """
  Build a `mob_push`-shaped payload that will fire `mob_wake` on the
  receiving device.

  The convention (see `decisions/2026-09-18-identifier-and-payload-schema.md`):

  * iOS: `content_available: true` + top-level `mob_wake_id` in the data
    map. Silent APNs on the device routes on `userInfo["mob_wake_id"]`.
  * Android: FCM data-only message with `mob_wake_id` in the data map.
    Same key — the `mob_push` library sends the identical shape to both
    sides.

  ## Example

      # Server-side (Elixir; wherever you fan out pushes)
      payload = MobWake.wake_payload(:sync_notes,
                                     data: %{"peer" => "abc"})

      MobPush.send(ios_token, :ios, payload)
      MobPush.send(android_token, :android, payload)

  Handlers on the device receive `{:change, :sync_notes, payload_json}`
  as usual — the payload arrives as a JSON binary; decode with Jason /
  `:json` if you want a map.

  ## Options

    * `:data` — a map of additional top-level keys merged into the
      payload. `mob_wake_id` is always set to the identifier and
      overrides any conflicting key.
    * `:title`, `:body` — visible on iOS (APNs requires them at the
      `alert` layer; `mob_push` currently sends both regardless).
      Defaulted to a single space each so a truly-silent push doesn't
      surface visible copy. Override to send a hybrid visible+silent
      push.
  """
  @spec wake_payload(identifier_t, keyword()) :: map()
  def wake_payload(identifier, opts \\ []) when is_atom(identifier) do
    data =
      opts
      |> Keyword.get(:data, %{})
      |> Map.put("mob_wake_id", Atom.to_string(identifier))

    %{
      title: Keyword.get(opts, :title, " "),
      body: Keyword.get(opts, :body, " "),
      content_available: true,
      data: data
    }
  end
end
