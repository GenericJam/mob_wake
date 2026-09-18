/* mob_wake_nif — iOS BGTaskScheduler + silent APNs receive plugin NIF.
 *
 * Bridges iOS's OS-triggered wake mechanisms to the BEAM.
 *
 * ── Why the shape looks like this ─────────────────────────────────────
 *
 * iOS suspends BEAM (and every other user-space thread) when the app is
 * backgrounded — mob/guides/background_execution.md is explicit about
 * this. When iOS later wakes us to run a BGTask, the launchHandler
 * fires on a background queue with BEAM either resumed-from-suspend or
 * cold-started, and we cannot rely on a specific BEAM state at that
 * moment.
 *
 * So the native side owns a tiny amount of persistent state:
 *
 *   * `g_dispatcher_pid`  — the pid (usually Mob.Wake.Registry) that
 *     Elixir wants wake events sent to. Set by
 *     `mob_wake_nif:set_dispatcher_pid/1` at Registry boot.
 *   * `g_pending_wakes`   — a queue of identifiers whose launchHandler
 *     fired before the dispatcher pid was set. Drained by
 *     `mob_wake_nif:take_pending_wakes/0` once BEAM is up.
 *   * `g_bg_tasks`        — identifier → BGTask* table. The launchHandler
 *     hands us a BGTask that MUST have `setTaskCompleted:` called
 *     before iOS's window expires; we hold it here until the BEAM
 *     dispatch returns and `mob_wake_nif:complete_task/2` fires.
 *
 * All three are guarded by a single ErlNifMutex (`g_mutex`) that
 * tolerates being asked to lock before `nif_load` created it — mirrors
 * the mob core `g_launch_notification_json` pattern.
 *
 * ── Wire flow ─────────────────────────────────────────────────────────
 *
 *   iOS wakes app for BGTask firing
 *     → AppDelegate's launchHandler runs on a background queue
 *     → Calls [MobWakeDispatcher onTaskFired: identifier task:]
 *         → Stashes task in g_bg_tasks under identifier
 *         → If g_dispatcher_pid set: enif_send({:wake_fired, id})
 *         → Else: appends id to g_pending_wakes
 *     → BEAM (eventually) runs Mob.Wake.dispatch/1
 *     → Elixir calls mob_wake_nif:complete_task(id, success?)
 *     → Retrieves BGTask from g_bg_tasks, calls setTaskCompleted:
 *       (success:), removes from table
 *
 * ── AppDelegate integration ───────────────────────────────────────────
 *
 * The host's AppDelegate.m must call
 * [MobWakeDispatcher registerTaskWithIdentifier:trigger:] once per
 * identifier in `didFinishLaunchingWithOptions:`. mob_new's codegen
 * (MOB-265) writes this automatically from `config :mob_wake, :tasks`;
 * hand-wired hosts until then follow the README snippet.
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <BackgroundTasks/BackgroundTasks.h>
#include <erl_nif.h>

// Single mutex covering the three globals. Guarded lazily — a call
// arriving before `nif_load` created the mutex is fine (we no-op the
// enqueue and let the BGTask expire; the scenario is a launchHandler
// firing before the app has loaded any NIF, which shouldn't happen).
static ErlNifMutex *g_mutex = NULL;
static ErlNifPid g_dispatcher_pid;
static BOOL g_dispatcher_pid_set = NO;
static NSMutableDictionary<NSString *, BGTask *> *g_bg_tasks = nil;
static NSMutableArray<NSString *> *g_pending_wakes = nil;

// Local send helper: {:wake_fired, identifier :: binary}
static void send_wake_fired(ErlNifPid *pid, NSString *identifier) {
  ErlNifEnv *env = enif_alloc_env();
  const char *bytes = [identifier UTF8String];
  size_t len = strlen(bytes);
  ERL_NIF_TERM id_bin;
  unsigned char *raw = enif_make_new_binary(env, len, &id_bin);
  if (raw != NULL) {
    memcpy(raw, bytes, len);
  }
  ERL_NIF_TERM msg = enif_make_tuple2(env, enif_make_atom(env, "wake_fired"), id_bin);
  enif_send(NULL, pid, env, msg);
  enif_free_env(env);
}

// ── ObjC-side dispatcher ─────────────────────────────────────────────

@interface MobWakeDispatcher : NSObject
+ (void)registerTaskWithIdentifier:(NSString *)identifier trigger:(NSString *)trigger;
+ (void)onTaskFired:(BGTask *)task;
@end

@implementation MobWakeDispatcher

+ (void)registerTaskWithIdentifier:(NSString *)identifier trigger:(NSString *)trigger {
  // BGTaskScheduler API requires the launchHandler to be registered
  // BEFORE didFinishLaunchingWithOptions returns; late registration is
  // silently rejected. mob_new (MOB-265) or the hand-wired app must
  // call this exactly once per identifier.
  //
  // We ignore the `trigger` arg for the register call — BGTaskScheduler
  // registers on the identifier alone; the trigger (refresh vs
  // processing) is enforced when submitting a request, not when
  // registering the handler.
  (void)trigger;

  if (@available(iOS 13.0, *)) {
    [[BGTaskScheduler sharedScheduler]
        registerForTaskWithIdentifier:identifier
                           usingQueue:nil
                        launchHandler:^(BGTask *_Nonnull task) {
                          [MobWakeDispatcher onTaskFired:task];
                        }];
  }
}

+ (void)onTaskFired:(BGTask *)task {
  NSString *identifier = task.identifier;
  if (identifier == nil || identifier.length == 0) {
    // Defensive — shouldn't happen given how BGTaskScheduler hands
    // BGTasks in, but if it does, mark complete-with-failure so iOS
    // learns to distrust the schedule rather than hanging.
    [task setTaskCompletedWithSuccess:NO];
    return;
  }

  if (g_mutex == NULL) {
    // NIF load hasn't run — we have nowhere to stash the task and no
    // way to reach BEAM. Fail the task honestly.
    [task setTaskCompletedWithSuccess:NO];
    return;
  }

  // iOS may cancel the task early (background-time exhausted). Report
  // NO to iOS via setTaskCompletedWithSuccess: even though BEAM may
  // still be running the handler — the platform contract is that
  // expirationHandler must be honored.
  task.expirationHandler = ^{
    // Grab-and-drop under lock so we don't race with complete_task.
    enif_mutex_lock(g_mutex);
    if (g_bg_tasks[identifier] == task) {
      [g_bg_tasks removeObjectForKey:identifier];
    }
    enif_mutex_unlock(g_mutex);
    [task setTaskCompletedWithSuccess:NO];
  };

  ErlNifPid pid_snapshot;
  BOOL pid_valid;

  enif_mutex_lock(g_mutex);
  if (g_bg_tasks == nil) g_bg_tasks = [NSMutableDictionary new];
  g_bg_tasks[identifier] = task;

  pid_valid = g_dispatcher_pid_set;
  if (pid_valid) {
    pid_snapshot = g_dispatcher_pid;
  } else {
    if (g_pending_wakes == nil) g_pending_wakes = [NSMutableArray new];
    [g_pending_wakes addObject:identifier];
  }
  enif_mutex_unlock(g_mutex);

  if (pid_valid) {
    send_wake_fired(&pid_snapshot, identifier);
  }
  // Not-set path: BEAM will drain via take_pending_wakes/0 when it's up.
  // The BGTask stays in g_bg_tasks until complete_task/2 fires or the
  // expirationHandler above collects it.
}

@end

// ── NIF: set_dispatcher_pid ──────────────────────────────────────────

static ERL_NIF_TERM nif_set_dispatcher_pid(ErlNifEnv *env, int argc,
                                            const ERL_NIF_TERM argv[]) {
  ErlNifPid pid;
  if (!enif_get_local_pid(env, argv[0], &pid)) return enif_make_badarg(env);

  enif_mutex_lock(g_mutex);
  g_dispatcher_pid = pid;
  g_dispatcher_pid_set = YES;
  enif_mutex_unlock(g_mutex);

  return enif_make_atom(env, "ok");
}

// ── NIF: take_pending_wakes ──────────────────────────────────────────

static ERL_NIF_TERM nif_take_pending_wakes(ErlNifEnv *env, int argc,
                                            const ERL_NIF_TERM argv[]) {
  NSArray<NSString *> *drained;
  enif_mutex_lock(g_mutex);
  drained = (g_pending_wakes == nil) ? @[] : [g_pending_wakes copy];
  [g_pending_wakes removeAllObjects];
  enif_mutex_unlock(g_mutex);

  ERL_NIF_TERM list = enif_make_list(env, 0);
  // Build the list in reverse so the head-inserted result is oldest-first.
  for (NSString *id_str in [drained reverseObjectEnumerator]) {
    const char *bytes = [id_str UTF8String];
    size_t len = strlen(bytes);
    ERL_NIF_TERM id_bin;
    unsigned char *raw = enif_make_new_binary(env, len, &id_bin);
    if (raw != NULL) memcpy(raw, bytes, len);
    list = enif_make_list_cell(env, id_bin, list);
  }
  return list;
}

// ── NIF: complete_task ───────────────────────────────────────────────

static ERL_NIF_TERM nif_complete_task(ErlNifEnv *env, int argc,
                                       const ERL_NIF_TERM argv[]) {
  ErlNifBinary id_bin;
  if (!enif_inspect_binary(env, argv[0], &id_bin) &&
      !enif_inspect_iolist_as_binary(env, argv[0], &id_bin)) {
    return enif_make_badarg(env);
  }
  // arg 1: :ok atom → success, anything else → failure. We accept a
  // 2-arity call (id, success_atom) rather than trying to interpret an
  // arbitrary term because the Elixir side has already flattened its
  // return to :ok | {:error, _}.
  char success_atom[16] = {0};
  if (!enif_get_atom(env, argv[1], success_atom, sizeof(success_atom), ERL_NIF_LATIN1)) {
    return enif_make_badarg(env);
  }
  BOOL success = (strncmp(success_atom, "ok", 3) == 0);

  NSString *identifier = [[NSString alloc] initWithBytes:id_bin.data
                                                  length:id_bin.size
                                                encoding:NSUTF8StringEncoding];
  if (identifier == nil) return enif_make_badarg(env);

  BGTask *task;
  enif_mutex_lock(g_mutex);
  task = g_bg_tasks[identifier];
  if (task != nil) [g_bg_tasks removeObjectForKey:identifier];
  enif_mutex_unlock(g_mutex);

  if (task == nil) {
    // Either already completed via expirationHandler, or complete_task
    // was called for an identifier that never fired. Return
    // {:error, :no_such_task} so the Elixir side sees the truth.
    return enif_make_tuple2(env,
                            enif_make_atom(env, "error"),
                            enif_make_atom(env, "no_such_task"));
  }

  [task setTaskCompletedWithSuccess:success];
  return enif_make_atom(env, "ok");
}

// ── NIF: schedule ────────────────────────────────────────────────────

static ERL_NIF_TERM nif_schedule(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
  // schedule(identifier :: binary, trigger :: atom, opts :: keyword) →
  //   :ok | {:error, reason}
  //
  // opts (keyword list) currently understood keys:
  //   :earliest — POSIX seconds since epoch (integer); maps to
  //     BGTaskRequest.earliestBeginDate.
  //
  // Constraints (:charging / :unmetered) are wired only on
  // BGProcessingTaskRequest — BGAppRefreshTaskRequest doesn't accept
  // them. We ignore constraint opts on :refresh rather than erroring
  // so a task table shared with Android (where the same constraint
  // shape is honored on WorkManager) doesn't need per-platform opts.
  ErlNifBinary id_bin;
  if (!enif_inspect_binary(env, argv[0], &id_bin) &&
      !enif_inspect_iolist_as_binary(env, argv[0], &id_bin)) {
    return enif_make_badarg(env);
  }
  char trigger[16] = {0};
  if (!enif_get_atom(env, argv[1], trigger, sizeof(trigger), ERL_NIF_LATIN1)) {
    return enif_make_badarg(env);
  }
  if (strncmp(trigger, "push", 5) == 0) {
    // Sanity — Elixir's Mob.Wake.schedule/2 rejects :push before we
    // get here, but a caller invoking the NIF directly should still be
    // told no.
    return enif_make_tuple2(env,
                            enif_make_atom(env, "error"),
                            enif_make_atom(env, "cannot_schedule_push"));
  }

  NSString *identifier = [[NSString alloc] initWithBytes:id_bin.data
                                                  length:id_bin.size
                                                encoding:NSUTF8StringEncoding];
  if (identifier == nil) return enif_make_badarg(env);

  if (@available(iOS 13.0, *)) {
    BGTaskRequest *req;
    if (strncmp(trigger, "refresh", 8) == 0) {
      req = [[BGAppRefreshTaskRequest alloc] initWithIdentifier:identifier];
    } else if (strncmp(trigger, "processing", 11) == 0) {
      BGProcessingTaskRequest *p =
          [[BGProcessingTaskRequest alloc] initWithIdentifier:identifier];
      // Defaults matched to the common case ("housekeeping when the
      // device is plugged in and idle") — mob_wake's docs recommend
      // :refresh for anything that runs while the user is active.
      p.requiresExternalPower = YES;
      p.requiresNetworkConnectivity = NO;
      req = p;
    } else {
      return enif_make_tuple2(env,
                              enif_make_atom(env, "error"),
                              enif_make_atom(env, "unknown_trigger"));
    }

    // TODO(MOB-267): parse opts keyword list for :earliest and constraints.
    (void)argv[2];

    NSError *err = nil;
    BOOL ok = [[BGTaskScheduler sharedScheduler] submitTaskRequest:req error:&err];
    if (!ok) {
      // Common error: BGTaskSchedulerErrorDomain / .unavailable — the
      // identifier isn't in Info.plist's BGTaskSchedulerPermittedIdentifiers,
      // or Background App Refresh is disabled system-wide.
      return enif_make_tuple2(env,
                              enif_make_atom(env, "error"),
                              enif_make_atom(env, "submit_failed"));
    }
    return enif_make_atom(env, "ok");
  }

  return enif_make_tuple2(env,
                          enif_make_atom(env, "error"),
                          enif_make_atom(env, "ios_below_13"));
}

// ── NIF load / unload ────────────────────────────────────────────────

static int on_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
  (void)env; (void)priv_data; (void)load_info;
  if (g_mutex == NULL) g_mutex = enif_mutex_create("mob_wake_nif");
  return (g_mutex == NULL) ? 1 : 0;
}

static void on_unload(ErlNifEnv *env, void *priv_data) {
  (void)env; (void)priv_data;
  // Deliberately leave g_mutex / g_bg_tasks / g_pending_wakes alive:
  // unload runs at app shutdown and the OS reclaims everything anyway;
  // freeing them here creates a race with any launchHandler in flight.
}

static ErlNifFunc nif_funcs[] = {
    {"set_dispatcher_pid",  1, nif_set_dispatcher_pid,  0},
    {"take_pending_wakes",  0, nif_take_pending_wakes,  0},
    {"complete_task",       2, nif_complete_task,       0},
    {"schedule",            3, nif_schedule,            0},
};

ERL_NIF_INIT(mob_wake_nif, nif_funcs, on_load, NULL, NULL, on_unload)
