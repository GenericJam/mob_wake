defmodule Mob.Wake.Registry do
  @moduledoc """
  ETS-backed dispatch table for `mob_wake`.

  Owns the identifier → {trigger, mfa, state} table used by
  `Mob.Wake.register/2`, `Mob.Wake.dispatch/1`, and `Mob.Wake.status/1`.

  Reads go directly to ETS (public, read-concurrency on) so
  `dispatch/1` is fast on the hot path. Writes go through the GenServer
  so registration is serialised and can validate opts. State updates
  (`:last_fired_at`, `:state`) after each dispatch go through the
  GenServer too — one owner keeps the concurrent-write story simple.

  This module is `@moduledoc false`-adjacent — it's public for the
  plugin's own supervision tree but users should reach for `Mob.Wake`,
  not touch this directly.

  Seeded at start from `Application.get_env(:mob_wake, :tasks, [])` —
  the compile-time task table each host declares in `mob.exs`.
  """

  use GenServer

  require Logger

  # :mob_wake_nif is defined by the iOS/Android NIFs at build time (MOB-261
  # onwards). On host and iOS-below-13/Android-without-GMS the module is
  # absent — the wire-up below catches :undef and no-ops so tests + host
  # dev work fine.
  @compile {:no_warn_undefined, :mob_wake_nif}

  @table __MODULE__

  @typedoc """
  A registered task: `{identifier, trigger, mfa, state}`.

  * `identifier` — the atom the OS-side handler names when it fires.
  * `trigger` — `:refresh | :processing | :push`.
  * `mfa` — `{module, function}` or `{module, function, extra_args}`.
    `extra_args` is prepended to the invocation's dispatch payload.
  * `state` — mutable per-entry metadata (`:state`, `:last_fired_at`,
    `:next_eligible_fire`) updated after each dispatch.
  """
  @type entry :: {
          atom(),
          MobWake.trigger(),
          {module(), atom()} | {module(), atom(), [any()]},
          map()
        }

  # ── public API (called by Mob.Wake) ─────────────────────────────────

  @doc "Start the registry, seeding from `config :mob_wake, :tasks`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register or replace a task's identifier → MFA mapping."
  @spec put(atom(), MobWake.trigger(), {module(), atom()} | {module(), atom(), [any()]}) :: :ok
  def put(identifier, trigger, mfa) when is_atom(identifier) and is_atom(trigger) do
    GenServer.call(__MODULE__, {:put, identifier, trigger, mfa})
  end

  @doc """
  Look up a registered task.

  Direct ETS read — safe on the hot path from concurrent processes.
  Returns `{:ok, entry}` or `:error`.
  """
  @spec lookup(atom()) :: {:ok, entry()} | :error
  def lookup(identifier) when is_atom(identifier) do
    case :ets.lookup(@table, identifier) do
      [{^identifier, trigger, mfa, state}] -> {:ok, {identifier, trigger, mfa, state}}
      [] -> :error
    end
  end

  @doc "All currently registered tasks."
  @spec all() :: [entry()]
  def all do
    :ets.tab2list(@table)
    |> Enum.map(fn {id, trigger, mfa, state} -> {id, trigger, mfa, state} end)
  end

  @doc "Update a task's `:state`, `:last_fired_at`, `:next_eligible_fire` fields."
  @spec update_state(atom(), map()) :: :ok | {:error, :unknown_identifier}
  def update_state(identifier, changes) when is_atom(identifier) and is_map(changes) do
    GenServer.call(__MODULE__, {:update_state, identifier, changes})
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true
    ])

    seed_from_config()
    handoff_native()
    {:ok, %{}}
  end

  # Wire this GenServer to the native NIF as the dispatcher pid and
  # drain any wakes queued while BEAM was cold. Catches :undef when the
  # NIF isn't loaded (host, iOS-below-13, non-iOS in the interim before
  # MOB-263's Android side lands) — the Registry still boots.
  defp handoff_native do
    :mob_wake_nif.set_dispatcher_pid(self())

    :mob_wake_nif.take_pending_wakes()
    |> Enum.each(fn identifier ->
      send(self(), {:wake_fired, identifier_to_atom(identifier)})
    end)
  catch
    :error, :undef -> :ok
    :error, :nif_not_loaded -> :ok
  end

  defp identifier_to_atom(bin) when is_binary(bin), do: String.to_atom(bin)
  defp identifier_to_atom(atom) when is_atom(atom), do: atom

  @impl true
  def handle_info({:wake_fired, identifier}, s) when is_atom(identifier) do
    # Native BGTask fire (MOB-261). Dispatch under the task supervisor
    # so a slow handler doesn't back up further wake events.
    # `complete_task` feeds iOS's setTaskCompleted(success:); success
    # argument matches the honest-reliability discipline — iOS's
    # opportunistic scheduler LEARNS from these, so lying degrades
    # future fires.
    Task.Supervisor.start_child(Mob.Wake.TaskSupervisor, fn ->
      result = Mob.Wake.dispatch(identifier)
      success_atom = if result == :ok, do: :ok, else: :error
      complete_native(identifier, success_atom)
    end)

    {:noreply, s}
  end

  def handle_info({:push_fired, identifier_bin, push_id, payload_json}, s)
      when is_binary(identifier_bin) and is_binary(push_id) and is_binary(payload_json) do
    # Native silent-APNs fire (MOB-262). Payload is delivered as JSON
    # binary to keep mob_wake out of the JSON-library-dep business —
    # handlers decode with Jason / :json / their choice. dispatch's
    # return maps to UIBackgroundFetchResult via `complete_push`:
    #   :ok               → :new_data  (iOS learns push was worthwhile)
    #   {:ok, :no_data}   → :no_data   (routed but no new data fetched)
    #   {:error, _}       → :failed
    identifier = identifier_to_atom(identifier_bin)

    Task.Supervisor.start_child(Mob.Wake.TaskSupervisor, fn ->
      dispatch_result = Mob.Wake.dispatch(%{identifier: identifier, payload: payload_json})
      result_atom = push_result_atom(dispatch_result)
      complete_push_native(push_id, result_atom)
    end)

    {:noreply, s}
  end

  defp push_result_atom(:ok), do: :new_data
  defp push_result_atom({:ok, :no_data}), do: :no_data
  defp push_result_atom(_), do: :failed

  defp complete_native(identifier, success_atom) do
    :mob_wake_nif.complete_task(Atom.to_string(identifier), success_atom)
  catch
    :error, :undef -> :ok
    :error, :nif_not_loaded -> :ok
  end

  defp complete_push_native(push_id, result_atom) do
    :mob_wake_nif.complete_push(push_id, result_atom)
  catch
    :error, :undef -> :ok
    :error, :nif_not_loaded -> :ok
  end

  @impl true
  def handle_call({:put, identifier, trigger, mfa}, _from, s) do
    :ets.insert(@table, {identifier, trigger, mfa, initial_state()})
    {:reply, :ok, s}
  end

  def handle_call({:update_state, identifier, changes}, _from, s) do
    case :ets.lookup(@table, identifier) do
      [{^identifier, trigger, mfa, state}] ->
        :ets.insert(@table, {identifier, trigger, mfa, Map.merge(state, changes)})
        {:reply, :ok, s}

      [] ->
        {:reply, {:error, :unknown_identifier}, s}
    end
  end

  # ── seeding ─────────────────────────────────────────────────────────

  defp seed_from_config do
    Application.get_env(:mob_wake, :tasks, [])
    |> Enum.each(fn
      {id, mod, fun, trigger} when is_atom(id) and is_atom(mod) and is_atom(fun) ->
        :ets.insert(@table, {id, trigger, {mod, fun}, initial_state()})

      {id, mod, fun, extra_args, trigger} when is_atom(id) and is_list(extra_args) ->
        :ets.insert(@table, {id, trigger, {mod, fun, extra_args}, initial_state()})

      other ->
        # A malformed :tasks entry is a compile-time bug in the host's
        # mob.exs — log and skip so a boot doesn't hard-crash on a typo,
        # but the state is visibly bad when `Mob.Wake.pending/0` is
        # asked. The host's CI + our own credo run will catch typos
        # earlier; this is the runtime fallback.
        Logger.warning("mob_wake: ignoring malformed :tasks entry: #{inspect(other)}")
    end)
  end

  defp initial_state do
    %{
      state: :idle,
      last_fired_at: nil,
      next_eligible_fire: nil,
      platform_signal: %{}
    }
  end
end
