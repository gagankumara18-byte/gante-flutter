package com.gante.gante_app

import android.app.AlarmManager
import android.app.AppOpsManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject

object AdaptiveAlarmScheduler {
    private const val prefsName = "gante_adaptive_state"
    private const val planPrefix = "plan_"

    fun hasUsageAccess(context: Context): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = appOps.checkOpNoThrow(
            AppOpsManager.OPSTR_GET_USAGE_STATS,
            android.os.Process.myUid(),
            context.packageName,
        )
        return mode == AppOpsManager.MODE_ALLOWED
    }

    fun openUsageAccessSettings(context: Context) {
        context.startActivity(
            Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
        )
    }

    fun schedule(
        context: Context,
        alarmId: Int,
        label: String,
        targetMillis: Long,
        offsets: List<Int>,
    ): List<Int> {
        cancelPlan(context, alarmId)
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val now = System.currentTimeMillis()
        val uniqueOffsets = offsets.distinct().sortedDescending()
        val ids = mutableListOf<Int>()

        uniqueOffsets.forEachIndexed { index, offset ->
            val trigger = targetMillis - offset * 60_000L
            if (trigger <= now) return@forEachIndexed
            val notificationId = notificationId(alarmId, index)
            val operation = firePendingIntent(
                context,
                notificationId,
                alarmId,
                label,
                targetMillis,
                offset,
                offset == 0,
            )
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || manager.canScheduleExactAlarms()) {
                manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, operation)
            } else {
                manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, operation)
            }
            ids.add(notificationId)
        }

        val plan = JSONObject()
            .put("alarmId", alarmId)
            .put("label", label)
            .put("targetMillis", targetMillis)
            .put("offsets", JSONArray(uniqueOffsets))
            .put("ids", JSONArray(ids))
        prefs(context).edit()
            .putString("$planPrefix$alarmId", plan.toString())
            .putBoolean("completed_$alarmId", false)
            .apply()
        return ids
    }

    fun cancelPlan(context: Context, alarmId: Int) {
        val raw = prefs(context).getString("$planPrefix$alarmId", null) ?: return
        val plan = runCatching { JSONObject(raw) }.getOrNull() ?: return
        val ids = plan.optJSONArray("ids") ?: JSONArray()
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        for (index in 0 until ids.length()) {
            val id = ids.optInt(index)
            manager.cancel(existingPendingIntent(context, id))
            val notifications = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
            notifications.cancel(id)
        }
    }

    fun cancelIds(context: Context, ids: List<Int>) {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val notifications = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        ids.forEach { id ->
            manager.cancel(existingPendingIntent(context, id))
            notifications.cancel(id)
        }
    }

    fun completePlan(context: Context, alarmId: Int) {
        prefs(context).edit()
            .putBoolean("completed_$alarmId", true)
            .putLong("completed_at_$alarmId", System.currentTimeMillis())
            .apply()
        cancelPlan(context, alarmId)
    }

    fun isCompleted(context: Context, alarmId: Int): Boolean =
        prefs(context).getBoolean("completed_$alarmId", false)

    fun completedIds(context: Context): List<Int> = prefs(context).all
        .filter { (key, value) -> key.startsWith("completed_") && value == true }
        .mapNotNull { (key, _) -> key.removePrefix("completed_").toIntOrNull() }

    fun recordSuppressed(context: Context, alarmId: Int) {
        val store = prefs(context)
        store.edit()
            .putInt("suppressed_count", store.getInt("suppressed_count", 0) + 1)
            .putLong("last_active_$alarmId", System.currentTimeMillis())
            .apply()
    }

    fun recordDelivered(context: Context) {
        val store = prefs(context)
        store.edit()
            .putInt("delivered_count", store.getInt("delivered_count", 0) + 1)
            .apply()
    }

    private fun firePendingIntent(
        context: Context,
        notificationId: Int,
        alarmId: Int,
        label: String,
        targetMillis: Long,
        offset: Int,
        isFinal: Boolean,
    ): PendingIntent = PendingIntent.getBroadcast(
        context,
        notificationId,
        Intent(context, AdaptiveAlarmReceiver::class.java).apply {
            action = "${AdaptiveAlarmReceiver.actionFire}.$notificationId"
            putExtra("notificationId", notificationId)
            putExtra("alarmId", alarmId)
            putExtra("label", label)
            putExtra("targetMillis", targetMillis)
            putExtra("offset", offset)
            putExtra("isFinal", isFinal)
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun existingPendingIntent(context: Context, notificationId: Int): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            notificationId,
            Intent(context, AdaptiveAlarmReceiver::class.java).apply {
                action = "${AdaptiveAlarmReceiver.actionFire}.$notificationId"
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun notificationId(alarmId: Int, slot: Int): Int =
        (alarmId + slot * 1_000_003) and 0x7fffffff

    private fun prefs(context: Context) =
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
}
