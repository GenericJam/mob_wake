// mob_wake plugin — Android bridge.
//
// Wires WorkManager (:refresh + :processing triggers, MOB-263) and FCM
// (:push trigger, MOB-264) to the BEAM. This file covers the
// WorkManager side; FCM lands in a follow-up.
//
// Native thunks pattern (mirrors mob_sms's MobSmsBridge):
//
//   * `nativeRegister()`     — external; Zig NIF's on_load calls this
//                              back to cache the jclass + method ids.
//   * `nativeSetDispatcher`  — external; Elixir Registry calls via NIF,
//                              lets native side know where to enif_send
//                              wake events.
//   * `nativeDeliverWake`    — external; called from Kotlin when a
//                              Worker fires, sends {:wake_fired, id}
//                              to the dispatcher pid or queues if not
//                              yet set.
//   * `nativeSchedule`       — Elixir Registry → NIF → JNI to enqueue a
//                              OneTimeWorkRequest / PeriodicWorkRequest.
//
// Coroutine flow when a Worker fires:
//
//   MobWakeWorker.doWork()  (suspend fn)
//     → MobWakeBridge.awaitBeamDispatch(identifier)
//         → register a CompletableDeferred keyed by identifier
//         → nativeDeliverWake(identifier)  // Zig NIF → BEAM
//         → withTimeoutOrNull { deferred.await() }
//     ← Result.success | Result.failure | Result.retry
//
// The BEAM side eventually calls complete_task/2 NIF, whose Zig thunk
// calls back into MobWakeBridge.completeWork(identifier, success).
// That completes the deferred and the Worker's doWork returns.
package io.mob.wake

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.ListenableWorker
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

object MobWakeBridge {
    // Per-identifier pending work registry. WorkManager gives us "one
    // in flight per identifier" semantics via ExistingWorkPolicy.REPLACE
    // when enqueueing — but if we've somehow ended up with a stale entry
    // we clean up on complete regardless.
    private val pendingWork = ConcurrentHashMap<String, CompletableDeferred<ListenableWorker.Result>>()

    // App context stash — needed for WorkManager.getInstance(context) at
    // schedule time. Set by mob's Application init flow via the standard
    // MobActivityAware / MobContextAware surface. If not set at
    // schedule time, we fall back to trying to find the singleton
    // WorkManager instance (works on API 21+ apps that opted into
    // WorkManager's default initializer).
    @Volatile private var appContext: Context? = null

    fun setAppContext(ctx: Context) {
        appContext = ctx.applicationContext
    }

    @JvmStatic external fun nativeRegister()
    // NIF → JNI thunks the Zig side exports.
    @JvmStatic external fun nativeDeliverWake(identifier: String)
    @JvmStatic external fun nativeDeliverPush(identifier: String, pushId: String, payloadJson: String)
    @JvmStatic external fun nativeDeliverFcmToken(token: String)

    /** MobWakeFcmService.onMessageReceived reaches here. Fire-and-forget. */
    @JvmStatic
    fun onPushFired(identifier: String, payloadJson: String) {
        // Native side generates its own push_id (matches the iOS shape
        // where multiple in-flight pushes for one identifier are
        // supported). FCM has no completion callback so complete_push
        // is a no-op on Android, but we keep the shape so the Elixir
        // Registry can handle both platforms uniformly.
        nativeDeliverPush(identifier, java.util.UUID.randomUUID().toString(), payloadJson)
    }

    /** MobWakeFcmService.onNewToken reaches here. */
    @JvmStatic
    fun onFcmTokenRefresh(token: String) {
        nativeDeliverFcmToken(token)
    }

    /**
     * Called from the Zig NIF's platform_signal thunk. Returns two flags:
     *
     *   * `batteryOptimized` — true if the app is subject to Android's
     *     battery-optimization list (i.e. OS may throttle background
     *     work aggressively). false when the user has whitelisted us via
     *     Settings → Battery → Battery Optimization → not-optimized.
     *   * `hasContext` — false when the bridge hasn't been given an app
     *     context yet; the query can't run in that state.
     *
     * Returns a packed long: bit 0 = batteryOptimized, bit 1 = hasContext.
     * Simpler than a full JNI object return; Zig decodes into the map.
     */
    @JvmStatic
    fun platformSignal(): Long {
        val ctx = appContext ?: return 0L  // hasContext=false, everything else 0
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
            ?: return 0b10L  // hasContext=true, batteryOptimized=false (unknown)
        val optimized = if (android.os.Build.VERSION.SDK_INT >= 23) {
            !pm.isIgnoringBatteryOptimizations(ctx.packageName)
        } else {
            false
        }
        var bits = 0b10L  // hasContext
        if (optimized) bits = bits or 0b01L
        return bits
    }

    /** Called by MobWakeWorker to hand control to BEAM and await result. */
    suspend fun awaitBeamDispatch(identifier: String): ListenableWorker.Result {
        val deferred = CompletableDeferred<ListenableWorker.Result>()

        // putIfAbsent so a concurrent Worker for the same identifier
        // can't overwrite an in-flight deferred. WorkManager's
        // ExistingWorkPolicy.REPLACE normally prevents this — but
        // during a replace, the outgoing Worker's doWork may still be
        // running while the incoming one starts. Losing the outgoing
        // deferred would leak it to the 9-minute timeout without ever
        // being completed by Elixir.
        val prior = pendingWork.putIfAbsent(identifier, deferred)
        if (prior != null) {
            // Existing dispatch in flight for this identifier. Tell
            // WorkManager to retry us — by then the prior one should
            // have completed and released the slot.
            return ListenableWorker.Result.retry()
        }

        // Ship to BEAM. The Zig thunk either enif_sends immediately or
        // queues for BEAM to drain at boot; either way the deferred
        // sits and waits until complete_task fires.
        nativeDeliverWake(identifier)

        // 9 minutes — a bit under WorkManager's practical 10-minute
        // upper bound for a single Worker, so we surface a timeout
        // before WorkManager kills us and mis-attributes the failure.
        val result = withTimeoutOrNull(9L * 60L * 1000L) { deferred.await() }
        // Remove ONLY if the entry is still this deferred — completeWork
        // may already have removed it. remove(key, expectedValue) is
        // the atomic compare-and-remove; a mismatch means someone else
        // already completed us and we shouldn't clobber their state.
        pendingWork.remove(identifier, deferred)
        return result ?: ListenableWorker.Result.failure()
    }

    /** Called from Zig NIF's complete_task thunk. */
    @JvmStatic
    fun completeWork(identifier: String, success: Boolean) {
        val deferred = pendingWork.remove(identifier) ?: return
        deferred.complete(
            if (success) ListenableWorker.Result.success() else ListenableWorker.Result.failure()
        )
    }

    /** Called from Zig NIF's complete_task thunk when Elixir returned {:error, :retry}. */
    @JvmStatic
    fun retryWork(identifier: String) {
        val deferred = pendingWork.remove(identifier) ?: return
        deferred.complete(ListenableWorker.Result.retry())
    }

    /**
     * Enqueue a wake with WorkManager. Called from Zig NIF's schedule
     * thunk (which is what Elixir's `Mob.Wake.schedule/2` reaches).
     *
     * @param identifier the mob_wake task identifier — also used as the
     *   unique work name so re-enqueue REPLACES the prior one (matches
     *   Elixir's semantics where schedule/2 supersedes a prior pending).
     * @param trigger `"refresh"` or `"processing"`. `"push"` should have
     *   been rejected earlier; if it slips through we return false.
     * @param earliestDelayMs delay before eligibility (0 = ASAP).
     * @param requiresCharging honored on :processing only, ignored on
     *   :refresh (WorkManager itself would accept it but it clashes
     *   with the :refresh semantic of "when the user might open the app").
     * @param requiresUnmetered same as above.
     */
    @JvmStatic
    fun scheduleWork(
        identifier: String,
        trigger: String,
        earliestDelayMs: Long,
        requiresCharging: Boolean,
        requiresUnmetered: Boolean
    ): Boolean {
        val ctx = appContext ?: return false
        if (trigger == "push") return false
        if (trigger != "refresh" && trigger != "processing") return false

        val input = Data.Builder().putString(KEY_IDENTIFIER, identifier).build()

        val builder = OneTimeWorkRequestBuilder<MobWakeWorker>()
            .setInputData(input)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)

        if (earliestDelayMs > 0) {
            builder.setInitialDelay(earliestDelayMs, TimeUnit.MILLISECONDS)
        }

        if (trigger == "processing") {
            val constraints = Constraints.Builder()
                .setRequiresCharging(requiresCharging)
                .setRequiredNetworkType(if (requiresUnmetered) NetworkType.UNMETERED else NetworkType.CONNECTED)
                .build()
            builder.setConstraints(constraints)
        }

        WorkManager.getInstance(ctx).enqueueUniqueWork(
            identifier,
            ExistingWorkPolicy.REPLACE,
            builder.build()
        )
        return true
    }

    const val KEY_IDENTIFIER = "mob_wake_identifier"
    // Server-side FCM data-message convention: the identifier lives under
    // this data-map key. Mirrors iOS's userInfo["mob_wake_id"].
    const val KEY_FCM_ID = "mob_wake_id"
}
