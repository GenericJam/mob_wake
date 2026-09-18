import Config

if Config.config_env() == :test do
  # Shrink the per-trigger timeouts so the timeout branch of
  # `Mob.Wake.dispatch/1` is testable in sub-second time. Production
  # windows are defined by the OS (see `Mob.Wake`'s @moduledoc).
  config :mob_wake, :timeouts, refresh: 200, processing: 200, push: 200
end
