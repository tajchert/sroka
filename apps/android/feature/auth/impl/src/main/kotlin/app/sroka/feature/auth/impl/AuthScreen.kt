package app.sroka.feature.auth.impl

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.ui.Alignment
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import app.sroka.core.designsystem.component.SrokaMark
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.sroka.core.domain.AuthError

@Composable
fun AuthRoute(viewModel: AuthViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    AuthScreen(
        state = state,
        onEmailChange = viewModel::onEmailChange,
        onSendCode = viewModel::sendCode,
        onCodeChange = viewModel::onCodeChange,
        onResend = viewModel::resend,
        onChangeEmail = viewModel::changeEmail,
        onOpenServer = viewModel::openServerDialog,
        onDismissServer = viewModel::dismissServerDialog,
        onSaveServer = viewModel::saveServerUrl,
    )
}

@Composable
fun AuthScreen(
    state: AuthUiState,
    onEmailChange: (String) -> Unit,
    onSendCode: () -> Unit,
    onCodeChange: (String) -> Unit,
    onResend: () -> Unit,
    onChangeEmail: () -> Unit,
    onOpenServer: () -> Unit,
    onDismissServer: () -> Unit,
    onSaveServer: (String) -> Unit,
) {
    Surface(Modifier.fillMaxSize()) {
        when (state.step) {
            AuthStep.EMAIL -> EmailStep(state, onEmailChange, onSendCode, onOpenServer)
            AuthStep.CODE -> {
                BackHandler(onBack = onChangeEmail)
                CodeStep(state, onCodeChange, onResend, onChangeEmail)
            }
        }
    }
    if (state.serverDialogOpen) {
        ServerDialog(state, onDismissServer, onSaveServer)
    }
}

@Composable
private fun EmailStep(
    state: AuthUiState,
    onEmailChange: (String) -> Unit,
    onSendCode: () -> Unit,
    onOpenServer: () -> Unit,
) {
    Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(start = 24.dp, end = 24.dp, top = 64.dp),
            verticalArrangement = Arrangement.spacedBy(32.dp),
        ) {
            SrokaMark(size = 64.dp)
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.feature_auth_title), style = MaterialTheme.typography.headlineLarge)
                Text(
                    stringResource(R.string.feature_auth_email_hint),
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            OutlinedTextField(
                value = state.email,
                onValueChange = onEmailChange,
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics { contentType = ContentType.EmailAddress },
                label = { Text(stringResource(R.string.feature_auth_email_label)) },
                singleLine = true,
                enabled = !state.loading,
                isError = state.error != null,
                supportingText = { ErrorText(state.error) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { onSendCode() }),
            )
            Button(
                onClick = onSendCode,
                enabled = !state.loading && state.email.isNotBlank(),
                modifier = Modifier.fillMaxWidth().height(48.dp),
            ) {
                if (state.loading) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                } else {
                    Text(stringResource(R.string.feature_auth_send_code))
                }
            }
        }
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        ListItem(
            modifier = Modifier.padding(horizontal = 8.dp),
            colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            leadingContent = {
                Icon(
                    Icons.Rounded.Dns,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            },
            headlineContent = { Text(stringResource(R.string.feature_auth_server_row)) },
            supportingContent = { Text(serverHost(state.serverUrl)) },
            trailingContent = {
                TextButton(onClick = onOpenServer) { Text(stringResource(R.string.feature_auth_change_server)) }
            },
        )
    }
}

internal fun serverHost(url: String): String =
    runCatching { java.net.URI(url.trim()).host }.getOrNull()?.takeIf { it.isNotEmpty() } ?: url

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CodeStep(
    state: AuthUiState,
    onCodeChange: (String) -> Unit,
    onResend: () -> Unit,
    onChangeEmail: () -> Unit,
) {
    Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
        TopAppBar(
            title = {},
            navigationIcon = {
                IconButton(onClick = onChangeEmail) {
                    Icon(
                        Icons.AutoMirrored.Rounded.ArrowBack,
                        contentDescription = stringResource(R.string.feature_auth_back),
                    )
                }
            },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
        )
        Column(
            Modifier
                .verticalScroll(rememberScrollState())
                .padding(start = 24.dp, end = 24.dp, top = 8.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.feature_auth_code_title), style = MaterialTheme.typography.headlineMedium)
                val full = stringResource(R.string.feature_auth_code_hint, state.email)
                val emphasised = remember(full, state.email) {
                    buildAnnotatedString {
                        append(full)
                        val i = full.lastIndexOf(state.email)
                        if (i >= 0 && state.email.isNotEmpty()) {
                            addStyle(SpanStyle(fontWeight = FontWeight.Medium), i, i + state.email.length)
                        }
                    }
                }
                Text(
                    emphasised,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OtpInput(
                    code = state.code,
                    onCodeChange = onCodeChange,
                    readOnly = state.loading,
                    isError = state.error != null,
                    refocusKey = state.error,
                )
                if (state.loading) {
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                }
                if (state.error != null) {
                    Text(
                        errorMessage(state.error),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            }
            Row(Modifier.offset(x = (-12).dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = onResend, enabled = !state.loading && state.resendSeconds == 0) {
                    Text(
                        if (state.resendSeconds > 0) {
                            stringResource(R.string.feature_auth_resend_in, state.resendSeconds)
                        } else {
                            stringResource(R.string.feature_auth_resend)
                        },
                    )
                }
                TextButton(onClick = onChangeEmail) { Text(stringResource(R.string.feature_auth_change_email)) }
            }
        }
    }
}

/** One hidden text field rendered as [CODE_LENGTH] boxes; digits only. */
@Composable
internal fun OtpInput(
    code: String,
    onCodeChange: (String) -> Unit,
    readOnly: Boolean,
    isError: Boolean,
    refocusKey: Any?,
) {
    val focus = remember { FocusRequester() }
    var focused by remember { mutableStateOf(false) }
    LaunchedEffect(refocusKey) { runCatching { focus.requestFocus() } }
    val a11y = stringResource(R.string.feature_auth_code_a11y)
    BasicTextField(
        value = code,
        onValueChange = { onCodeChange(it) },
        modifier = Modifier
            .fillMaxWidth()
            .testTag(OTP_TAG)
            .focusRequester(focus)
            .onFocusChanged { focused = it.isFocused }
            .semantics {
                contentType = ContentType.SmsOtpCode
                contentDescription = a11y
            },
        readOnly = readOnly,
        singleLine = true,
        textStyle = TextStyle(color = Color.Transparent),
        cursorBrush = SolidColor(Color.Transparent),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
        decorationBox = {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                val active = code.length.coerceAtMost(CODE_LENGTH - 1)
                repeat(CODE_LENGTH) { i ->
                    val isFocused = focused && i == active
                    val border = when {
                        isError -> MaterialTheme.colorScheme.error
                        isFocused -> MaterialTheme.colorScheme.primary
                        i < code.length -> MaterialTheme.colorScheme.onSurfaceVariant
                        else -> MaterialTheme.colorScheme.outline
                    }
                    Box(
                        Modifier
                            .weight(1f)
                            .height(56.dp)
                            .background(
                                if (isFocused) MaterialTheme.colorScheme.surfaceContainer else Color.Transparent,
                                RoundedCornerShape(12.dp),
                            )
                            .border(if (isFocused) 2.dp else 1.dp, border, RoundedCornerShape(12.dp)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            code.getOrNull(i)?.toString().orEmpty(),
                            style = MaterialTheme.typography.headlineSmall,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                    }
                }
            }
        },
    )
}

internal const val OTP_TAG = "otp_input"

@Composable
private fun ErrorText(error: AuthError?) {
    if (error != null) Text(errorMessage(error))
}

@Composable
private fun errorMessage(error: AuthError): String = when (error) {
    AuthError.InvalidEmail -> stringResource(R.string.feature_auth_error_invalid_email)
    AuthError.InvalidCode -> stringResource(R.string.feature_auth_error_invalid_code)
    AuthError.CodeExpired -> stringResource(R.string.feature_auth_error_expired)
    AuthError.TooManyAttempts -> stringResource(R.string.feature_auth_error_too_many)
    is AuthError.RateLimited -> error.retryAfterSeconds?.let {
        pluralStringResource(R.plurals.feature_auth_error_rate_limited_seconds, it.toInt(), it.toInt())
    } ?: stringResource(R.string.feature_auth_error_rate_limited)
    AuthError.Network -> stringResource(R.string.feature_auth_error_network)
    AuthError.Server -> stringResource(R.string.feature_auth_error_server)
}

@Composable
private fun ServerDialog(state: AuthUiState, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var value by rememberSaveable { mutableStateOf(state.serverUrl) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.feature_auth_server_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.feature_auth_server_body))
                OutlinedTextField(
                    value = value,
                    onValueChange = { value = it },
                    singleLine = true,
                    isError = state.serverUrlInvalid,
                    label = { Text(stringResource(R.string.feature_auth_server_label)) },
                    supportingText = {
                        if (state.serverUrlInvalid) Text(stringResource(R.string.feature_auth_server_invalid))
                    },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { onSave(value) }),
                )
            }
        },
        confirmButton = { TextButton(onClick = { onSave(value) }) { Text(stringResource(R.string.feature_auth_save)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.feature_auth_cancel)) } },
    )
}
