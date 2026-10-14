package app.sroka.feature.auth.api

import androidx.navigation3.runtime.NavKey
import kotlinx.serialization.Serializable

/** Sign-in flow (email → code). The app shows it whenever the session is signed out. */
@Serializable
data object AuthKey : NavKey
