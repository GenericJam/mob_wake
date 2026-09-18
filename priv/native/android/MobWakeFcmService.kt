// mob_wake plugin — FCM data-message receiver (MOB-264).
//
// FCM delivers data-only messages via FirebaseMessagingService.onMessageReceived,
// which runs on a worker thread with a ~10s wall-clock budget before
// Android may kill the service. The mob_wake convention is:
//
//   * The message's data map MUST contain a `mob_wake_id` key naming
//     the identifier `Mob.Wake` should dispatch under. Server-side
//     (mob_push, MOB-269) enforces this — messages without the key
//     are dropped by this service without reaching BEAM.
//
//   * The whole data map is JSON-serialised and delivered to Elixir
//     as the payload binary. Handlers decode themselves (Jason or
//     :json.decode) — mob_wake stays out of the JSON-library-dep
//     business, same reason as the iOS side.
//
//   * We DO NOT block onMessageReceived awaiting BEAM's dispatch.
//     FCM has no completion callback (unlike silent APNs on iOS), so
//     "did the app run to completion" is not something the OS or the
//     sending server can observe. Return fast; BEAM processes in its
//     own time.
//
// The service also gets `onNewToken` — the app can subscribe to
// {:mob_wake_fcm_token, token} on the dispatcher pid to receive the
// current registration token for uploading to a push server.
//
// AndroidManifest.xml (host app, until MOB-265 codegen writes this):
//
//   <service
//     android:name="io.mob.wake.MobWakeFcmService"
//     android:exported="false">
//     <intent-filter>
//       <action android:name="com.google.firebase.MESSAGING_EVENT" />
//     </intent-filter>
//   </service>
package io.mob.wake

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONObject

class MobWakeFcmService : FirebaseMessagingService() {

    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        val data = remoteMessage.data
        val identifier = data[MobWakeBridge.KEY_FCM_ID]
        if (identifier.isNullOrEmpty()) {
            // No routing information — drop silently. Sender's
            // convention says every data message MUST include the id;
            // one without it is either a bug on the sending side or
            // an unrelated FCM message (which shouldn't reach us given
            // the intent-filter, but defense in depth).
            return
        }

        val payloadJson = JSONObject(data as Map<String, Any>).toString()
        MobWakeBridge.onPushFired(identifier, payloadJson)
    }

    override fun onNewToken(token: String) {
        MobWakeBridge.onFcmTokenRefresh(token)
    }
}
