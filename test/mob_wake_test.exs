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
end
