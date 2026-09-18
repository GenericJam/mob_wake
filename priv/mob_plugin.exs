%{
  name: :mob_wake,
  mob_version: "~> 0.9.1",
  plugin_spec_version: 1,
  # Description lives in mix.exs (Hex's source of truth). The plugin manifest
  # schema does not accept a top-level :description key today.
  #
  # No screens — mob_wake has no UI surface; it dispatches to the app's own
  # background handlers when the OS wakes us. A host app that wants to see
  # the wake state visually renders it themselves via `Mob.Wake.status/1`.
  screens: [],
  nifs: [
    # iOS: BGTaskScheduler + silent APNs receive (MOB-261 + MOB-262).
    # Compiled as ObjC (-fobjc-arc) via the plugin objc-NIF path.
    # Absent on non-iOS builds (platform: :ios). Android's WorkManager +
    # FCM NIF (MOB-263/264) will land as a separate zig NIF here.
    %{module: :mob_wake_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios}
  ],
  android: %{
    permissions: [
      # Post-only permission for a notification the app might raise from
      # inside a background handler (`Mob.Notify.local/1`). Not required
      # for the wake itself — WorkManager and FCM data messages need no
      # runtime permission. Keeping it here so mob_new's permission merge
      # surfaces it once, not per-app.
      "android.permission.POST_NOTIFICATIONS"
    ],
    gradle_deps: []
  },
  ios: %{
    frameworks: ["BackgroundTasks", "UserNotifications"],
    plist_keys: %{
      # BGTaskScheduler identifiers are listed in Info.plist under
      # BGTaskSchedulerPermittedIdentifiers. The scaffold declares NO
      # identifiers by default — the host app's `config :mob_wake, :tasks`
      # feeds mob_new codegen which writes the identifiers into
      # Info.plist at build time. Keep this map empty here so the plugin
      # itself contributes nothing until the host declares tasks.
      "UIBackgroundModes" => [
        # "fetch"          — BGAppRefreshTask (:refresh trigger source)
        # "processing"     — BGProcessingTask (:processing trigger source)
        # "remote-notification" — silent APNs (:push trigger source)
        # None of these are pulled in by default — the host's task table
        # decides which modes to add via mob_new codegen (MOB-265).
      ]
    }
  }
}
