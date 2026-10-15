package app.sroka.feature.reader.api

import androidx.navigation3.runtime.NavKey
import kotlinx.serialization.Serializable

/** Reader for one saved item. */
@Serializable
data class ReaderKey(val itemId: String) : NavKey
