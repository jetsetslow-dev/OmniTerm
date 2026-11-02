package com.jetsetslow.omniterm.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.fido.SecurityKeyCtap
import com.yubico.yubikit.android.YubiKitManager
import com.yubico.yubikit.android.transport.nfc.NfcConfiguration
import com.yubico.yubikit.android.transport.nfc.NfcNotAvailable
import com.yubico.yubikit.android.transport.usb.DeviceFilter
import com.yubico.yubikit.android.transport.usb.UsbConfiguration
import com.yubico.yubikit.android.transport.usb.UsbYubiKeyDevice
import com.yubico.yubikit.core.YubiKeyDevice
import com.yubico.yubikit.core.application.ApplicationNotAvailableException
import com.yubico.yubikit.core.application.CommandState
import com.yubico.yubikit.core.fido.FidoConnection
import com.yubico.yubikit.core.smartcard.SmartCardConnection
import com.yubico.yubikit.fido.ctap.Ctap2Session
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** Any USB device with a plain HID interface: where FIDO keys of every maker answer. yubikit checks for FIDO itself. */
private object FidoHidFilter : DeviceFilter() {
    override fun checkUsbDevice(usbManager: UsbManager, usbDevice: UsbDevice): Boolean =
        (0 until usbDevice.interfaceCount).any {
            val usbInterface = usbDevice.getInterface(it)
            usbInterface.interfaceClass == UsbConstants.USB_CLASS_HID && usbInterface.interfaceSubclass == 0
        }
}

private tailrec fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}

/**
 * Finds the user's security key over USB or NFC while a security key job waits
 * ([AppViewModel.pendingSecurityKey]), asking for the key's PIN when it wants one. Hosted by
 * MainAppScreen with the sign-in dialogs, since Test connection and Files sign in too.
 */
@Composable
fun SecurityKeyDialog(viewModel: AppViewModel) {
    val pending = viewModel.pendingSecurityKey ?: return
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var pin by remember(pending) { mutableStateOf("") }
    var askPin by remember(pending) { mutableStateOf(pending.pinUpFront) }
    var problem by remember(pending) { mutableStateOf<String?>(null) }
    var working by remember(pending) { mutableStateOf(false) }
    var touchNow by remember(pending) { mutableStateOf(false) }
    var nfcOff by remember(pending) { mutableStateOf(false) }
    var nfcAvailable by remember(pending) { mutableStateOf(true) }
    // The plugged-in key, for Continue once its PIN is typed.
    var usbKey by remember(pending) { mutableStateOf<UsbYubiKeyDevice?>(null) }
    val state = remember(pending) {
        object : CommandState() {
            override fun onKeepAliveStatus(status: Byte) {
                if (status == STATUS_UPNEEDED) scope.launch(Dispatchers.Main) { touchNow = true }
            }
        }
    }
    fun finished(outcome: Result<Any>) = scope.launch(Dispatchers.Main) {
        working = false
        touchNow = false
        outcome.onSuccess { viewModel.finishSecurityKey(pending, it) }
        outcome.onFailure { e ->
            problem = when (e) {
                is SecurityKeyCtap.PinNeeded -> {
                    askPin = true
                    pin = ""
                    when {
                        !e.wrongPin -> context.getString(R.string.security_key_pin_needed)
                        e.retries != null -> context.getString(R.string.security_key_pin_wrong_tries, e.retries)
                        else -> context.getString(R.string.security_key_pin_wrong)
                    }
                }
                is SecurityKeyCtap.Failure -> e.message
                is ApplicationNotAvailableException -> context.getString(R.string.security_key_not_fido2)
                else -> context.getString(R.string.security_key_failed, e.message ?: e.javaClass.simpleName)
            }
        }
    }

    // Runs on yubikit's connection thread, which the security key's touch may hold for a while.
    fun use(device: YubiKeyDevice) {
        if (working) return
        if (device is UsbYubiKeyDevice) usbKey = device
        if (askPin && pin.isEmpty()) {
            problem = context.getString(R.string.security_key_pin_needed)
            return
        }
        working = true
        problem = null
        val pinChars = pin.takeIf { askPin && it.isNotEmpty() }?.toCharArray()
        val work = { session: Ctap2Session -> pending.work(session, pinChars, state) }
        if (device is UsbYubiKeyDevice) {
            device.requestConnection(FidoConnection::class.java) { result ->
                finished(runCatching { result.value.use { work(Ctap2Session(it)) } })
            }
        } else {
            device.requestConnection(SmartCardConnection::class.java) { result ->
                finished(runCatching { result.value.use { work(Ctap2Session(it)) } })
            }
        }
    }
    val useKey by rememberUpdatedState(::use)

    DisposableEffect(pending) {
        val manager = YubiKitManager(context.applicationContext)
        val activity = context.activity()
        manager.startUsbDiscovery(UsbConfiguration().handlePermissions(true).setDeviceFilter(FidoHidFilter)) { device ->
            device.setOnClosed { scope.launch(Dispatchers.Main) { if (usbKey === device) usbKey = null } }
            scope.launch(Dispatchers.Main) { useKey(device) }
        }
        if (activity != null) {
            try {
                manager.startNfcDiscovery(NfcConfiguration().timeout(NFC_TIMEOUT_MS), activity) { device ->
                    scope.launch(Dispatchers.Main) { useKey(device) }
                }
            } catch (e: NfcNotAvailable) {
                nfcAvailable = false
                nfcOff = e.isDisabled
            }
        } else {
            nfcAvailable = false
        }
        onDispose {
            state.cancel()
            manager.stopUsbDiscovery()
            activity?.let { runCatching { manager.stopNfcDiscovery(it) } }
        }
    }

    val cancel = {
        state.cancel()
        viewModel.finishSecurityKey(pending, null)
    }
    AlertDialog(
        onDismissRequest = cancel,
        title = {
            Text(
                when (val job = pending.job) {
                    is SecurityKeyJob.SignIn -> stringResource(R.string.sign_in_to, job.hostName)
                    is SecurityKeyJob.Create -> stringResource(R.string.security_key_create_title)
                },
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                when (val job = pending.job) {
                    is SecurityKeyJob.SignIn -> Text(job.destination, fontWeight = FontWeight.Bold)
                    is SecurityKeyJob.Create -> Text("${job.alias} · ${job.type.label}", fontWeight = FontWeight.Bold)
                }
                Text(
                    stringResource(
                        when {
                            working && touchNow -> R.string.security_key_touch
                            working -> R.string.security_key_working
                            nfcAvailable -> R.string.security_key_plug_or_hold
                            else -> R.string.security_key_plug
                        },
                    ),
                    modifier = Modifier.testTag("securityKey.status"),
                )
                if (working) CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                if (nfcOff && !working) {
                    Text(stringResource(R.string.security_key_nfc_off), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (askPin) {
                    OutlinedTextField(
                        value = pin,
                        onValueChange = { pin = it },
                        enabled = !working,
                        label = { Text(stringResource(R.string.security_key_pin)) },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { usbKey?.let(useKey) }),
                        modifier = Modifier.fillMaxWidth().testTag("securityKey.pin"),
                    )
                }
                problem?.let {
                    Text(it, color = MaterialTheme.colorScheme.error, fontSize = 12.sp, modifier = Modifier.testTag("securityKey.problem"))
                }
            }
        },
        confirmButton = {
            if (askPin) {
                TextButton(
                    enabled = !working && pin.isNotEmpty() && usbKey != null,
                    onClick = { usbKey?.let(useKey) },
                    modifier = Modifier.testTag("securityKey.continue"),
                ) { Text(stringResource(R.string.security_key_continue)) }
            }
        },
        dismissButton = {
            TextButton(onClick = cancel, modifier = Modifier.testTag("securityKey.cancel")) {
                Text(stringResource(R.string.cancel))
            }
        },
    )
}

/** How long one NFC exchange may take; a security key signs well within it. */
private const val NFC_TIMEOUT_MS = 5_000
