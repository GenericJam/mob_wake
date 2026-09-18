//! mob_wake_nif — Android WorkManager + FCM plugin NIF (Zig).
//!
//! Bridges to the Kotlin `io.mob.wake.MobWakeBridge`. Mirrors the iOS
//! `mob_wake_nif.m` shape at the Elixir seam — the same four NIFs
//! (`set_dispatcher_pid`, `take_pending_wakes`, `complete_task`,
//! `schedule`), plus the JNI thunks the bridge calls when a Worker
//! fires.
//!
//! Wire flow (WorkManager fires):
//!
//!   WorkManager → MobWakeWorker.doWork()
//!     → MobWakeBridge.awaitBeamDispatch(identifier) (suspend)
//!         → registers CompletableDeferred keyed by identifier
//!         → nativeDeliverWake(identifier) → this NIF
//!             → enif_send({:wake_fired, id}) to g_dispatcher_pid
//!               OR appends to g_pending_wakes if pid not yet set
//!     ...  (BEAM runs Mob.Wake.dispatch/1, returns :ok | :error)
//!     Elixir Mob.Wake.Registry.complete_native calls
//!       :mob_wake_nif.complete_task(id_bin, :ok | :error)
//!         → this NIF → MobWakeBridge.completeWork(id, success)
//!             → deferred.complete(Result.success / .failure)
//!     ← Worker.doWork returns Result
//!
//! Structurally follows mob_sms_nif.zig — same erts / jni imports, same
//! bridge-class registration pattern.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

// mob-core exports (linked into the same .so). NOT duplicated.
extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// ── Plugin-owned bridge-class method-id cache ────────────────────────────
const WakeMethods = struct {
    schedule_work: jni.JMethodID = null,
    complete_work: jni.JMethodID = null,
    retry_work: jni.JMethodID = null,
    platform_signal: jni.JMethodID = null,
};

var g_wake: WakeMethods = .{};
var g_wake_cls: jni.JClass = null;

// ── Native dispatcher-pid + pending-wake queue ───────────────────────────
// Guarded by g_state_mutex. Mirrors the iOS side's g_mutex-guarded state.
var g_state_mutex: ?*erts.ErlNifMutex = null;
var g_dispatcher_pid: erts.ErlNifPid = undefined;
var g_dispatcher_pid_set: bool = false;
// Fixed-capacity queue — 32 pending identifiers is more than a real
// cold-start-into-background scenario would hit (one Worker fires at a
// time from WorkManager per identifier); dropping oldest on overflow is
// acceptable since the Worker's withTimeoutOrNull await times out with
// Result.failure() anyway.
//
// MAX_ID_LEN sized to accommodate reverse-DNS identifiers with a safe
// margin. Longer than 255 is invalid per iOS BGTaskScheduler docs and
// rejected explicitly at the entry rather than silently truncated —
// truncation was the previous bug: a truncated id doesn't match the
// Kotlin bridge's pendingWork key, so the Worker hangs to its timeout.
const MAX_PENDING: usize = 32;
const MAX_ID_LEN: usize = 256;
var g_pending: [MAX_PENDING][MAX_ID_LEN]u8 = @splat(@splat(0));
var g_pending_lens: [MAX_PENDING]usize = @splat(0);
var g_pending_count: usize = 0;

inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

// Clears any pending JNI exception AFTER a CallStatic*Method — the JNI
// spec says subsequent JNI calls are undefined behaviour with a pending
// exception, including detachCurrentThread. We clear rather than
// propagate: mob_wake's Kotlin bridge shouldn't throw as part of normal
// operation, so an exception here is a bug on the Kotlin side that
// wants a Logcat entry, not a BEAM-side rethrow.
inline fn clearPendingJniException(jenv: *jni.JNIEnv) void {
    if (jenv.*.ExceptionCheck.?(jenv) != 0) {
        jenv.*.ExceptionDescribe.?(jenv);
        jenv.*.ExceptionClear.?(jenv);
    }
}

// Compare a fixed-size atom buffer (null-padded, from enif_get_atom) to
// a literal target. `startsWith` was previously used — a future
// `:okay` or `:retry_later` atom would prefix-match `"ok"` / `"retry"`
// and silently misclassify. Exact match closes that hole.
inline fn atomEquals(buf: []const u8, target: []const u8) bool {
    var len: usize = 0;
    while (len < buf.len and buf[len] != 0) : (len += 1) {}
    return std.mem.eql(u8, buf[0..len], target);
}

// ── nativeRegister — Kotlin's static init calls this at first touch ──────
export fn Java_io_mob_wake_MobWakeBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_wake_cls = jni.newGlobalRef(jenv, cls);
    if (g_wake_cls == null) return;
    g_wake.schedule_work = jni.getStaticMethodID(jenv, cls, "scheduleWork", "(Ljava/lang/String;Ljava/lang/String;JZZ)Z");
    g_wake.complete_work = jni.getStaticMethodID(jenv, cls, "completeWork", "(Ljava/lang/String;Z)V");
    g_wake.retry_work = jni.getStaticMethodID(jenv, cls, "retryWork", "(Ljava/lang/String;)V");
    g_wake.platform_signal = jni.getStaticMethodID(jenv, cls, "platformSignal", "()J");
}

// ── Send helpers ─────────────────────────────────────────────────────────
fn sendWakeFired(pid: *erts.ErlNifPid, id_bytes: []const u8) void {
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(id_bytes.len, &bin) == 0) return;
    @memcpy(bin.data[0..id_bytes.len], id_bytes);
    const bin_term = erts.enif_make_binary(env, &bin);
    const msg = erts.makeTuple(env, .{
        erts.atom(env, "wake_fired"),
        bin_term,
    });
    _ = erts.enif_send(null, pid, env, msg);
}

// ── nativeDeliverWake — Kotlin calls this when a Worker fires ────────────
export fn Java_io_mob_wake_MobWakeBridge_nativeDeliverWake(jenv: *jni.JNIEnv, cls: jni.JClass, id: jni.JString) callconv(.c) void {
    _ = cls;
    const id_c = jenv.*.GetStringUTFChars.?(jenv, id, null) orelse return;
    defer jenv.*.ReleaseStringUTFChars.?(jenv, id, id_c);

    // Measure the identifier fully — no MAX_ID_LEN cap on the walk —
    // so we can reject rather than truncate. A truncated id doesn't
    // match the Kotlin bridge's pendingWork key and the Worker hangs
    // to its 9-minute timeout with the deferred never completing.
    var id_len: usize = 0;
    while (id_c[id_len] != 0) : (id_len += 1) {}
    if (id_len >= MAX_ID_LEN) return; // too long — drop, Worker times out honestly

    if (g_state_mutex == null) return;
    erts.enif_mutex_lock(g_state_mutex);
    const pid_valid = g_dispatcher_pid_set;
    var pid_snap: erts.ErlNifPid = undefined;
    if (pid_valid) {
        pid_snap = g_dispatcher_pid;
    } else if (g_pending_count < MAX_PENDING) {
        @memcpy(g_pending[g_pending_count][0..id_len], id_c[0..id_len]);
        g_pending_lens[g_pending_count] = id_len;
        g_pending_count += 1;
    }
    erts.enif_mutex_unlock(g_state_mutex);

    if (pid_valid) sendWakeFired(&pid_snap, id_c[0..id_len]);
}

// ── nativeDeliverPush — Kotlin's FCM service calls this ──────────────────
// Sends {:push_fired, id :: binary, push_id :: binary, payload_json ::
// binary} to the dispatcher pid. If the dispatcher pid isn't set yet
// we drop — FCM has a ~10s process budget on Android and BEAM waking
// from cold-suspend won't reliably make that window; failing fast
// mirrors the iOS silent-APNs choice.
export fn Java_io_mob_wake_MobWakeBridge_nativeDeliverPush(jenv: *jni.JNIEnv, cls: jni.JClass, id: jni.JString, push_id: jni.JString, payload: jni.JString) callconv(.c) void {
    _ = cls;
    const id_c = jenv.*.GetStringUTFChars.?(jenv, id, null) orelse return;
    defer jenv.*.ReleaseStringUTFChars.?(jenv, id, id_c);
    const push_id_c = jenv.*.GetStringUTFChars.?(jenv, push_id, null) orelse return;
    defer jenv.*.ReleaseStringUTFChars.?(jenv, push_id, push_id_c);
    const payload_c = jenv.*.GetStringUTFChars.?(jenv, payload, null) orelse return;
    defer jenv.*.ReleaseStringUTFChars.?(jenv, payload, payload_c);

    if (g_state_mutex == null) return;
    erts.enif_mutex_lock(g_state_mutex);
    const pid_valid = g_dispatcher_pid_set;
    var pid_snap: erts.ErlNifPid = undefined;
    if (pid_valid) pid_snap = g_dispatcher_pid;
    erts.enif_mutex_unlock(g_state_mutex);

    if (!pid_valid) return;

    var id_len: usize = 0;
    while (id_c[id_len] != 0) : (id_len += 1) {}
    var push_id_len: usize = 0;
    while (push_id_c[push_id_len] != 0) : (push_id_len += 1) {}
    var payload_len: usize = 0;
    while (payload_c[payload_len] != 0) : (payload_len += 1) {}

    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    var id_bin: erts.ErlNifBinary = undefined;
    var push_id_bin: erts.ErlNifBinary = undefined;
    var payload_bin: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(id_len, &id_bin) == 0) return;
    if (erts.enif_alloc_binary(push_id_len, &push_id_bin) == 0) return;
    if (erts.enif_alloc_binary(payload_len, &payload_bin) == 0) return;
    @memcpy(id_bin.data[0..id_len], id_c[0..id_len]);
    @memcpy(push_id_bin.data[0..push_id_len], push_id_c[0..push_id_len]);
    @memcpy(payload_bin.data[0..payload_len], payload_c[0..payload_len]);
    const msg = erts.makeTuple(env, .{
        erts.atom(env, "push_fired"),
        erts.enif_make_binary(env, &id_bin),
        erts.enif_make_binary(env, &push_id_bin),
        erts.enif_make_binary(env, &payload_bin),
    });
    _ = erts.enif_send(null, &pid_snap, env, msg);
}

// ── nativeDeliverFcmToken — sent on token registration/refresh ───────────
// Fires {:mob_wake_fcm_token, token :: binary} at the dispatcher pid
// so the app can upload it to its push server.
export fn Java_io_mob_wake_MobWakeBridge_nativeDeliverFcmToken(jenv: *jni.JNIEnv, cls: jni.JClass, token: jni.JString) callconv(.c) void {
    _ = cls;
    const tok_c = jenv.*.GetStringUTFChars.?(jenv, token, null) orelse return;
    defer jenv.*.ReleaseStringUTFChars.?(jenv, token, tok_c);

    if (g_state_mutex == null) return;
    erts.enif_mutex_lock(g_state_mutex);
    const pid_valid = g_dispatcher_pid_set;
    var pid_snap: erts.ErlNifPid = undefined;
    if (pid_valid) pid_snap = g_dispatcher_pid;
    erts.enif_mutex_unlock(g_state_mutex);
    if (!pid_valid) return;

    var tok_len: usize = 0;
    while (tok_c[tok_len] != 0) : (tok_len += 1) {}

    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(tok_len, &bin) == 0) return;
    @memcpy(bin.data[0..tok_len], tok_c[0..tok_len]);
    const msg = erts.makeTuple(env, .{
        erts.atom(env, "mob_wake_fcm_token"),
        erts.enif_make_binary(env, &bin),
    });
    _ = erts.enif_send(null, &pid_snap, env, msg);
}

// ── NIFs ─────────────────────────────────────────────────────────────────

fn nif_set_dispatcher_pid(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var pid: erts.ErlNifPid = undefined;
    if (erts.enif_get_local_pid(env, argv[0], &pid) == 0) return erts.badarg(env);
    erts.enif_mutex_lock(g_state_mutex);
    g_dispatcher_pid = pid;
    g_dispatcher_pid_set = true;
    erts.enif_mutex_unlock(g_state_mutex);
    return erts.ok(env);
}

fn nif_take_pending_wakes(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var list = erts.enif_make_list(env, 0);
    erts.enif_mutex_lock(g_state_mutex);
    const count = g_pending_count;
    var idx: usize = count;
    while (idx > 0) {
        idx -= 1;
        var bin: erts.ErlNifBinary = undefined;
        const n = g_pending_lens[idx];
        if (erts.enif_alloc_binary(n, &bin) != 0) {
            @memcpy(bin.data[0..n], g_pending[idx][0..n]);
            const term = erts.enif_make_binary(env, &bin);
            list = erts.enif_make_list_cell(env, term, list);
        }
    }
    g_pending_count = 0;
    erts.enif_mutex_unlock(g_state_mutex);
    return list;
}

fn nif_complete_task(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var id_buf: [MAX_ID_LEN]u8 = @splat(0);
    if (!binArgZ(env, argv[0], &id_buf)) return erts.badarg(env);

    var result_atom: [16]u8 = @splat(0);
    if (erts.enif_get_atom(env, argv[1], &result_atom, result_atom.len, erts.ERL_NIF_LATIN1) == 0) return erts.badarg(env);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    if (g_wake_cls == null) {
        detachIfAttached(attached);
        return erts.atom(env, "error");
    }

    const id_str = jni.newStringUTF(jenv, jni.asCStr(&id_buf));
    if (id_str == null) {
        detachIfAttached(attached);
        return erts.atom(env, "error");
    }
    defer jni.deleteLocalRef(jenv, id_str);

    // Exact match on the atom, not prefix — startsWith would misclassify
    // a future `:okay` / `:retry_soon` / etc. atom.
    if (atomEquals(&result_atom, "retry")) {
        if (g_wake.retry_work != null) {
            jenv.*.CallStaticVoidMethod.?(jenv, g_wake_cls, g_wake.retry_work, id_str);
            clearPendingJniException(jenv);
        }
    } else {
        const success: jni.JBoolean = if (atomEquals(&result_atom, "ok")) 1 else 0;
        if (g_wake.complete_work != null) {
            jenv.*.CallStaticVoidMethod.?(jenv, g_wake_cls, g_wake.complete_work, id_str, success);
            clearPendingJniException(jenv);
        }
    }
    detachIfAttached(attached);
    return erts.ok(env);
}

fn nif_schedule(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var id_buf: [MAX_ID_LEN]u8 = @splat(0);
    if (!binArgZ(env, argv[0], &id_buf)) return erts.badarg(env);

    var trigger_atom: [16]u8 = @splat(0);
    if (erts.enif_get_atom(env, argv[1], &trigger_atom, trigger_atom.len, erts.ERL_NIF_LATIN1) == 0) return erts.badarg(env);

    // Elixir side flattens opts to explicit args — earliest_ms, charging,
    // unmetered. See Mob.Wake.flatten_opts/1.
    var earliest_ms: c_long = 0;
    if (erts.enif_get_long(env, argv[2], &earliest_ms) == 0) return erts.badarg(env);
    if (earliest_ms < 0) return erts.badarg(env);

    var charging_atom: [8]u8 = @splat(0);
    if (erts.enif_get_atom(env, argv[3], &charging_atom, charging_atom.len, erts.ERL_NIF_LATIN1) == 0) return erts.badarg(env);
    const charging: jni.JBoolean = if (atomEquals(&charging_atom, "true")) 1 else 0;

    var unmetered_atom: [8]u8 = @splat(0);
    if (erts.enif_get_atom(env, argv[4], &unmetered_atom, unmetered_atom.len, erts.ERL_NIF_LATIN1) == 0) return erts.badarg(env);
    const unmetered: jni.JBoolean = if (atomEquals(&unmetered_atom, "true")) 1 else 0;

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse {
        return erts.tuple2(env, erts.atom(env, "error"), erts.atom(env, "no_jenv"));
    };
    if (g_wake_cls == null or g_wake.schedule_work == null) {
        detachIfAttached(attached);
        return erts.tuple2(env, erts.atom(env, "error"), erts.atom(env, "bridge_not_registered"));
    }

    const id_str = jni.newStringUTF(jenv, jni.asCStr(&id_buf));
    const trg_str = jni.newStringUTF(jenv, jni.asCStr(&trigger_atom));
    if (id_str == null or trg_str == null) {
        if (id_str != null) jni.deleteLocalRef(jenv, id_str);
        if (trg_str != null) jni.deleteLocalRef(jenv, trg_str);
        detachIfAttached(attached);
        return erts.tuple2(env, erts.atom(env, "error"), erts.atom(env, "jstring_alloc_failed"));
    }
    defer jni.deleteLocalRef(jenv, id_str);
    defer jni.deleteLocalRef(jenv, trg_str);

    const ok = jenv.*.CallStaticBooleanMethod.?(jenv, g_wake_cls, g_wake.schedule_work, id_str, trg_str, @as(jni.JLong, earliest_ms), charging, unmetered);
    clearPendingJniException(jenv);
    detachIfAttached(attached);
    if (ok == 0) {
        return erts.tuple2(env, erts.atom(env, "error"), erts.atom(env, "submit_failed"));
    }
    return erts.ok(env);
}

// ── Helpers (matches mob_sms shape) ──────────────────────────────────────
fn binArgZ(env: ?*erts.ErlNifEnv, term: erts.ERL_NIF_TERM, buf: []u8) bool {
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, term, &bin) == 0 and
        erts.enif_inspect_iolist_as_binary(env, term, &bin) == 0) return false;
    const n = @min(bin.size, buf.len - 1);
    @memcpy(buf[0..n], bin.data[0..n]);
    buf[n] = 0;
    return true;
}

// ── NIF table + init ─────────────────────────────────────────────────────
fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = env;
    _ = priv;
    _ = info;
    if (g_state_mutex == null) g_state_mutex = erts.enif_mutex_create("mob_wake_nif");
    return if (g_state_mutex == null) 1 else 0;
}

// complete_push is iOS-only (silent APNs has a fetchCompletionHandler
// callback; FCM does not). Kept exported here as a no-op so the Elixir
// Registry's complete_push_native call succeeds on both platforms
// without a per-platform branch — mirrors mob-core's "cross-platform
// contract > per-platform gate" convention.
fn nif_complete_push_noop(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return erts.ok(env);
}

// platform_signal/0 → %{battery_optimized: bool, has_context: bool}
// Wraps MobWakeBridge.platformSignal() which returns a bit-packed long:
// bit 0 = batteryOptimized, bit 1 = hasContext. `has_context` distinguishes
// "app is whitelisted" from "we can't tell yet" (bridge boot race).
fn nif_platform_signal(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.enif_make_new_map(env);
    if (g_wake_cls == null or g_wake.platform_signal == null) {
        detachIfAttached(attached);
        return erts.enif_make_new_map(env);
    }
    const bits = jenv.*.CallStaticLongMethod.?(jenv, g_wake_cls, g_wake.platform_signal);
    clearPendingJniException(jenv);
    detachIfAttached(attached);

    const battery_optimized: bool = (bits & 0b01) != 0;
    const has_context: bool = (bits & 0b10) != 0;

    var map = erts.enif_make_new_map(env);
    var out: erts.ERL_NIF_TERM = undefined;
    _ = erts.enif_make_map_put(env, map,
        erts.atom(env, "battery_optimized"),
        erts.atom(env, if (battery_optimized) "true" else "false"),
        &out);
    map = out;
    _ = erts.enif_make_map_put(env, map,
        erts.atom(env, "has_context"),
        erts.atom(env, if (has_context) "true" else "false"),
        &out);
    return out;
}

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "set_dispatcher_pid", .arity = 1, .fptr = nif_set_dispatcher_pid, .flags = 0 },
    .{ .name = "take_pending_wakes", .arity = 0, .fptr = nif_take_pending_wakes, .flags = 0 },
    .{ .name = "complete_task", .arity = 2, .fptr = nif_complete_task, .flags = 0 },
    .{ .name = "complete_push", .arity = 2, .fptr = nif_complete_push_noop, .flags = 0 },
    .{ .name = "platform_signal", .arity = 0, .fptr = nif_platform_signal, .flags = 0 },
    .{ .name = "schedule", .arity = 5, .fptr = nif_schedule, .flags = 0 },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_wake_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = nifLoad,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

pub export fn mob_wake_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
