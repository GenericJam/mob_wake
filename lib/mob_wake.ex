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

  ## What this plugin is NOT

  * **Not `mob_background`** (already on Hex). That's the keep-alive
    pattern — silent-audio session on iOS, foreground service with
    notification on Android — for staying alive while the user is on
    another screen. Different lifecycle, different entitlements, different
    user-visibility rules.
  * **Not the send-side of push.** `mob_push` (in progress) is the *send*
    side of silent APNs / FCM. `mob_wake` is the *receive* side. Both
    coordinate on the identifier scheme so a task scheduled here can be
    triggered via push there without duplication.
  * **Not a replacement for the OS's own reasoning.** iOS's
    `BGTaskScheduler` is deliberately opportunistic — it fires when iOS
    decides the user is likely to open the app soon and the device has
    energy budget to spare. Do not treat it as cron. See the reliability
    story below.

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
