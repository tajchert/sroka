package app.sroka.navigation

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import app.sroka.R
import app.sroka.core.designsystem.theme.srokaColors

/** One tab of [SrokaRail]. */
data class RailDestination(
    val label: String,
    val icon: ImageVector,
    val selectedIcon: ImageVector,
)

/**
 * The 96dp navigation rail for wide windows (R13, screen 17): the "Save link" FAB on top, the four
 * tabs (56x32 indicator, filled icon when selected) and the account avatar at the bottom, which opens
 * Settings. Stateless: [selectedIndex] is the highlighted destination (or -1).
 */
@Composable
fun SrokaRail(
    destinations: List<RailDestination>,
    selectedIndex: Int,
    avatarLetter: String,
    onSaveLink: () -> Unit,
    onSelect: (index: Int) -> Unit,
    onOpenSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    NavigationRail(
        modifier = modifier.width(RailWidth),
        containerColor = scheme.background,
        header = { SaveLinkButton(onSaveLink, Modifier.padding(top = 8.dp, bottom = 20.dp)) },
    ) {
        destinations.forEachIndexed { index, destination ->
            val selected = index == selectedIndex
            NavigationRailItem(
                selected = selected,
                onClick = { onSelect(index) },
                icon = {
                    Icon(
                        imageVector = if (selected) destination.selectedIcon else destination.icon,
                        contentDescription = null,
                    )
                },
                label = { Text(destination.label) },
                alwaysShowLabel = true,
                colors = NavigationRailItemDefaults.colors(
                    indicatorColor = scheme.primaryContainer,
                    selectedIconColor = scheme.onPrimaryContainer,
                    selectedTextColor = scheme.onPrimaryContainer,
                ),
            )
        }
        Spacer(Modifier.weight(1f))
        RailAvatar(avatarLetter, onOpenSettings, Modifier.padding(bottom = 16.dp))
    }
}

/** The 56dp brand FAB (16dp corners) shown at the top of the rail. */
@Composable
fun SaveLinkButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    val brand = MaterialTheme.srokaColors
    Surface(
        onClick = onClick,
        modifier = modifier.size(56.dp),
        shape = RoundedCornerShape(16.dp),
        color = brand.brand,
        contentColor = brand.onBrand,
        shadowElevation = 6.dp,
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.Add, contentDescription = stringResource(R.string.nav_save_link))
        }
    }
}

/** 36dp primaryContainer circle with the first letter of the account email. */
@Composable
fun RailAvatar(letter: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val label = stringResource(R.string.nav_settings)
    Box(
        modifier
            .size(36.dp)
            .background(MaterialTheme.colorScheme.primaryContainer, CircleShape)
            .clickable(onClick = onClick, role = Role.Button, onClickLabel = label),
        contentAlignment = Alignment.Center,
    ) {
        Text(letter, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onPrimaryContainer)
    }
}

/** The 4x48dp pane drag handle drawn in the gutter between list and detail (R13). */
@Composable
fun PaneDividerHandle(modifier: Modifier = Modifier) {
    // The outer box is the (invisible) touch target the drag modifier is applied to; the pill is
    // drawn inside it so a minimum-size modifier cannot stretch the visible handle.
    Box(modifier, contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .width(4.dp)
                .height(48.dp)
                .background(MaterialTheme.colorScheme.outline, RoundedCornerShape(2.dp)),
        )
    }
}

/** Rail width from the mock (R13). */
val RailWidth = 96.dp

/** First letter of the account email, upper-cased; "?" when unknown. */
internal fun railAvatarLetter(email: String): String =
    email.trim().firstOrNull { it.isLetterOrDigit() }?.uppercase() ?: "?"
