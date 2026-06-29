package com.unitrack.sdk

/**
 * Conformed by analytics providers that also expose a remote-config bag
 * (vd FirebaseAdapter built-in). [UniTrack.getRemoteValue] iterates over
 * every registered provider that implements this and returns the first
 * non-null hit.
 *
 * Lives in the core unitrack module (host app supplies Firebase deps) so the
 * resolver can reference the type without dragging in any third-party SDK.
 */
interface RemoteValueProvider {
    /** Look up [key] and return as [T] if available. Return null to defer
     *  to the next provider / the caller's defaultValue. */
    fun <T> getRemoteValue(key: String): T?
}
