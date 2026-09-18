defmodule Mob.WakeTest do
  # This suite exercises the Elixir dispatch surface (MOB-260). The
  # native trigger paths (MOB-261..264) are covered elsewhere — these
  # tests deliberately register handlers with `register/3` rather than
  # rely on native firings, so each test is hermetic.
  #
  # `async: false` because the Registry is a named singleton. Each test
  # picks a distinct identifier via unique_tag/1 so the tests can run
  # in any order without stepping on each other.

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # ── helpers ─────────────────────────────────────────────────────────

  defp unique_tag(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  # A handler module the tests can point Mob.Wake at. Sends to a caller
  # so the test can observe both invocation shape (payload arg) and
  # return value handling in `dispatch/1`.
  defmodule TestHandlers do
    def echo_ok(_payload), do: :ok
    def with_extra(who, payload), do: send(who, {:with_extra, payload}) && :ok
    def report_and_ok(who, payload), do: send(who, {:report_and_ok, payload}) && :ok

    def report_and_error(who, payload),
      do: send(who, {:report_and_error, payload}) && {:error, :nope}

    def crash(_payload), do: raise("boom")
    def slow(_payload), do: :timer.sleep(:infinity)
  end

  # ── register/3 ──────────────────────────────────────────────────────

  describe "register/3" do
    test "accepts {m, f} mfa" do
      id = unique_tag(:reg_mf)
      assert :ok = Mob.Wake.register(id, :refresh, {TestHandlers, :echo_ok})
    end

    test "accepts {m, f, extra_args} mfa" do
      id = unique_tag(:reg_mfa)
      assert :ok = Mob.Wake.register(id, :refresh, {TestHandlers, :with_extra, [self()]})
    end

    test "rejects a malformed mfa with ArgumentError" do
      id = unique_tag(:reg_bad)
      # Not a tuple — the shape guard raises. This catches typos like
      # passing a bare atom or a function capture instead of a tuple.
      assert_raise ArgumentError, ~r/register\/3 expects/, fn ->
        Mob.Wake.register(id, :refresh, :not_a_tuple)
      end
    end

    test "rejects an invalid trigger at the head clause guard" do
      id = unique_tag(:reg_bad_trig)
      # Guard failure raises FunctionClauseError — a bare atom that isn't
      # one of the three trigger sources means the caller hasn't decided
      # on a trigger and we'd rather that be loud than silently accepted.
      # apply/3 bypasses Dialyzer's static rejection of an invalid trigger
      # atom — the runtime guard is exactly what this test exercises.
      assert_raise FunctionClauseError, fn ->
        apply(Mob.Wake, :register, [id, :not_a_trigger, {TestHandlers, :echo_ok}])
      end
    end
  end

  # ── dispatch/1 ──────────────────────────────────────────────────────

  describe "dispatch/1 — bare identifier (scheduler firings)" do
    test "invokes the handler with nil payload and returns :ok" do
      id = unique_tag(:dis_bare)
      :ok = Mob.Wake.register(id, :refresh, {TestHandlers, :report_and_ok, [self()]})

      assert :ok = Mob.Wake.dispatch(id)
      assert_received {:report_and_ok, nil}
    end

    test "returns {:error, :unknown_identifier} for an unregistered id" do
      assert {:error, :unknown_identifier} = Mob.Wake.dispatch(:never_registered)
    end

    test "propagates a handler's {:error, reason}" do
      id = unique_tag(:dis_err)
      :ok = Mob.Wake.register(id, :refresh, {TestHandlers, :report_and_error, [self()]})

      assert {:error, :nope} = Mob.Wake.dispatch(id)
    end

    test "propagates a handler's {:ok, :no_data} (push :no_data convention)" do
      # Push handlers can signal "ran but no new data" via {:ok, :no_data}.
      # Verifies the return survives run_handler_with_timeout's match on
      # the {:ok, {:ok, :no_data}} → {:ok, :no_data} branch. The Registry's
      # push_result_atom then maps it to :no_data for
      # UIBackgroundFetchResult on iOS.
      id = unique_tag(:dis_no_data)

      defmodule NoDataHandler do
        def run(_payload), do: {:ok, :no_data}
      end

      :ok = Mob.Wake.register(id, :push, {NoDataHandler, :run})
      assert {:ok, :no_data} = Mob.Wake.dispatch(id)
    end

    test "wraps a handler crash in {:error, {:crashed, _}}" do
      id = unique_tag(:dis_crash)
      :ok = Mob.Wake.register(id, :refresh, {TestHandlers, :crash})

      # capture_log suppresses the expected crash log line so stdout
      # stays clean; the assertion is what matters.
      capture_log(fn ->
        assert {:error, {:crashed, _}} = Mob.Wake.dispatch(id)
      end)
    end
  end

  describe "dispatch/1 — payload map (push firings)" do
    test "invokes the handler with the payload map" do
      id = unique_tag(:dis_push)
      :ok = Mob.Wake.register(id, :push, {TestHandlers, :report_and_ok, [self()]})

      assert :ok = Mob.Wake.dispatch(%{identifier: id, payload: %{"peer" => "abc"}})
      assert_received {:report_and_ok, %{"peer" => "abc"}}
    end
  end

  describe "dispatch/1 — timeout" do
    test "returns {:error, :timeout} when the handler runs past the trigger's window" do
      # test env shrinks all timeouts to 200ms via config/config.exs, so
      # this branch is testable in sub-second time. Prod windows are
      # matched to the OS (see Mob.Wake's @moduledoc).
      id = unique_tag(:dis_slow)
      :ok = Mob.Wake.register(id, :push, {TestHandlers, :slow})

      assert {:error, :timeout} = Mob.Wake.dispatch(id)
    end
  end

  # ── schedule/2 ──────────────────────────────────────────────────────

  describe "schedule/2" do
    test "rejects an unknown identifier" do
      assert {:error, :unknown_identifier} = Mob.Wake.schedule(:never_registered)
    end

    test "rejects a :push identifier with :cannot_schedule_push" do
      # :push identifiers wake from a server, not from `schedule/2`.
      # Enforcing this at call time catches the case where a user
      # accidentally called schedule on a push-only handler.
      id = unique_tag(:sch_push)
      :ok = Mob.Wake.register(id, :push, {TestHandlers, :echo_ok})
      assert {:error, :cannot_schedule_push} = Mob.Wake.schedule(id)
    end

    test "reports :not_yet_implemented for a schedulable trigger until MOB-261/263 land" do
      id = unique_tag(:sch_impl)
      :ok = Mob.Wake.register(id, :refresh, {TestHandlers, :echo_ok})
      # The NIF module doesn't exist yet — the catch collapses the
      # undef and reports :not_yet_implemented rather than a
      # FunctionClauseError leaking to the caller.
      assert {:error, :not_yet_implemented} = Mob.Wake.schedule(id)
    end

    test "raises ArgumentError on malformed :earliest opt" do
      id = unique_tag(:sch_bad_earliest)
      :ok = Mob.Wake.register(id, :refresh, {TestHandlers, :echo_ok})
      # Flatten_opts is the shape guard. String is not a DateTime or
      # non_neg_integer — MUST raise before the NIF is called so a
      # typo doesn't silently no-op.
      assert_raise ArgumentError, ~r/:earliest/, fn ->
        Mob.Wake.schedule(id, earliest: "not-a-datetime")
      end
    end

    test "accepts :earliest as DateTime and non_neg_integer" do
      id = unique_tag(:sch_earliest_ok)
      :ok = Mob.Wake.register(id, :refresh, {TestHandlers, :echo_ok})
      # NIF not loaded so both return :not_yet_implemented, but the
      # important thing is neither shape raises — flatten_opts accepts
      # both forms.
      assert {:error, :not_yet_implemented} =
               Mob.Wake.schedule(id, earliest: DateTime.utc_now())

      assert {:error, :not_yet_implemented} =
               Mob.Wake.schedule(id, earliest: 60_000)
    end
  end

  # ── status/1 ────────────────────────────────────────────────────────

  describe "status/1" do
    test "returns the initial state after registration" do
      id = unique_tag(:stat_init)
      :ok = Mob.Wake.register(id, :refresh, {TestHandlers, :echo_ok})

      s = Mob.Wake.status(id)
      assert s.state == :idle
      assert s.last_fired_at == nil
      assert s.next_eligible_fire == nil
      # On host the NIF is absent so platform_signal collapses to %{}.
      # Real devices override with iOS backgroundRefreshStatus or
      # Android battery_optimized (see MOB-267).
      assert s.platform_signal == %{}
    end

    test "reflects last_fired_at after a dispatch" do
      id = unique_tag(:stat_fire)
      :ok = Mob.Wake.register(id, :refresh, {TestHandlers, :echo_ok})
      before = DateTime.utc_now()
      :ok = Mob.Wake.dispatch(id)

      s = Mob.Wake.status(id)
      assert s.state == :idle
      assert %DateTime{} = s.last_fired_at
      assert DateTime.compare(s.last_fired_at, before) in [:eq, :gt]
    end

    test "returns {:error, :unknown_identifier} for an unregistered id" do
      assert {:error, :unknown_identifier} = Mob.Wake.status(:never_registered)
    end
  end

  # ── pending/0 ───────────────────────────────────────────────────────

  describe "pending/0" do
    test "includes registered tasks with their trigger + state" do
      id = unique_tag(:pen_incl)
      :ok = Mob.Wake.register(id, :processing, {TestHandlers, :echo_ok})

      entry = Enum.find(Mob.Wake.pending(), fn e -> e.identifier == id end)
      assert entry.trigger == :processing
      assert entry.state == :idle
      assert entry.last_fired_at == nil
    end
  end
end
