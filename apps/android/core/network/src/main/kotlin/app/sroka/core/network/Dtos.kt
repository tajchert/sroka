package app.sroka.core.network

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/** api.md §4.1. Enum-like fields stay strings so unknown future values never break decoding. */
@Serializable
data class ItemDto(
    val id: String,
    val url: String,
    val canonicalUrl: String? = null,
    val title: String? = null,
    val excerpt: String? = null,
    val siteName: String? = null,
    val author: String? = null,
    val lang: String? = null,
    val leadImageUrl: String? = null,
    val leadImageKey: String? = null,
    val wordCount: Int? = null,
    val readingMinutes: Int? = null,
    val contentId: String? = null,
    val contentPrivate: Boolean = false,
    val parseStatus: String = "pending",
    val parseError: String? = null,
    val status: String = "unread",
    val isFavorite: Boolean = false,
    val progress: Float = 0f,
    val progressAnchor: Int? = null,
    val savedAt: Long = 0,
    val archivedAt: Long? = null,
    val lastReadAt: Long? = null,
    val source: String? = null,
    val tags: List<String> = emptyList(),
    val seq: Long = 0,
)

/** api.md §4.2 (`count` only in /v1/tags). */
@Serializable
data class TagDto(val id: String, val name: String, val count: Int? = null, val seq: Long = 0)

@Serializable
data class DeletedDto(val items: List<String> = emptyList(), val tags: List<String> = emptyList())

/** api.md §7.2. */
@Serializable
data class PullResponseDto(
    val cursor: Long,
    val hasMore: Boolean = false,
    val items: List<ItemDto> = emptyList(),
    val tags: List<TagDto> = emptyList(),
    val deleted: DeletedDto = DeletedDto(),
)

@Serializable
data class RejectedOpDto(val opId: String = "", val reason: String = "")

/** api.md §7.1. [aliases] maps client item id to the existing server item id. */
@Serializable
data class PushResponseDto(
    val applied: List<String> = emptyList(),
    val rejected: List<RejectedOpDto> = emptyList(),
    val aliases: Map<String, String> = emptyMap(),
    val cursor: Long = 0,
)

/** api.md §5.7. */
@Serializable
data class ContentUrlsDto(
    val articleUrl: String,
    val baseUrl: String,
    val packageUrl: String,
    val expiresAt: Long = 0,
)

@Serializable
data class MeUserDto(
    val id: String,
    val email: String,
    val name: String? = null,
    val emailVerified: Boolean = false,
    val createdAt: Long? = null,
)

@Serializable
data class MeStatsDto(val unread: Int = 0, val archived: Int = 0, val favorites: Int = 0, val tags: Int = 0)

@Serializable
data class MeDto(val user: MeUserDto, val stats: MeStatsDto = MeStatsDto())

@Serializable
data class MinVersionsDto(val android: Int? = null)

@Serializable
data class ConfigLimitsDto(val maxOpsPerPush: Int = 500)

/** api.md §12; only what the client uses. */
@Serializable
data class ConfigDto(
    val appOrigin: String? = null,
    val minVersions: MinVersionsDto = MinVersionsDto(),
    val limits: ConfigLimitsDto = ConfigLimitsDto(),
)

/** Result of a successful sign-in; [token] is the verbatim `set-auth-token` header value. */
data class SignInResult(val token: String, val userEmail: String)

@Serializable
internal data class SendOtpRequest(val email: String, val type: String)

@Serializable
internal data class SignInRequest(val email: String, val otp: String)

@Serializable
internal data class SignInResponse(val user: SignInUser? = null)

@Serializable
internal data class SignInUser(val email: String? = null)

@Serializable
internal data class PushRequest(val deviceId: String, val ops: List<JsonObject>)

@Serializable
internal data class DeleteAccountRequest(val confirm: String)

@Serializable
internal data class ErrorBody(val error: String? = null, val code: String? = null)
