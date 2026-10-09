defmodule MobWakeTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}
  alias MobWake.SelfTest

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

    test "declares the self-test, which passes the validator without a warning", %{manifest: m} do
      assert m.selftest == MobWake.SelfTest
      assert %{errors: [], warnings: warnings} = Validator.validate_plugin(m, @plugin_dir)
      refute Enum.any?(warnings, &(&1 =~ "selftest"))
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

  describe "MobWake.SelfTest" do
    defp assert_result(result) do
      assert Mob.Plugin.SelfTest.result?(result)
      result
    end

    test "on a host with no native library linked it fails, naming the NIF, instead of raising" do
      for platform <- [:ios, :android] do
        assert {:fail, reason} =
                 assert_result(SelfTest.run(%{platform: platform, device: :simulator}))

        assert reason =~ "mob_wake_nif is not linked"
        assert reason =~ "nif_not_loaded"
      end
    end

    test "iOS passes on every backgroundRefreshStatus the NIF can report" do
      for status <- [:available, :denied, :restricted] do
        assert :pass ==
                 assert_result(SelfTest.classify(:ios, %{background_refresh_status: status}))
      end
    end

    test "iOS fails on an unknown status, an empty map or the Android shape" do
      for answer <- [
            %{background_refresh_status: :bogus},
            %{},
            %{battery_optimized: false, has_context: true}
          ] do
        assert {:fail, "platform_signal/0 on ios returned " <> _} =
                 assert_result(SelfTest.classify(:ios, answer))
      end
    end

    test "Android passes once the bridge answered with an app context, whatever the battery setting" do
      for optimized <- [true, false] do
        assert :pass ==
                 assert_result(
                   SelfTest.classify(:android, %{battery_optimized: optimized, has_context: true})
                 )
      end
    end

    test "Android fails when the bridge never got an app context" do
      assert {:fail, "MobWakeBridge has no app context" <> _} =
               assert_result(
                 SelfTest.classify(:android, %{battery_optimized: false, has_context: false})
               )
    end

    test "Android fails when the NIF reports the bridge unregistered or no JNIEnv" do
      assert {:fail, "Kotlin MobWakeBridge not registered" <> _} =
               assert_result(SelfTest.classify(:android, {:error, :bridge_not_registered}))

      assert {:fail, "platform_signal/0 could not get a JNIEnv" <> _} =
               assert_result(SelfTest.classify(:android, {:error, :no_jni_env}))
    end

    test "Android fails on the pre-fix empty map, the iOS shape or an unexpected answer" do
      for answer <- [
            %{},
            %{background_refresh_status: :available},
            %{battery_optimized: :maybe, has_context: true},
            {:error, :map_build_failed},
            :ok
          ] do
        assert {:fail, "platform_signal/0 on android returned " <> _} =
                 assert_result(SelfTest.classify(:android, answer))
      end
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
