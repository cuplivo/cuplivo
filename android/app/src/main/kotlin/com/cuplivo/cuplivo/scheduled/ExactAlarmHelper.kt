package com.cuplivo.cuplivo.scheduled

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Shared helper for scheduling exact alarms with battery optimization bypass.
 */
object ExactAlarmHelper {
    fun isExactAlarmPermitted(alarms: AlarmManager): Boolean =
        Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()

    fun scheduleExact(
        alarms: AlarmManager,
        triggerAtMillis: Long,
        operation: PendingIntent,
    ) {
        if (isExactAlarmPermitted(alarms)) {
            try {
                alarms.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtMillis,
                    operation,
                )
            } catch (ignored: SecurityException) {}
        }
    }

    fun cancel(alarms: AlarmManager, operation: PendingIntent) {
        alarms.cancel(operation)
    }
}
