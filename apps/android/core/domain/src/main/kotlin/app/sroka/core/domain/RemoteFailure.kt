package app.sroka.core.domain

/** Why a network-backed operation failed; mapped to string resources in the UI. */
enum class RemoteFailure {
    /** No connection / timeout. */
    NETWORK,

    /** Session expired (401). */
    UNAUTHORIZED,

    /** 429; try again later. */
    RATE_LIMITED,

    /** 5xx or an unexpected response. */
    SERVER,
}
