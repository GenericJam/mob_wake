# ADR: Identifier + payload schema for cross-platform silent-push wake

**Date:** 2026-09-18
**Status:** Accepted
**Linear:** [MOB-269](https://linear.app/mobframework/issue/MOB-269)

## Context

`mob_wake` (this plugin) receives silent-push wake events from `mob_push` (already on Hex 0.2, the server-side APNs + FCM library). Both platforms need a consistent way to name *which* `Mob.Wake` handler a push should dispatch to. Without a fixed convention, sender code has to fork per-platform and receiver code has to know both routing shapes.

## Decision

**One string key: `mob_wake_id`. Same key on iOS and Android. Top-level in the send-side payload's data map. Case-sensitive.**

The identifier itself is the string form of the atom used in `config :mob_wake, :tasks`:

    config :mob_wake, tasks: [
      {:sync_notes, MyApp.BackgroundJobs, :sync_notes, :push}
    ]

    # server-side (mob_push)
    MobPush.send(token, :ios,
      MobWake.wake_payload(:sync_notes, data: %{"peer" => "abc"}))

    MobPush.send(token, :android,
      MobWake.wake_payload(:sync_notes, data: %{"peer" => "abc"}))

## Concrete payload shapes

### iOS silent APNs (via `mob_push`)

    %{
      title: " ",
      body: " ",
      content_available: true,
      data: %{
        "mob_wake_id" => "sync_notes",
        "peer" => "abc"
      }
    }

Which `mob_push`'s APNS module encodes as:

    {
      "aps": {
        "alert": {"title": " ", "body": " "},
        "content-available": 1
      },
      "mob_wake_id": "sync_notes",
      "peer": "abc"
    }

Receive-side (`mob_wake` on the device): `MobWakeDispatcher.onPushFired:completionHandler:` reads `userInfo["mob_wake_id"]`, routes to the registered handler.

### Android FCM data

    %{
      title: " ",
      body: " ",
      content_available: true,
      data: %{
        "mob_wake_id" => "sync_notes",
        "peer" => "abc"
      }
    }

`mob_push`'s FCM module sends this as a data-only message (`content_available: true` translates to `priority: HIGH` for wake-through-Doze). Receive-side: `MobWakeFcmService.onMessageReceived` reads `data["mob_wake_id"]`, routes.

## Why this shape

* **One key across both platforms.** APNs and FCM structure differ (APNs has `aps` object + top-level userInfo keys; FCM has a flat `data` map), but the key `mob_wake_id` is under the same effective root in both cases from the receiver's perspective. No platform gate on the send side.
* **String not atom.** Atoms don't round-trip through JSON. String form is `Atom.to_string(:sync_notes)` — matches how the identifier is delivered to the receive-side handlers already.
* **`data` merge, not a nested `mob_wake` object.** Keeps the payload flat and inspectable in server logs. Application-specific data keys sit alongside `mob_wake_id` without conflicts (unless an app names its own key `mob_wake_id`, which the `wake_payload/2` helper overrides deliberately).
* **`title` + `body` defaulted to a single space.** `mob_push`'s APNS module requires both (pattern-matched on payload). A single space keeps the push technically valid without visible content. Apps that want a hybrid silent+visible push override.
* **Case-sensitive.** Both platforms deliver JSON key names verbatim; matching them exactly is cheaper than lowercasing on both sides.

## What we're giving up

* **Signing.** MOB-269's issue title mentions "identifier schema, signing" — this ADR covers the identifier schema. Signed payloads (so the receiver knows the `mob_wake_id` came from a trusted sender and hasn't been forged by another app or an on-device attacker) is a follow-up. The receive-side threat model right now is "trust the OS + trust the APNs/FCM channel"; that's the same threat model every silent-push app implicitly uses.
* **Payload schema evolution.** Adding new top-level keys to the payload is backwards-compatible (the receiver ignores unknown keys). Renaming `mob_wake_id` would be breaking; anchoring it in this ADR is what makes the rename cost visible.
* **`mob_push` cross-reference is one-way (mob_wake → mob_push).** `mob_push` doesn't currently know about `mob_wake`. That's fine — the sender doesn't need to; it just needs to accept a payload with `mob_wake_id` in the data map, which its existing `send/3` API already does. If a `MobPush.wake/3` convenience helper turns out to be worth it, it lands in `mob_push` as a thin wrapper over `MobWake.wake_payload/2`.

## Consequences

* `MobWake.wake_payload/2` is the canonical builder — sender code that composes payloads by hand should be replaced with this helper.
* iOS `MobWakeDispatcher.onPushFired:` and Android `MobWakeFcmService.onMessageReceived` both key on `mob_wake_id` — matches this ADR. Changing that key requires updating three places (this ADR, both native handlers, and the Elixir helper).
* `MobWake.wake_payload/2`'s spec is `identifier :: atom() → map()` — an atom identifier at the call site, string at the wire, matches the receiver's atom lookup. If a caller needs to send to an identifier they only have as a string (e.g. dynamic), they cast: `String.to_existing_atom(id) |> MobWake.wake_payload(opts)`.
