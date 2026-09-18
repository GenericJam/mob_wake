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
const MAX_PENDING: usize = 32;
const MAX_ID_LEN: usize = 128;
var g_pending: [MAX_PENDING][MAX_ID_LEN]u8 = @splat(@splat(0));
var g_pending_lens: [MAX_PENDING]usize = @splat(0);
var g_pending_count: usize = 0;

inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

// ── nativeRegister — Kotlin's static init calls this at first touch ──────
export fn Java_io_mob_wake_MobWakeBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_wake_cls = jni.newGlobalRef(jenv, cls);
    if (g_wake_cls == null) return;
    g_wake.schedule_work = jni.getStaticMethodID(jenv, cls, "scheduleWork", "(Ljava/lang/String;Ljava/lang/String;JZZ)Z");
    g_wake.complete_work = jni.getStaticMethodID(jenv, cls, "completeWork", "(Ljava/lang/String;Z)V");
    g_wake.retry_work = jni.getStaticMethodID(jenv, cls, "retryWork", "(Ljava/lang/String;)V");
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

    var id_len: usize = 0;
    while (id_c[id_len] != 0 and id_len < MAX_ID_LEN) : (id_len += 1) {}

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

    // :ok → success, :retry → retry, anything else → failure
    if (std.mem.startsWith(u8, &result_atom, "retry")) {
        if (g_wake.retry_work != null) {
            jenv.*.CallStaticVoidMethod.?(jenv, g_wake_cls, g_wake.retry_work, id_str);
        }
    } else {
        const success: jni.JBoolean = if (std.mem.startsWith(u8, &result_atom, "ok")) 1 else 0;
        if (g_wake.complete_work != null) {
            jenv.*.CallStaticVoidMethod.?(jenv, g_wake_cls, g_wake.complete_work, id_str, success);
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
    // opts (argv[2]) parsing is a TODO; the Java side currently defaults
    // earliestDelayMs=0, requiresCharging=false, requiresUnmetered=false.
    // MOB-267 wires the keyword-list parse; for MOB-263 the defaults are
    // exercised (immediate submission, no constraints).
    _ = argv[2];

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

    const ok = jenv.*.CallStaticBooleanMethod.?(jenv, g_wake_cls, g_wake.schedule_work, id_str, trg_str, @as(jni.JLong, 0), @as(jni.JBoolean, 0), @as(jni.JBoolean, 0));
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

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "set_dispatcher_pid", .arity = 1, .fptr = nif_set_dispatcher_pid, .flags = 0 },
    .{ .name = "take_pending_wakes", .arity = 0, .fptr = nif_take_pending_wakes, .flags = 0 },
    .{ .name = "complete_task", .arity = 2, .fptr = nif_complete_task, .flags = 0 },
    .{ .name = "schedule", .arity = 3, .fptr = nif_schedule, .flags = 0 },
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
