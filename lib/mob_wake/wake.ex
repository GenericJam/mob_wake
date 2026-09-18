defmodule Mob.Wake do
  @moduledoc """
  Public dispatch surface for `mob_wake`.

  This module is what user code touches: `register/3` to register a
  handler dynamically, `schedule/2` to enqueue a wake fire, `dispatch/1`
  for the native side to call when the OS fires, and `status/1` /
  `pending/0` for observability.

  See `MobWake`'s @moduledoc for the honest-reliability discussion,
  configuration format, and cross-references to `mob_push` /
  `mob_background`.

  ## Handler contract

  Handlers are functions the plugin invokes when the OS wakes us.
  Signature:

      def my_handler(payload_or_nil), do: :ok | {:error, reason}
      # or with extra_args baked in at registration time:
      def my_handler(extra_arg_1, extra_arg_2, ..., payload_or_nil), do: ...

  * The payload is `nil` for scheduler triggers (`:refresh`,
    `:processing`) and a `map` for `:push` triggers (the APNs / FCM
    message body).
  * Returning `:ok` tells the native side to mark the task successful
    (`setTaskCompleted(success: true)` / `Result.success()`). iOS's
    opportunistic scheduler learns from this — trust yourself to
    the truth.
  * Returning `{:error, :retry}` on Android maps to `Result.retry()`
    (WorkManager will attempt again). Any other `{:error, _}` maps to
    `Result.failure()` on Android and `success: false` on iOS.
  * A crash or timeout is mapped to `{:error, :crashed}` / `{:error,
    :timeout}` respectively — the OS is notified honestly.

  ## Trigger sources and timeouts

  Timeout enforcement runs on the Elixir side just below the OS's own
  window, so `dispatch/1` returns `{:error, :timeout}` before the OS
  force-kills us and mis-attributes the failure:

  | Trigger      | iOS window   | Android window | Elixir timeout |
  |--------------|--------------|----------------|----------------|
  | `:refresh`   | ~30s         | varies (WM)    | 25 s           |
  | `:processing`| ~10 min      | unlimited†     | 4 min          |
  | `:push`      | ~30s         | ~10s (FCM)     | 8 s            |

  † Under WorkManager's constraints; OEM battery killers may terminate
  sooner. `status/1`'s `:platform_signal` surfaces the signal.

  Overrideable per-call via `dispatch/1`'s options (see below).
  """

  alias Mob.Wake.Registry, as: WakeRegistry

  # :mob_wake_nif is defined by the platform NIF loaders (MOB-261 iOS,
  # MOB-263 Android). Until those land, the module doesn't exist at
  # compile time — silence the warning; `do_schedule/3` catches the
  # runtime :undef / :nif_not_loaded and reports :not_yet_implemented.
  @compile {:no_warn_undefined, :mob_wake_nif}

  # Elixir-side timeouts, matched to just below the platform windows so
  # we surface :timeout before the OS force-kills. See @moduledoc.
  # Overrideable via `config :mob_wake, :timeouts, [refresh: n, processing: n, push: n]`
  # — useful for the test suite (shortens the :timeout branch to sub-second)
  # and for apps that want to be more conservative than the defaults.
  @default_timeouts %{refresh: 25_000, processing: 240_000, push: 8_000}

  @doc """
  Register a task at runtime.

  Usually not needed — `config :mob_wake, :tasks` seeds the table at
  boot. Reach for `register/3` when a plugin needs to add its own
  handlers dynamically or for tests.

  * `trigger` — one of `:refresh`, `:processing`, `:push`.
  * `mfa` — `{module, function}` or `{module, function, extra_args}`.
    `extra_args` is prepended when the handler is invoked.

  Returns `:ok`.
  """
  @spec register(
          MobWake.identifier_t(),
          MobWake.trigger(),
          {module(), atom()} | {module(), atom(), [any()]}
        ) :: :ok
  def register(identifier, trigger, mfa)
      when is_atom(identifier) and trigger in [:refresh, :processing, :push] do
    validate_mfa!(mfa)
    WakeRegistry.put(identifier, trigger, mfa)
  end

  @doc """
  Schedule a wake fire.

  On iOS submits a `BGTaskScheduler` request; on Android enqueues a
  `WorkManager` request. `:push`-triggered identifiers cannot be
  scheduled locally — the wake comes from a server-sent APNs / FCM
  message; `schedule/2` on a `:push` identifier raises `ArgumentError`.

  ## Options

    * `:earliest` — a `DateTime` naming the earliest time the OS should
      consider firing this task. Maps to `BGTaskRequest.earliestBeginDate`
      on iOS and `setInitialDelay` on Android.
    * `:interval` — a `Duration` for `:processing`-triggered periodic
      work only. iOS accepts as a hint, Android as a hard interval floor.
    * `:constraints` — a keyword list: `charging: true`, `unmetered: true`,
      `idle: true`. Maps to `BGProcessingTaskRequest.requiresExternalPower`
      etc. on iOS and `Constraints.Builder` on Android. Not all
      constraints are honored on all platforms — check `status/1`.

  ## Return

  * `:ok` — request accepted by the OS.
  * `{:error, :not_yet_implemented}` — the NIF for this platform hasn't
    landed yet (MOB-261..264 in progress). Elixir-side registry state
    is unchanged.
  * `{:error, :unknown_identifier}` — nothing registered under that
    identifier.
  * `{:error, :cannot_schedule_push}` — attempted to schedule a
    `:push`-triggered identifier.
  * `{:error, reason}` — anything else the native side reported.
  """
  @spec schedule(MobWake.identifier_t(), keyword()) ::
          :ok | {:error, term()}
  def schedule(identifier, opts \\ []) when is_atom(identifier) do
    case WakeRegistry.lookup(identifier) do
      {:ok, {^identifier, :push, _mfa, _state}} ->
        {:error, :cannot_schedule_push}

      {:ok, {^identifier, trigger, _mfa, _state}} ->
        do_schedule(identifier, trigger, opts)

      :error ->
        {:error, :unknown_identifier}
    end
  end

  @doc """
  Dispatch a fire from the native side.

  Called by the platform-specific NIF when the OS wakes us. Looks up
  the identifier's registered MFA and invokes it inside a
  `Task.Supervisor` with a timeout matched to the trigger's platform
  window (see @moduledoc).

  Return values map to the native completion API — see @moduledoc's
  handler contract for the shape.

  ## Input

  * A bare `identifier` — scheduler firings pass this shape.
  * A `%{identifier: id, payload: payload}` — push firings pass this,
    where `payload` is the parsed APNs / FCM message body.

  ## Return

  * `:ok` — handler returned `:ok`. Silent-APNs completions map this to
    `UIBackgroundFetchResultNewData`; scheduler firings map to
    `setTaskCompleted(success: true)`.
  * `{:ok, :no_data}` — push-only convention: handler ran successfully
    but no new data resulted. Maps to `UIBackgroundFetchResultNoData`.
    Passed through from scheduler triggers as-is (they don't use it).
  * `{:error, :unknown_identifier}` — no MFA registered.
  * `{:error, :timeout}` — handler ran past the trigger's Elixir timeout.
  * `{:error, {:crashed, error}}` — handler raised.
  * `{:error, reason}` — whatever `{:error, reason}` the handler
    returned; `:retry` is honored on Android as `Result.retry()`.
  """
  @spec dispatch(MobWake.identifier_t() | %{identifier: MobWake.identifier_t(), payload: map()}) ::
          :ok | {:ok, :no_data} | {:error, term()}
  def dispatch(input) do
    {identifier, payload} = unpack_input(input)

    case WakeRegistry.lookup(identifier) do
      {:ok, {^identifier, trigger, mfa, _state}} ->
        WakeRegistry.update_state(identifier, %{
          state: :running,
          last_fired_at: DateTime.utc_now()
        })

        result = run_handler_with_timeout(mfa, payload, timeout_for(trigger))
        WakeRegistry.update_state(identifier, %{state: :idle})
        result

      :error ->
        {:error, :unknown_identifier}
    end
  end

  @doc """
  Current state for one identifier.

  Returns a map with keys:

    * `:state` — `:pending | :running | :idle`
    * `:last_fired_at` — `DateTime.t()` or `nil`
    * `:next_eligible_fire` — `DateTime.t()` or `nil`. The OS's own hint
      (not a guarantee); populated by MOB-267's `status/1` NIF
      enrichment.
    * `:platform_signal` — per-platform reliability info; empty map
      until MOB-267 lands. Then Android gets `%{battery_optimized:
      bool, work_state: term()}` and iOS gets
      `%{background_refresh_status: :available | :denied | :restricted}`.

  Returns `{:error, :unknown_identifier}` for an identifier that is not
  registered.
  """
  @spec status(MobWake.identifier_t()) :: map() | {:error, :unknown_identifier}
  def status(identifier) when is_atom(identifier) do
    case WakeRegistry.lookup(identifier) do
      {:ok, {^identifier, _trigger, _mfa, state}} -> state
      :error -> {:error, :unknown_identifier}
    end
  end

  @doc """
  Inventory of all pending fires.

  Returns a list of `%{identifier: id, trigger: t, state: s,
  last_fired_at: dt, next_eligible_fire: dt}` maps, one per registered
  task. Includes tasks in every state (`:pending`, `:running`, `:idle`)
  — the caller filters if they only want pending.

  The `:next_eligible_fire` field is populated by MOB-267; before that
  it is `nil` for every entry.
  """
  @spec pending() :: [map()]
  def pending do
    WakeRegistry.all()
    |> Enum.map(fn {id, trigger, _mfa, state} ->
      Map.merge(%{identifier: id, trigger: trigger}, state)
    end)
  end

  # ── internal ────────────────────────────────────────────────────────

  defp validate_mfa!({m, f}) when is_atom(m) and is_atom(f), do: :ok
  defp validate_mfa!({m, f, args}) when is_atom(m) and is_atom(f) and is_list(args), do: :ok

  defp validate_mfa!(other) do
    raise ArgumentError,
          "mob_wake register/3 expects {module, function} or {module, function, extra_args}; got #{inspect(other)}"
  end

  defp unpack_input(identifier) when is_atom(identifier), do: {identifier, nil}
  defp unpack_input(%{identifier: id, payload: p}) when is_atom(id), do: {id, p}

  defp timeout_for(trigger) do
    overrides = Application.get_env(:mob_wake, :timeouts, []) |> Map.new()
    Map.get(overrides, trigger, Map.fetch!(@default_timeouts, trigger))
  end

  defp run_handler_with_timeout(mfa, payload, timeout_ms) do
    task =
      Task.Supervisor.async_nolink(Mob.Wake.TaskSupervisor, fn ->
        invoke(mfa, payload)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} -> :ok
      {:ok, {:ok, :no_data}} -> {:ok, :no_data}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:error, {:unexpected_return, other}}
      {:exit, reason} -> {:error, {:crashed, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp invoke({m, f}, payload), do: apply(m, f, [payload])
  defp invoke({m, f, extra_args}, payload), do: apply(m, f, extra_args ++ [payload])

  # Native scheduler entry points. iOS NIF landed in MOB-261; Android
  # NIF lands in MOB-263. Until Android is up, the catch reports
  # :not_yet_implemented on that platform so callers see a clear signal
  # rather than a generic FunctionClauseError.
  #
  # The NIF expects the identifier as a binary — atoms don't cross the
  # native boundary as nicely (enif_get_atom with a small buffer is a
  # foot-gun for identifiers of arbitrary length). Convert once at the
  # seam.
  defp do_schedule(identifier, trigger, opts) do
    :mob_wake_nif.schedule(Atom.to_string(identifier), trigger, opts)
  catch
    :error, :undef -> {:error, :not_yet_implemented}
    :error, :nif_not_loaded -> {:error, :not_yet_implemented}
  end
end
