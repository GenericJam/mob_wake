// mob_wake plugin — WorkManager Worker.
//
// WorkManager's default WorkerFactory constructs this via the standard
// (Context, WorkerParameters) constructor, so no custom
// Configuration.Provider on the host Application is required. Public
// constructor is mandatory — WorkManager reflects.
//
// `doWork` reads the identifier from inputData (put there by
// `MobWakeBridge.scheduleWork`), hands off to the bridge's coroutine,
// and returns the bridge's result verbatim. All the interesting logic
// lives on the bridge side; this file is a thin adapter.
package io.mob.wake

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters

class MobWakeWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val identifier = inputData.getString(MobWakeBridge.KEY_IDENTIFIER)
            ?: return Result.failure()

        // Ensure the bridge has an app context — safe to call
        // idempotently. WorkManager may fire us before the mob
        // Application has run its Context setup, so we self-heal here.
        MobWakeBridge.setAppContext(applicationContext)

        return MobWakeBridge.awaitBeamDispatch(identifier)
    }
}
