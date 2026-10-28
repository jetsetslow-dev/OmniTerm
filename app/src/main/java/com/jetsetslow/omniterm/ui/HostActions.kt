package com.jetsetslow.omniterm.ui

import android.content.Context
import android.widget.Toast
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.WolTargetEntity

/** The saved Wake-on-LAN target for [server]: the one whose address is the host's address. */
internal fun wolTargetFor(server: ServerEntity, targets: List<WolTargetEntity>): WolTargetEntity? =
    targets.firstOrNull { it.ipAddress.isNotBlank() && it.ipAddress.trim().equals(server.host.trim(), ignoreCase = true) }

/**
 * Asks before sending [target] a magic packet, then says whether it went out. The one wake flow,
 * used by Tools → Wake-on-LAN and by an offline host's card.
 */
fun confirmAndWake(confirm: ConfirmController, viewModel: AppViewModel, target: WolTargetEntity, context: Context) {
    confirm.ask(
        confirm.str(R.string.send_wake_packet),
        confirm.str(R.string.send_a_wake_on_lan_magic, target.name, target.macAddress),
        confirmLabel = confirm.str(R.string.wake),
    ) {
        viewModel.triggerWol(target) { sent ->
            Toast.makeText(
                context,
                context.getString(if (sent) R.string.magic_packet_sent_to else R.string.failed_to_send_magic_packet_to, target.name),
                Toast.LENGTH_SHORT,
            ).show()
        }
    }
}
