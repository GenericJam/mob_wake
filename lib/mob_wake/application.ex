defmodule MobWake.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Owns the ETS table backing `Mob.Wake.Registry`. Seeded at start
      # from `config :mob_wake, :tasks` (compile-time constant); runtime
      # `Mob.Wake.register/2` adds to it.
      Mob.Wake.Registry,
      # Handler execution runs under this supervisor with a per-trigger
      # timeout. The Task.Supervisor is used rather than raw Task.async so
      # a crashing handler doesn't take down the caller (`Mob.Wake.dispatch/1`).
      {Task.Supervisor, name: Mob.Wake.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MobWake.Supervisor)
  end
end
