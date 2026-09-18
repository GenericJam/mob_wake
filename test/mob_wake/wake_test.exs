defmodule Mob.WakeTest do
  use ExUnit.Case, async: true

  # Scaffold contract: every public function raises with a clear
  # "not yet implemented — see MOB-XXX" message. Real bodies land in
  # MOB-260 (Elixir surface) + MOB-261..264 (native trigger paths) +
  # MOB-267 (observability enrichment).
  #
  # These tests exist so a future accidental "empty body" implementation
  # (returning nil, :ok, %{}) is caught rather than silently regressing
  # the contract. They enumerate the surface: any new public function
  # added to Mob.Wake without a stub-body test is a gap in this contract.

  describe "scaffold contract" do
    test "register/2 raises pointing at MOB-260" do
      err = assert_raise RuntimeError, fn -> Mob.Wake.register(:sync_notes, {Mod, :fun}) end
      assert err.message =~ "MOB-260"
    end

    test "schedule/2 raises pointing at MOB-260" do
      err = assert_raise RuntimeError, fn -> Mob.Wake.schedule(:sync_notes, []) end
      assert err.message =~ "MOB-260"
    end

    test "dispatch/1 raises pointing at MOB-260" do
      err = assert_raise RuntimeError, fn -> Mob.Wake.dispatch(:sync_notes) end
      assert err.message =~ "MOB-260"
    end

    test "status/1 raises pointing at MOB-260 (and MOB-267)" do
      err = assert_raise RuntimeError, fn -> Mob.Wake.status(:sync_notes) end
      assert err.message =~ "MOB-260"
    end

    test "pending/0 raises pointing at MOB-260" do
      err = assert_raise RuntimeError, fn -> Mob.Wake.pending() end
      assert err.message =~ "MOB-260"
    end
  end
end
