%% mob_wake_nif — Erlang NIF module for the mob_wake plugin.
%%
%% iOS: priv/native/ios/mob_wake_nif.m (Objective-C, BGTaskScheduler +
%% silent APNs).
%% Android: priv/native/jni/mob_wake_nif.zig (WorkManager + FCM data via
%% the io.mob.wake.MobWakeBridge Kotlin bridge). Both register this
%% module via ERL_NIF_INIT and are statically linked into the host
%% binary on device.
%%
%% On host dev builds neither is linked, so on_load tolerates the failure
%% and every NIF falls back to nif_error until the native merge links
%% one. `Mob.Wake.Registry` / `Mob.Wake` catch :undef and :nif_not_loaded
%% at every call site to keep the Elixir surface working uniformly.
-module(mob_wake_nif).

-export([
    set_dispatcher_pid/1,
    take_pending_wakes/0,
    complete_task/2,
    complete_push/2,
    platform_signal/0,
    schedule/5
]).

-on_load(init/0).

init() ->
    case erlang:load_nif("mob_wake_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

set_dispatcher_pid(_Pid) ->
    erlang:nif_error(nif_not_loaded).

take_pending_wakes() ->
    erlang:nif_error(nif_not_loaded).

complete_task(_Identifier, _SuccessAtom) ->
    erlang:nif_error(nif_not_loaded).

complete_push(_PushId, _ResultAtom) ->
    erlang:nif_error(nif_not_loaded).

platform_signal() ->
    erlang:nif_error(nif_not_loaded).

schedule(_Identifier, _Trigger, _EarliestMs, _Charging, _Unmetered) ->
    erlang:nif_error(nif_not_loaded).
