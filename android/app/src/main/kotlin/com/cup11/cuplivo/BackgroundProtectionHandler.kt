package com.cup11.cuplivo

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Native backend for the background keep-alive guide page (`app.background_protection`).
 *
 * The guide educates users on Chinese OEM ROMs, where a foreground service alone is
 * frequently killed unless the app is whitelisted (autostart / unlimited battery).
 * This handler:
 *  - queries/requests the AOSP battery-optimization exemption,
 *  - opens curated vendor settings pages, falling back to generic pages when the
 *    vendor components drift between ROM versions (never silent: Log.w per failure).
 */
class BackgroundProtectionHandler(private val activity: Activity) {
    companion object {
        const val CHANNEL_NAME = "app.background_protection"
        private const val TAG = "BackgroundProtection"
        private const val KIND_AUTOSTART = "autostart"
        private const val KIND_BATTERY = "battery"
    }

    /** Curated vendor settings pages. Component names come from the AutoStarter
     *  community knowledge base and drift across ROM versions; every entry is
     *  best-effort with graceful fallback. */
    private val vendorSettings: Map<String, Map<String, List<String>>> = mapOf(
        "xiaomi" to mapOf(
            KIND_AUTOSTART to listOf(
                "com.miui.securitycenter/com.miui.permcenter.autostart.AutoStartManagementActivity",
            ),
            KIND_BATTERY to listOf(
                "com.miui.powerkeeper/com.miui.powerkeeper.ui.HiddenAppsConfigActivity",
                "com.miui.powerkeeper/com.miui.powerkeeper.ui.HiddenAppsActivity",
            ),
        ),
        "huawei" to mapOf(
            KIND_AUTOSTART to listOf(
                "com.huawei.systemmanager/com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            ),
            KIND_BATTERY to listOf(
                "com.huawei.systemmanager/com.huawei.systemmanager.optimize.process.ProtectActivity",
            ),
        ),
        "honor" to mapOf(
            KIND_AUTOSTART to listOf(
                "com.hihonor.systemmanager/com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            ),
            KIND_BATTERY to listOf(
                "com.hihonor.systemmanager/com.hihonor.systemmanager.optimize.process.ProtectActivity",
            ),
        ),
        "oppo" to mapOf(
            KIND_AUTOSTART to listOf(
                "com.oplus.safecenter/com.oplus.safecenter.startupapp.StartupAppListActivity",
                "com.coloros.safecenter/com.coloros.safecenter.permission.startup.StartupAppListActivity",
            ),
            KIND_BATTERY to emptyList(),
        ),
        "oneplus" to mapOf(
            KIND_AUTOSTART to listOf(
                "com.oneplus.security/com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity",
            ),
            KIND_BATTERY to emptyList(),
        ),
        "vivo" to mapOf(
            KIND_AUTOSTART to listOf(
                "com.vivo.permissionmanager/com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
            ),
            KIND_BATTERY to listOf(
                "com.vivo.permissionmanager/com.vivo.permissionmanager.activity.PowerUsageActivity",
            ),
        ),
        "samsung" to mapOf(
            KIND_AUTOSTART to listOf(
                "com.samsung.android.lool/com.samsung.android.sm.battery.ui.SettingPackageListActivity",
            ),
            KIND_BATTERY to listOf(
                "com.samsung.android.lool/com.samsung.android.sm.battery.ui.BatteryActivity",
            ),
        ),
        "meizu" to mapOf(
            KIND_AUTOSTART to listOf(
                "com.meizu.safe/com.meizu.safe.security.SHOW_APPSEC",
            ),
            KIND_BATTERY to emptyList(),
        ),
    )

    fun configure(messenger: BinaryMessenger) {
        val channel = MethodChannel(messenger, CHANNEL_NAME)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "requestIgnoreBatteryOptimization" -> {
                    result.success(requestIgnoreBatteryOptimization())
                }
                "openVendorSettings" -> {
                    val args = call.arguments as? Map<*, *>
                    val vendor = args?.get("vendor")?.toString().orEmpty()
                    val kind = args?.get("kind")?.toString().orEmpty()
                    result.success(openVendorSettings(vendor, kind))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val pm = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(activity.packageName)
    }

    private fun requestIgnoreBatteryOptimization(): Boolean {
        return try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:${activity.packageName}")
            }
            activity.startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w(TAG, "Unable to request battery optimization exemption", e)
            false
        }
    }

    /** Returns "opened" | "fallback" | "failed". Never throws. */
    private fun openVendorSettings(vendor: String, kind: String): String {
        val candidates = vendorSettings[vendor]?.get(kind).orEmpty()
        for (component in candidates) {
            if (tryStart(componentIntent(component))) return "opened"
        }

        val genericFallbacks = if (kind == KIND_BATTERY) {
            listOf(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        } else {
            emptyList()
        }
        for (fallback in genericFallbacks) {
            if (tryStart(fallback)) return "fallback"
        }

        val details = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:${activity.packageName}"),
        )
        return if (tryStart(details)) "fallback" else "failed"
    }

    private fun componentIntent(component: String): Intent {
        val name = ComponentName.unflattenFromString(component)
        return if (name == null) {
            Intent(component)
        } else {
            Intent().setComponent(name)
        }
    }

    private fun tryStart(intent: Intent): Boolean {
        return try {
            activity.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "Settings activity not found: $intent")
            false
        } catch (e: SecurityException) {
            Log.w(TAG, "Settings activity not accessible: $intent (${e.message})")
            false
        } catch (e: Exception) {
            Log.w(TAG, "Unable to open settings: $intent", e)
            false
        }
    }
}
