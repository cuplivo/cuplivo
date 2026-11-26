package com.cuplivo.cuplivo.scheduled

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.cuplivo.cuplivo.KelivoApplication

/** Only claims the alarm and hands off to the shared engine. Never waits
 *  for Flutter or a model reply. */
class ProactiveCareAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val alarms = (context.applicationContext as KelivoApplication).proactiveCareAlarms
        if (intent.action == ProactiveCareAlarms.FIRE) {
            val id = intent.data?.lastPathSegment ?: return
            alarms.fire(id, intent.getLongExtra("dueAt", 0))
        } else if (intent.action in setOf(Intent.ACTION_BOOT_COMPLETED,
                Intent.ACTION_MY_PACKAGE_REPLACED, Intent.ACTION_TIME_CHANGED,
                Intent.ACTION_TIMEZONE_CHANGED,
                android.app.AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED)) {
            // Reboot/time changes rearm future letters, never replay missed ones.
            alarms.rescheduleAll()
        }
    }
}
