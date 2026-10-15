package com.gante.gante_app

import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.gante.gante_app/share"
    private val adaptiveChannelName = "com.gante.gante_app/adaptive"
    private var shareChannel: MethodChannel? = null
    private var pendingText: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingText = extractSharedText(intent)
        shareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "getInitialText") {
                    result.success(pendingText)
                    pendingText = null
                } else {
                    result.notImplemented()
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            adaptiveChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasUsageAccess" -> result.success(AdaptiveAlarmScheduler.hasUsageAccess(this))
                "requestUsageAccess" -> {
                    AdaptiveAlarmScheduler.openUsageAccessSettings(this)
                    result.success(null)
                }
                "schedulePlan" -> {
                    val alarmId = call.argument<Int>("alarmId") ?: return@setMethodCallHandler result.error("ARGS", "Missing alarmId", null)
                    val label = call.argument<String>("label") ?: "Gante alarm"
                    val targetMillis = call.argument<Number>("targetMillis")?.toLong() ?: return@setMethodCallHandler result.error("ARGS", "Missing targetMillis", null)
                    val offsets = call.argument<List<Number>>("offsets")?.map { it.toInt() } ?: listOf(0)
                    result.success(AdaptiveAlarmScheduler.schedule(this, alarmId, label, targetMillis, offsets))
                }
                "cancelPlan" -> {
                    call.argument<Int>("alarmId")?.let { AdaptiveAlarmScheduler.cancelPlan(this, it) }
                    result.success(null)
                }
                "completePlan" -> {
                    call.argument<Int>("alarmId")?.let { AdaptiveAlarmScheduler.completePlan(this, it) }
                    result.success(null)
                }
                "completedIds" -> result.success(AdaptiveAlarmScheduler.completedIds(this))
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = extractSharedText(intent) ?: return
        val channel = shareChannel
        if (channel == null) {
            pendingText = text
        } else {
            channel.invokeMethod("sharedText", text)
        }
    }

    private fun extractSharedText(intent: Intent?): String? {
        val value = when (intent?.action) {
            Intent.ACTION_SEND -> intent.getCharSequenceExtra(Intent.EXTRA_TEXT)
            Intent.ACTION_PROCESS_TEXT ->
                intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)
            else -> null
        }
        return value?.toString()?.trim()?.take(8000)?.takeIf { it.isNotEmpty() }
    }
}
