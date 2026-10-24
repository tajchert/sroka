package app.sroka.navigation

/**
 * Pure anchor bookkeeping for the list/detail divider (R14.3). The anchors are laid out as
 * [COLLAPSED_INDEX] (list pane at 0dp) followed by the R13 snap points; [DEFAULT_LIST_INDEX] is 360dp.
 */
internal const val COLLAPSED_INDEX = 0
internal const val DEFAULT_LIST_INDEX = 2

/** Index "Show list" returns to: the anchor remembered before collapsing, never the collapsed one. */
internal fun restoreIndex(previous: Int, anchorCount: Int): Int =
    if (previous in (COLLAPSED_INDEX + 1) until anchorCount) previous else DEFAULT_LIST_INDEX

/** Index to remember while the divider rests at [current]: collapsed (or unknown, -1) keeps [previous]. */
internal fun rememberedIndex(current: Int, previous: Int): Int =
    if (current > COLLAPSED_INDEX) current else previous
