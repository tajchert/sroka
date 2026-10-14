package app.sroka.feature.auth.impl.navigation

import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
import app.sroka.feature.auth.api.AuthKey
import app.sroka.feature.auth.impl.AuthRoute

/**
 * Sign-in entries. Navigation after a successful sign-in is driven by the app observing
 * `AuthRepository.session`, so this feature needs no navigation callbacks.
 */
fun EntryProviderScope<NavKey>.authEntries() {
    entry<AuthKey> { AuthRoute() }
}
