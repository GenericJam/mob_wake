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

// Single mutex covering all five globals. Guarded lazily — a call
// arriving before `nif_load` created the mutex is fine (we no-op the
// enqueue and let the BGTask expire; the scenario is a launchHandler
// firing before the app has loaded any NIF, which shouldn't happen).
static ErlNifMutex *g_mutex = NULL;
static ErlNifPid g_dispatcher_pid;
static BOOL g_dispatcher_pid_set = NO;
static NSMutableDictionary<NSString *, BGTask *> *g_bg_tasks = nil;
static NSMutableArray<NSString *> *g_pending_wakes = nil;
// Silent-APNs completions live in their own table keyed by push_id
// (NSUUID string) rather than the wake identifier — multiple pushes
// for the same identifier can arrive in flight, unlike BGTasks where
// only one fires per identifier at a time.
static NSMutableDictionary<NSString *, void (^)(UIBackgroundFetchResult)> *g_push_completions = nil;

// Build a binary term from an NSString.
static ERL_NIF_TERM nsstring_to_bin(ErlNifEnv *env, NSString *s) {
  const char *bytes = [s UTF8String];
  size_t len = strlen(bytes);
  ERL_NIF_TERM bin;
  unsigned char *raw = enif_make_new_binary(env, len, &bin);
  if (raw != NULL) memcpy(raw, bytes, len);
  return bin;
}

// Local send helper: {:wake_fired, identifier :: binary}
//
// enif_alloc_env can return NULL under memory pressure; dereferencing
// it in enif_make_tuple2 crashes the BEAM. On failure we silently drop —
// the BGTask expirationHandler will pick up the drop at the OS window
// and mark success:false, which is the honest signal (we couldn't
// deliver).
static void send_wake_fired(ErlNifPid *pid, NSString *identifier) {
  ErlNifEnv *env = enif_alloc_env();
  if (env == NULL) return;
  ERL_NIF_TERM msg = enif_make_tuple2(env,
                                      enif_make_atom(env, "wake_fired"),
                                      nsstring_to_bin(env, identifier));
  enif_send(NULL, pid, env, msg);
  enif_free_env(env);
}

// Local send helper: {:push_fired, identifier :: binary, push_id :: binary, payload_json :: binary}
// The payload arrives as the userInfo dict JSON-serialised; the Elixir
// side can decode further if it cares. Keeping it as a JSON binary
// avoids pulling a JSON library into mob_wake's runtime deps.
static void send_push_fired(ErlNifPid *pid, NSString *identifier,
                             NSString *push_id, NSString *payload_json) {
  ErlNifEnv *env = enif_alloc_env();
  if (env == NULL) return;
  ERL_NIF_TERM msg = enif_make_tuple4(env,
                                      enif_make_atom(env, "push_fired"),
                                      nsstring_to_bin(env, identifier),
                                      nsstring_to_bin(env, push_id),
                                      nsstring_to_bin(env, payload_json));
  enif_send(NULL, pid, env, msg);
  enif_free_env(env);
}

// ── ObjC-side dispatcher ─────────────────────────────────────────────

@interface MobWakeDispatcher : NSObject
+ (void)registerTaskWithIdentifier:(NSString *)identifier trigger:(NSString *)trigger;
+ (void)onTaskFired:(BGTask *)task;
// Silent APNs entry (MOB-262). Call from AppDelegate's
// `application:didReceiveRemoteNotification:fetchCompletionHandler:`.
// Requires userInfo to carry a top-level "mob_wake_id" (NSString) key;
// pushes without it are ignored and the completionHandler is called
// with .noData so iOS learns not to prioritise them.
+ (void)onPushFired:(NSDictionary *)userInfo
    completionHandler:(void (^)(UIBackgroundFetchResult))completionHandler;
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

+ (void)onPushFired:(NSDictionary *)userInfo
    completionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
  // MOB-262 minimal path. Cold-start-via-push (BEAM not yet up) is NOT
  // queued — silent APNs has a ~30s completion window that would
  // frequently miss a cold BEAM boot, so we fail fast here rather than
  // leave the user's server thinking the push landed. Cold-start-via-push
  // is a follow-up concern; the common case is a running app.
  NSString *identifier = userInfo[@"mob_wake_id"];
  if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) {
    // No routing information — call .noData so iOS's opportunistic
    // scheduler doesn't over-invest in future silent pushes for us.
    completionHandler(UIBackgroundFetchResultNoData);
    return;
  }

  if (g_mutex == NULL) {
    // NIF not loaded — can't reach BEAM at all.
    completionHandler(UIBackgroundFetchResultFailed);
    return;
  }

  ErlNifPid pid_snapshot;
  BOOL pid_valid;

  enif_mutex_lock(g_mutex);
  pid_valid = g_dispatcher_pid_set;
  if (pid_valid) pid_snapshot = g_dispatcher_pid;
  enif_mutex_unlock(g_mutex);

  if (!pid_valid) {
    // BEAM not yet ready — fail fast rather than queue with a race
    // against the ~30s window. This is the documented limitation.
    completionHandler(UIBackgroundFetchResultFailed);
    return;
  }

  // Serialize userInfo to JSON so the Elixir side sees the full payload
  // without us having to build a nested map term-by-term in ObjC.
  // NSJSONSerialization rejects some NSObject values (dates, data) but
  // silent-APNs payloads are HTTP-JSON — the round-trip is safe.
  NSError *jerr = nil;
  NSData *json = [NSJSONSerialization dataWithJSONObject:userInfo
                                                  options:0
                                                    error:&jerr];
  NSString *payload_json;
  if (json != nil) {
    payload_json = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
  } else {
    // Extremely rare — the payload didn't survive JSON round-trip.
    // Fall back to an empty object so the Elixir side sees a
    // decodable but empty payload; the identifier is what matters.
    payload_json = @"{}";
  }

  NSString *push_id = [[NSUUID UUID] UUIDString];

  enif_mutex_lock(g_mutex);
  if (g_push_completions == nil) g_push_completions = [NSMutableDictionary new];
  // Copy the block so its stack captures survive; APNs completion
  // blocks are typically already heap-allocated but copying is cheap.
  g_push_completions[push_id] = [completionHandler copy];
  enif_mutex_unlock(g_mutex);

  send_push_fired(&pid_snapshot, identifier, push_id, payload_json);
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

// ── NIF: complete_push ──────────────────────────────────────────────

static ERL_NIF_TERM nif_complete_push(ErlNifEnv *env, int argc,
                                       const ERL_NIF_TERM argv[]) {
  // complete_push(push_id :: binary, result :: :new_data | :no_data | :failed)
  ErlNifBinary id_bin;
  if (!enif_inspect_binary(env, argv[0], &id_bin) &&
      !enif_inspect_iolist_as_binary(env, argv[0], &id_bin)) {
    return enif_make_badarg(env);
  }
  char result_atom[16] = {0};
  if (!enif_get_atom(env, argv[1], result_atom, sizeof(result_atom), ERL_NIF_LATIN1)) {
    return enif_make_badarg(env);
  }

  UIBackgroundFetchResult result_val;
  if (strncmp(result_atom, "new_data", 9) == 0) {
    result_val = UIBackgroundFetchResultNewData;
  } else if (strncmp(result_atom, "no_data", 8) == 0) {
    result_val = UIBackgroundFetchResultNoData;
  } else if (strncmp(result_atom, "failed", 7) == 0) {
    result_val = UIBackgroundFetchResultFailed;
  } else {
    return enif_make_badarg(env);
  }

  NSString *push_id = [[NSString alloc] initWithBytes:id_bin.data
                                                length:id_bin.size
                                              encoding:NSUTF8StringEncoding];
  if (push_id == nil) return enif_make_badarg(env);

  void (^completion)(UIBackgroundFetchResult);
  enif_mutex_lock(g_mutex);
  completion = g_push_completions[push_id];
  if (completion != nil) [g_push_completions removeObjectForKey:push_id];
  enif_mutex_unlock(g_mutex);

  if (completion == nil) {
    // Push already completed, or complete_push was called for a push
    // that never happened. Report so Elixir sees the truth.
    return enif_make_tuple2(env,
                            enif_make_atom(env, "error"),
                            enif_make_atom(env, "no_such_push"));
  }

  completion(result_val);
  return enif_make_atom(env, "ok");
}

// ── NIF: platform_signal ─────────────────────────────────────────────

// platform_signal/0 → %{background_refresh_status: :available | :denied
//                                                  | :restricted}
// Called by Mob.Wake.status/1 to enrich the per-identifier state map
// with iOS-specific reliability signals. Wraps
// UIApplication.backgroundRefreshStatus — a system-wide setting the
// user controls in Settings → General → Background App Refresh.
// Values map directly:
//   .available   → :available
//   .denied      → :denied      (user turned it off)
//   .restricted  → :restricted  (parental controls / MDM)
static ERL_NIF_TERM nif_platform_signal(ErlNifEnv *env, int argc,
                                         const ERL_NIF_TERM argv[]) {
  (void)argc; (void)argv;
  __block const char *status_atom = "available";
  // Query on the main thread synchronously — UIApplication API access
  // is main-thread-only.
  if ([NSThread isMainThread]) {
    UIBackgroundRefreshStatus s = [UIApplication sharedApplication].backgroundRefreshStatus;
    if (s == UIBackgroundRefreshStatusDenied) status_atom = "denied";
    else if (s == UIBackgroundRefreshStatusRestricted) status_atom = "restricted";
  } else {
    dispatch_sync(dispatch_get_main_queue(), ^{
      UIBackgroundRefreshStatus s = [UIApplication sharedApplication].backgroundRefreshStatus;
      if (s == UIBackgroundRefreshStatusDenied) status_atom = "denied";
      else if (s == UIBackgroundRefreshStatusRestricted) status_atom = "restricted";
    });
  }

  ERL_NIF_TERM map = enif_make_new_map(env);
  ERL_NIF_TERM out;
  enif_make_map_put(env, map,
                    enif_make_atom(env, "background_refresh_status"),
                    enif_make_atom(env, status_atom),
                    &out);
  return out;
}

// ── NIF: schedule ────────────────────────────────────────────────────

static ERL_NIF_TERM nif_schedule(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
  // schedule(identifier :: binary,
  //          trigger :: atom,
  //          earliest_ms :: non_neg_integer,
  //          requires_charging :: bool,
  //          requires_unmetered :: bool)
  //   → :ok | {:error, reason}
  //
  // Elixir side has flattened the opts keyword list into explicit
  // args (see Mob.Wake.flatten_opts/1) — the NIF stays a dumb
  // dispatcher. Constraints are wired only on BGProcessingTaskRequest;
  // BGAppRefreshTaskRequest doesn't accept them and they're silently
  // ignored (matches WorkManager's Android side).
  ErlNifBinary id_bin;
  if (!enif_inspect_binary(env, argv[0], &id_bin) &&
      !enif_inspect_iolist_as_binary(env, argv[0], &id_bin)) {
    return enif_make_badarg(env);
  }
  char trigger[16] = {0};
  if (!enif_get_atom(env, argv[1], trigger, sizeof(trigger), ERL_NIF_LATIN1)) {
    return enif_make_badarg(env);
  }
  long earliest_ms = 0;
  if (!enif_get_long(env, argv[2], &earliest_ms) || earliest_ms < 0) {
    return enif_make_badarg(env);
  }
  int charging = 0, unmetered = 0;
  {
    char buf[8] = {0};
    if (!enif_get_atom(env, argv[3], buf, sizeof(buf), ERL_NIF_LATIN1)) {
      return enif_make_badarg(env);
    }
    charging = (strncmp(buf, "true", 5) == 0);
  }
  {
    char buf[8] = {0};
    if (!enif_get_atom(env, argv[4], buf, sizeof(buf), ERL_NIF_LATIN1)) {
      return enif_make_badarg(env);
    }
    unmetered = (strncmp(buf, "true", 5) == 0);
  }

  if (strncmp(trigger, "push", 5) == 0) {
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
      // Constraint mapping:
      //   :charging  → requiresExternalPower
      //   :unmetered → requiresNetworkConnectivity (best iOS analogue —
      //                iOS doesn't distinguish metered vs unmetered at
      //                the API level, so a caller wanting "wifi only"
      //                asks for network + hopes cellular-only users
      //                are on Wi-Fi at the moment).
      p.requiresExternalPower = charging ? YES : NO;
      p.requiresNetworkConnectivity = unmetered ? YES : NO;
      req = p;
    } else {
      return enif_make_tuple2(env,
                              enif_make_atom(env, "error"),
                              enif_make_atom(env, "unknown_trigger"));
    }

    if (earliest_ms > 0) {
      req.earliestBeginDate =
          [NSDate dateWithTimeIntervalSinceNow:((double)earliest_ms) / 1000.0];
    }

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
    {"complete_push",       2, nif_complete_push,       0},
    {"platform_signal",     0, nif_platform_signal,     0},
    {"schedule",            5, nif_schedule,            0},
};

ERL_NIF_INIT(mob_wake_nif, nif_funcs, on_load, NULL, NULL, on_unload)
