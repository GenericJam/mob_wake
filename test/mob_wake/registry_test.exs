defmodule Mob.Wake.RegistryTest do
  # This suite exercises the Registry's native-side integration paths —
  # in particular the {:wake_fired, id} handler that the iOS NIF's
  # enif_send targets. The NIF is not loaded on host; the Registry's
  # catches let the code paths run cleanly here so the Elixir shape is
  # verified even without a device.
  #
  # `async: false` because the Registry is a named singleton.

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule TestHandlers do
    def report_and_ok(who, payload), do: send(who, {:report_and_ok, payload}) && :ok
    def report_and_no_data(who, payload), do: send(who, {:no_data, payload}) && {:ok, :no_data}
    def report_and_retry(who, payload), do: send(who, {:retry, payload}) && {:error, :retry}
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

    test "ignores an unregistered identifier — SECURITY: does NOT mint a new atom" do
      # This is the fix for the atom-exhaustion finding. The push_fired
      # path is fed by APNs/FCM payload content (caller-controlled — the
      # relay operator, or worse). Prior code used String.to_atom which
      # would create a new atom for every unique inbound id and eventually
      # exhaust the BEAM's atom table (max ~1M by default).
      #
      # The fix uses String.to_existing_atom; unknown ids drop silently
      # (with a Logger.warning). We verify by:
      #   1. Sending a wake for an atom we DO NOT create locally.
      #   2. Asserting the atom does not exist afterwards.
      unknown_bin = "never_registered_#{System.unique_integer([:positive])}"

      # Establish baseline: the atom truly does not exist yet.
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_bin) end

      push_id = "unregistered-push-#{System.unique_integer([:positive])}"

      capture_log(fn ->
        send(Mob.Wake.Registry, {:push_fired, unknown_bin, push_id, ~s({})})
        # Give the Registry a beat to process — no message we can assert
        # positively on, so we probe negatively by asserting the atom
        # still doesn't exist.
        Process.sleep(50)
      end)

      # Post-condition: atom STILL does not exist. This is the whole
      # point of the fix — a hostile push can't fill the atom table.
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_bin) end
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

    test "wake_result_atom: {:ok, :no_data} from a scheduler handler maps to :ok, not :error" do
      # Fix for the review's finding #2 — a scheduler handler returning
      # {:ok, :no_data} was being flattened to :error by the previous
      # `success_atom = if result == :ok, do: :ok, else: :error` line.
      # That taught iOS's opportunistic scheduler "this task failed" and
      # over days future fires would stop. Now wake_result_atom
      # explicitly maps {:ok, :no_data} → :ok.
      #
      # This test exercises the mapping indirectly: it registers a
      # handler that returns {:ok, :no_data} and asserts the dispatch
      # result at Mob.Wake.dispatch/1's level flows the shape through.
      id = :"wake_no_data_#{System.unique_integer([:positive])}"
      :ok = Mob.Wake.register(id, :refresh, {TestHandlers, :report_and_no_data, [self()]})

      # dispatch/1 returns {:ok, :no_data} — the spec-widened shape.
      assert {:ok, :no_data} = Mob.Wake.dispatch(id)
      assert_received {:no_data, nil}
    end

    test "wake_result_atom: {:error, :retry} from a scheduler handler is preserved" do
      # Fix for the review's finding #3 — WorkManager's Result.retry()
      # was unreachable because the Registry was flattening
      # {:error, :retry} to :error (which the Zig NIF maps to
      # Result.failure()). Now wake_result_atom preserves :retry so
      # the NIF's retryWork branch is reachable.
      id = :"wake_retry_#{System.unique_integer([:positive])}"
      :ok = Mob.Wake.register(id, :refresh, {TestHandlers, :report_and_retry, [self()]})

      # dispatch/1 returns {:error, :retry} — the wake_result_atom
      # mapping preserves this for the NIF layer.
      assert {:error, :retry} = Mob.Wake.dispatch(id)
      assert_received {:retry, nil}
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
