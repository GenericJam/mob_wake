defmodule Mob.Wake.RegistryTest do
  # This suite exercises the Registry's native-side integration paths —
  # in particular the {:wake_fired, id} handler that the iOS NIF's
  # enif_send targets. The NIF is not loaded on host; the Registry's
  # catches let the code paths run cleanly here so the Elixir shape is
  # verified even without a device.
  #
  # `async: false` because the Registry is a named singleton.

  use ExUnit.Case, async: false

  defmodule TestHandlers do
    def report_and_ok(who, payload), do: send(who, {:report_and_ok, payload}) && :ok
  end

  describe "handle_info({:push_fired, id_bin, push_id, payload_json}, s)" do
    test "dispatches with the payload JSON binary as the handler arg" do
      # Silent-APNs wire delivers payload as a JSON binary (the NIF
      # NSJSONSerialization output). The Elixir side dispatches the
      # payload through unchanged — handlers Jason.decode! or :json.decode
      # themselves. This test asserts that arrival shape.
      id = :"push_dispatch_#{System.unique_integer([:positive])}"
      :ok = Mob.Wake.register(id, :push, {TestHandlers, :report_and_ok, [self()]})

      payload_json = ~s({"peer":"abc","count":1})
      push_id = "test-push-#{System.unique_integer([:positive])}"

      send(Mob.Wake.Registry, {:push_fired, Atom.to_string(id), push_id, payload_json})

      assert_receive {:report_and_ok, ^payload_json}, 500
    end
  end

  describe "handle_info({:wake_fired, id}, s)" do
    test "dispatches the identifier under the Task.Supervisor" do
      # Register a handler that pings this test process so we can
      # observe the dispatch actually running.
      id = :"wake_fired_dispatch_#{System.unique_integer([:positive])}"
      :ok = Mob.Wake.register(id, :refresh, {TestHandlers, :report_and_ok, [self()]})

      # Simulate the NIF's enif_send by dropping the message into the
      # Registry's mailbox. The Registry spawns a task under
      # Mob.Wake.TaskSupervisor that runs Mob.Wake.dispatch(id) and
      # then calls complete_task — the latter is a no-op on host
      # (NIF absent, caught by defp complete_native/2).
      send(Mob.Wake.Registry, {:wake_fired, id})

      assert_receive {:report_and_ok, nil}, 500

      # And the Registry's own state reflects the dispatch.
      s = Mob.Wake.status(id)
      assert %DateTime{} = s.last_fired_at
    end

    test "surviving native-side complete_task no-op means Registry stays up" do
      # The NIF's complete_task is called after dispatch; on host it
      # raises :undef which the Registry catches. This test ensures a
      # sequence of wake_fired doesn't crash the Registry.
      id1 = :"wake_multi_a_#{System.unique_integer([:positive])}"
      id2 = :"wake_multi_b_#{System.unique_integer([:positive])}"
      :ok = Mob.Wake.register(id1, :refresh, {TestHandlers, :report_and_ok, [self()]})
      :ok = Mob.Wake.register(id2, :refresh, {TestHandlers, :report_and_ok, [self()]})

      send(Mob.Wake.Registry, {:wake_fired, id1})
      send(Mob.Wake.Registry, {:wake_fired, id2})

      assert_receive {:report_and_ok, nil}, 500
      assert_receive {:report_and_ok, nil}, 500

      # Registry still responsive to a subsequent register/3 (i.e. it
      # didn't crash mid-flow).
      id3 = :"wake_after_#{System.unique_integer([:positive])}"
      assert :ok = Mob.Wake.register(id3, :refresh, {TestHandlers, :report_and_ok, [self()]})
    end
  end
end
