defmodule MobWakeTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("..", __DIR__)

  describe "plugin manifest — scaffold shape" do
    setup do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      %{manifest: manifest}
    end

    test "passes the pre-publish validator", %{manifest: m} do
      # Scaffold has no NIFs yet — MOB-261..264 add them per trigger source.
      # The validator's contract is the plugin loads cleanly with the
      # frameworks + permissions declared here; if that breaks, we want to
      # know before we start layering NIFs on top.
      assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
    end

    test "requires mob 0.9.1 or newer", %{manifest: m} do
      # mob 0.9.1 is the first release with the plugin manifest schema mob_wake
      # depends on. Older mobs don't validate our manifest shape.
      assert m.mob_version == "~> 0.9.1"
    end

    test "declares BackgroundTasks + UserNotifications frameworks on iOS", %{manifest: m} do
      # BackgroundTasks is the framework for BGTaskScheduler
      # (:refresh + :processing triggers). UserNotifications is needed for
      # local notifications the app might raise from inside a handler.
      # Both must be present at scaffold time so the iOS build won't fail
      # when the NIFs land in MOB-261/262.
      assert "BackgroundTasks" in m.ios.frameworks
      assert "UserNotifications" in m.ios.frameworks
    end

    test "declares POST_NOTIFICATIONS permission on Android", %{manifest: m} do
      # Notifications from inside a WorkManager handler need the Android
      # 13+ runtime permission. Not required for the wake itself; declared
      # here so mob_new's permission merge surfaces it once, not per-app.
      assert "android.permission.POST_NOTIFICATIONS" in m.android.permissions
    end
  end

  describe "MobWake.wake_payload/2 (MOB-269 identifier + payload contract)" do
    # These tests pin the ADR — decisions/2026-09-18-identifier-and-payload-schema.md.
    # If any of these fail without a matching ADR update, the receive-side
    # native code (userInfo["mob_wake_id"] / data["mob_wake_id"]) will
    # silently stop routing.

    test "sets top-level data.mob_wake_id to the identifier's string form" do
      p = MobWake.wake_payload(:sync_notes)
      assert p.data["mob_wake_id"] == "sync_notes"
    end

    test "sets content_available: true so both APNs silent + FCM data hit mob_wake" do
      p = MobWake.wake_payload(:whatever)
      assert p.content_available == true
    end

    test "merges caller :data alongside the mob_wake_id" do
      p = MobWake.wake_payload(:on_new_peer, data: %{"peer" => "abc", "count" => 1})
      assert p.data["mob_wake_id"] == "on_new_peer"
      assert p.data["peer"] == "abc"
      assert p.data["count"] == 1
    end

    test "overrides a caller-provided mob_wake_id — this key is ours" do
      # Deliberate — if a caller passes their own mob_wake_id, they've
      # confused the routing key with app-level data. Overriding rather
      # than raising is the pragmatic call.
      p = MobWake.wake_payload(:real, data: %{"mob_wake_id" => "hijack"})
      assert p.data["mob_wake_id"] == "real"
    end

    test "defaults title + body to a single space (mob_push requires both)" do
      # mob_push 0.2 pattern-matches title + body as required. A truly
      # silent push has visible content but the OS suppresses it under
      # content-available:1 + no user-facing alert body. This matches
      # what mob_push accepts today.
      p = MobWake.wake_payload(:foo)
      assert p.title == " "
      assert p.body == " "
    end
  end
end
