defmodule MobWake.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  One read-only native call, no UI, nothing scheduled: `:mob_wake_nif.platform_signal/0`.

    * **iOS** — the Objective-C NIF reads
      `UIApplication.backgroundRefreshStatus` on the main thread and answers
      `%{background_refresh_status: :available | :denied | :restricted}`.
      Any of the three passes: the answer can only come from the linked NIF
      asking UIKit. `:denied` / `:restricted` are the user's or MDM's
      Background App Refresh setting, not a plugin fault.
    * **Android** — the Zig NIF calls the Kotlin
      `MobWakeBridge.platformSignal()` over JNI and answers
      `%{battery_optimized: boolean, has_context: boolean}`. It passes only
      with `has_context: true`: that proves the NIF is linked, the bootstrap
      ran `MobWakeBridge.register()` (the JNI class + method IDs are cached)
      and handed the bridge the app context (`setActivity/1`), which is what
      `Mob.Wake.schedule/2` needs to reach WorkManager. `battery_optimized` is
      the user's battery setting either way.
    * `has_context: false` fails: the bridge never got a context, so
      scheduling can't reach WorkManager in this host.
    * `{:error, :bridge_not_registered}` (Android: `register()` never ran or
      the `platformSignal` method-ID lookup failed) and
      `{:error, :no_jni_env}` fail.
    * The other platform's map, an empty map, or anything else fails.

  The host stub's `nif_not_loaded` is a failure. Nothing here needs
  hardware or the user, so the test never skips.
  """
  @behaviour Mob.Plugin.SelfTest

  @ios_statuses [:available, :denied, :restricted]

  @impl true
  def run(%{platform: platform}) do
    classify(platform, :mob_wake_nif.platform_signal())
  catch
    :error, :nif_not_loaded ->
      {:fail, "mob_wake_nif is not linked into this build (nif_not_loaded)"}
  end

  @doc false
  # Maps platform_signal/0's native answer on `platform` to a self-test result.
  @spec classify(:ios | :android, term()) :: Mob.Plugin.SelfTest.result()
  def classify(:ios, %{background_refresh_status: status}) when status in @ios_statuses,
    do: :pass

  def classify(:android, %{battery_optimized: optimized, has_context: true})
      when is_boolean(optimized),
      do: :pass

  def classify(:android, %{battery_optimized: optimized, has_context: false})
      when is_boolean(optimized),
      do: {:fail, "MobWakeBridge has no app context (MobActivityAware.setActivity never called)"}

  def classify(:android, {:error, :bridge_not_registered}),
    do:
      {:fail,
       "Kotlin MobWakeBridge not registered (the plugin bootstrap never called MobWakeBridge.register(), or a method-ID lookup failed)"}

  def classify(:android, {:error, :no_jni_env}),
    do: {:fail, "platform_signal/0 could not get a JNIEnv on this thread"}

  def classify(platform, other) do
    {:fail,
     "platform_signal/0 on #{platform} returned #{inspect(other)}, expected #{expected(platform)}"}
  end

  defp expected(:ios), do: "%{background_refresh_status: :available | :denied | :restricted}"
  defp expected(:android), do: "%{battery_optimized: boolean, has_context: boolean}"
end
