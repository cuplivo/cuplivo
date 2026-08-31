package com.cup11.cuplivo

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

internal data class SettingsComponent(
  val packageName: String,
  val className: String,
)

internal fun autoStartComponentsForManufacturer(
  manufacturer: String,
): List<SettingsComponent> = when (manufacturer.lowercase(Locale.ROOT)) {
  "xiaomi", "redmi" -> listOf(
    SettingsComponent(
      "com.miui.securitycenter",
      "com.miui.permcenter.autostart.AutoStartManagementActivity",
    ),
  )
  "huawei" -> listOf(
    SettingsComponent(
      "com.huawei.systemmanager",
      "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
    ),
    SettingsComponent(
      "com.huawei.systemmanager",
      "com.huawei.systemmanager.optimize.process.ProtectActivity",
    ),
  )
  "honor" -> listOf(
    SettingsComponent(
      "com.hihonor.systemmanager",
      "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
    ),
    SettingsComponent(
      "com.huawei.systemmanager",
      "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
    ),
  )
  "oppo", "realme", "oneplus" -> listOf(
    SettingsComponent(
      "com.oplus.safecenter",
      "com.oplus.safecenter.startupapp.StartupAppListActivity",
    ),
    SettingsComponent(
      "com.coloros.safecenter",
      "com.coloros.safecenter.startupapp.StartupAppListActivity",
    ),
  )
  "vivo", "iqoo" -> listOf(
    SettingsComponent(
      "com.vivo.permissionmanager",
      "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
    ),
    SettingsComponent(
      "com.iqoo.secure",
      "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager",
    ),
  )
  "samsung" -> listOf(
    SettingsComponent(
      "com.samsung.android.lool",
      "com.samsung.android.sm.ui.battery.BatteryActivity",
    ),
  )
  "asus" -> listOf(
    SettingsComponent("com.asus.mobilemanager", "com.asus.mobilemanager.MainActivity"),
  )
  "meizu" -> listOf(
    SettingsComponent("com.meizu.safe", "com.meizu.safe.permission.SmartBGActivity"),
  )
  else -> emptyList()
}

/** Opens Android settings destinations that existing Flutter plugins do not expose. */
class ProactiveCareSettingsHandler(private val activity: Activity) {
  companion object {
    const val CHANNEL_NAME = "cuplivo/proactive_care_settings"
    private const val TAG = "ProactiveCareSettings"
  }

  fun configure(messenger: BinaryMessenger) {
    MethodChannel(messenger, CHANNEL_NAME).setMethodCallHandler { call, result ->
      try {
        when (call.method) {
          "openAppNotificationSettings" -> result.success(openAppNotificationSettings())
          "openNotificationChannelSettings" -> {
            val channelId = call.argument<String>("channelId")
            if (channelId.isNullOrBlank()) {
              result.error("invalid_args", "Missing channelId.", null)
            } else {
              result.success(openNotificationChannelSettings(channelId))
            }
          }
          "openAutoStartSettings" -> openAutoStartSettings(result)
          else -> result.notImplemented()
        }
      } catch (error: Exception) {
        Log.e(TAG, "Failed to handle ${call.method}.", error)
        result.error("settings_launch_failed", error.message, null)
      }
    }
  }

  private fun openAppNotificationSettings(): Boolean {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
        putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
      }
      if (tryStart(intent, "app notification settings")) return true
    }
    return openApplicationDetails()
  }

  private fun openNotificationChannelSettings(channelId: String): Boolean {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val intent = Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
        putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
        putExtra(Settings.EXTRA_CHANNEL_ID, channelId)
      }
      if (tryStart(intent, "notification channel settings")) return true
    }
    return openAppNotificationSettings()
  }

  private fun openAutoStartSettings(result: MethodChannel.Result) {
    for (component in autoStartComponentsForManufacturer(Build.MANUFACTURER)) {
      val intent = Intent().apply {
        this.component = ComponentName(component.packageName, component.className)
      }
      if (tryStart(intent, "${Build.MANUFACTURER} auto-start settings")) {
        result.success("manufacturerSettings")
        return
      }
    }
    if (openApplicationDetails()) {
      result.success("applicationDetails")
    } else {
      result.error(
        "settings_unavailable",
        "No auto-start or application-details settings activity is available.",
        null,
      )
    }
  }

  private fun openApplicationDetails(): Boolean = tryStart(
    Intent(
      Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
      Uri.fromParts("package", activity.packageName, null),
    ),
    "application details settings",
  )

  private fun tryStart(intent: Intent, destination: String): Boolean {
    return try {
      activity.startActivity(intent)
      true
    } catch (error: ActivityNotFoundException) {
      Log.w(TAG, "$destination is unavailable.", error)
      false
    } catch (error: SecurityException) {
      Log.w(TAG, "$destination was rejected by Android.", error)
      false
    }
  }
}
