package com.jetsetslow.omniterm

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Flutter method-channel facade for [LongOperationService]. */
object LongOperationBridge {
    private const val CHANNEL = "omniterm/long_operations"

    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            val id = call.argument<String>("id").orEmpty()
            when (call.method) {
                "isSupported" -> result.success(true)
                "start", "update" -> {
                    if (id.isBlank()) {
                        result.error("invalid_operation", "Operation id is required", null)
                        return@setMethodCallHandler
                    }
                    val intent = Intent(app, LongOperationService::class.java).apply {
                        action = LongOperationService.ACTION_START_OR_UPDATE
                        putExtra(LongOperationService.EXTRA_ID, id)
                        putExtra(LongOperationService.EXTRA_LABEL, call.argument<String>("label").orEmpty())
                        putExtra(LongOperationService.EXTRA_BYTES_DONE, call.argument<Number>("bytesDone")?.toLong() ?: 0L)
                        putExtra(LongOperationService.EXTRA_TOTAL_BYTES, call.argument<Number>("totalBytes")?.toLong() ?: 0L)
                        putExtra(LongOperationService.EXTRA_DESTINATION, call.argument<String>("destination").orEmpty())
                    }
                    runCatching {
                        if (call.method == "start") ContextCompat.startForegroundService(app, intent)
                        else app.startService(intent)
                    }.fold(
                        onSuccess = { result.success(true) },
                        onFailure = { result.error("operation_service", it.message, null) },
                    )
                }
                "finish" -> {
                    if (id.isBlank()) {
                        result.error("invalid_operation", "Operation id is required", null)
                        return@setMethodCallHandler
                    }
                    runCatching {
                        app.startService(
                            Intent(app, LongOperationService::class.java).apply {
                                action = LongOperationService.ACTION_FINISH
                                putExtra(LongOperationService.EXTRA_ID, id)
                                putExtra(LongOperationService.EXTRA_SUCCESS, call.argument<Boolean>("success") ?: true)
                                putExtra(LongOperationService.EXTRA_CANCELLED, call.argument<Boolean>("cancelled") ?: false)
                            },
                        )
                    }.fold(
                        onSuccess = { result.success(true) },
                        onFailure = { result.error("operation_service", it.message, null) },
                    )
                }
                "stopAll" -> {
                    runCatching {
                        app.startService(
                            Intent(app, LongOperationService::class.java).apply {
                                action = LongOperationService.ACTION_STOP
                            },
                        )
                    }.fold(
                        onSuccess = { result.success(true) },
                        onFailure = { result.error("operation_service", it.message, null) },
                    )
                }
                else -> result.notImplemented()
            }
        }
    }
}
