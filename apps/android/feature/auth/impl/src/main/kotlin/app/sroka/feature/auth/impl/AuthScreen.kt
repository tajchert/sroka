package app.sroka.feature.auth.impl

import androidx.activity.compose.BackHandler
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
        Column(
            Modifier
                .safeDrawingPadding()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(stringResource(R.string.feature_auth_title), style = MaterialTheme.typography.headlineMedium)
            when (state.step) {
                AuthStep.EMAIL -> EmailStep(state, onEmailChange, onSendCode)
                AuthStep.CODE -> {
                    BackHandler(onBack = onChangeEmail)
                    CodeStep(state, onCodeChange, onResend, onChangeEmail)
                }
            }
            if (state.loading) {
                CircularProgressIndicator(Modifier.size(28.dp))
            }
            TextButton(onClick = onOpenServer) {
                Text(stringResource(R.string.feature_auth_change_server))
            }
        }
    }
    if (state.serverDialogOpen) {
        ServerDialog(state, onDismissServer, onSaveServer)
    }
}

@Composable
private fun EmailStep(state: AuthUiState, onEmailChange: (String) -> Unit, onSendCode: () -> Unit) {
    Text(stringResource(R.string.feature_auth_email_hint), style = MaterialTheme.typography.bodyLarge)
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
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email, imeAction = ImeAction.Send),
        keyboardActions = KeyboardActions(onSend = { onSendCode() }),
    )
    Button(
        onClick = onSendCode,
        enabled = !state.loading && state.email.isNotBlank(),
        modifier = Modifier.fillMaxWidth(),
    ) { Text(stringResource(R.string.feature_auth_send_code)) }
}

@Composable
private fun CodeStep(
    state: AuthUiState,
    onCodeChange: (String) -> Unit,
    onResend: () -> Unit,
    onChangeEmail: () -> Unit,
) {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    Text(stringResource(R.string.feature_auth_code_hint, state.email), style = MaterialTheme.typography.bodyLarge)
    OutlinedTextField(
        value = state.code,
        onValueChange = onCodeChange,
        modifier = Modifier
            .fillMaxWidth()
            .focusRequester(focus)
            .semantics { contentType = ContentType.SmsOtpCode },
        label = { Text(stringResource(R.string.feature_auth_code_label)) },
        singleLine = true,
        enabled = !state.loading,
        isError = state.error != null,
        supportingText = { ErrorText(state.error) },
        textStyle = MaterialTheme.typography.headlineSmall,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { onCodeChange(state.code) }),
    )
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

@Composable
private fun ErrorText(error: AuthError?) {
    if (error == null) return
    val text = when (error) {
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
    Text(text)
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
