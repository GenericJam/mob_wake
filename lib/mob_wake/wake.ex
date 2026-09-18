defmodule Mob.Wake do
  @moduledoc """
  Public dispatch surface for `mob_wake`.

  This module is what user code touches: `schedule/2` to enqueue a wake,
  `dispatch/1` for the native side to call when the OS fires, `status/1`
  and `pending/0` for observability.

  See `MobWake`'s @moduledoc for the honest-reliability discussion,
  configuration, and cross-references to `mob_push` / `mob_background`.

  ## Contract stubs

  The scaffold ships stubs — every function `raise`s a clear
  "not implemented until MOB-260" error. Real bodies land in the
  Elixir dispatch surface issue (MOB-260); the four native trigger
  paths (MOB-261..264) call into `dispatch/1` and `status/1` here.
  """

  alias MobWake

  @doc """
  Register an identifier → MFA at runtime.

  Usually called from generated boot code — `mob_new`'s codegen writes
  a `Mob.Wake.register/2` line per `config :mob_wake, :tasks` entry
  into the host's `Application.start/2` — but directly callable for
  dynamic registration (e.g. a plugin that registers additional
  handlers at boot).

  ## Not yet implemented

  Full implementation lands in MOB-260. Scaffold contract only.
  """
  @spec register(MobWake.identifier_t(), {module(), atom()} | {module(), atom(), [any()]}) ::
          :ok
  def register(_identifier, _mfa) do
    raise "Mob.Wake.register/2 is not yet implemented — see MOB-260"
  end

  @doc """
  Schedule a wake fire.

  On iOS submits a `BGTaskScheduler` request; on Android enqueues a
  `WorkManager` request. `:push`-triggered identifiers cannot be
  scheduled locally — the wake comes from a server-sent APNs / FCM
  message; `schedule/2` on a `:push` identifier raises `ArgumentError`.

  ## Options

    * `:earliest` — a `DateTime` naming the earliest time the OS should
      consider firing this task. On iOS this maps to
      `BGTaskRequest.earliestBeginDate`; on Android to `setInitialDelay`.
    * `:interval` — a `Duration` for `:processing`-triggered periodic
      work only. iOS accepts as a hint, Android as a hard interval floor.
    * `:constraints` — a keyword list of `:charging`, `:unmetered`, `:idle`
      booleans. Maps to `BGProcessingTaskRequest.requiresExternalPower`
      etc. on iOS and `Constraints.Builder` on Android. Not all
      constraints are honored on all platforms — see `status/1`.

  ## Not yet implemented

  Full implementation lands in MOB-260. Scaffold contract only.
  """
  @spec schedule(MobWake.identifier_t(), keyword()) :: :ok | {:error, term()}
  def schedule(_identifier, _opts \\ []) do
    raise "Mob.Wake.schedule/2 is not yet implemented — see MOB-260"
  end

  @doc """
  Dispatch a fire from the native side.

  Called by the platform-specific NIF when the OS wakes us. Looks up the
  identifier's registered MFA and invokes it inside a timeout
  supervisor. Returns `:ok` / `{:error, reason}` so the native side can
  call the platform's task-completion API correctly:

  * iOS: `BGTask.setTaskCompleted(success:)` — `:ok` → `success: true`,
    `{:error, _}` → `success: false`, so the OS's opportunistic
    scheduler learns the app can be trusted with future fires.
  * Android: `Result.success()` / `Result.retry()` / `Result.failure()`
    — same shape, retry semantics propagated through `{:error, :retry}`
    specifically.

  The input can be a bare identifier (scheduler firings) or a map
  including a `:payload` (push firings — the APNs/FCM message body).

  ## Not yet implemented

  Full implementation lands in MOB-260. Scaffold contract only.
  """
  @spec dispatch(MobWake.identifier_t() | %{identifier: MobWake.identifier_t(), payload: map()}) ::
          :ok | {:error, term()}
  def dispatch(_input) do
    raise "Mob.Wake.dispatch/1 is not yet implemented — see MOB-260"
  end

  @doc """
  Observability: current state for one identifier.

  Returns a map with keys:

    * `:state` — `:pending | :running | :idle`
    * `:last_fired_at` — `DateTime` or `nil`
    * `:next_eligible_fire` — `DateTime` or `nil` (the OS's own hint,
      not a guarantee)
    * `:platform_signal` — per-platform reliability info. On Android
      includes `%{battery_optimized: bool, work_state: term()}`; on iOS
      includes `%{background_refresh_status: :available | :denied |
      :restricted}`.

  Powers the honest-reliability observability story — an app can show
  the user "Background sync is disabled — enable Battery Optimization"
  based on this signal, so failures to fire aren't silent.

  ## Not yet implemented

  Full implementation lands in MOB-260 + MOB-267.
  """
  @spec status(MobWake.identifier_t()) :: map()
  def status(_identifier) do
    raise "Mob.Wake.status/1 is not yet implemented — see MOB-260, MOB-267"
  end

  @doc """
  Observability: inventory of all pending scheduled fires.

  Returns a list of `%{identifier: atom(), earliest: DateTime.t() | nil,
  trigger: MobWake.trigger()}` maps, one per pending fire currently
  known to the OS. Useful for the app's own settings screen ("here's
  what will fire when").

  ## Not yet implemented

  Full implementation lands in MOB-260.
  """
  @spec pending() :: [map()]
  def pending do
    raise "Mob.Wake.pending/0 is not yet implemented — see MOB-260"
  end
end
