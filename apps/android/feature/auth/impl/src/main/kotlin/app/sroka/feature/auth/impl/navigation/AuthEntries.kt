package app.sroka.feature.auth.impl.navigation

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
import app.sroka.feature.auth.api.AuthKey
import app.sroka.feature.auth.impl.R

/**
 * Sign-in entries. Navigation after a successful sign-in is driven by the app observing
 * `AuthRepository.session`, so this feature needs no navigation callbacks.
 */
fun EntryProviderScope<NavKey>.authEntries() {
    entry<AuthKey> {
        // Placeholder until the auth feature is implemented.
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.feature_auth_title))
        }
    }
}
