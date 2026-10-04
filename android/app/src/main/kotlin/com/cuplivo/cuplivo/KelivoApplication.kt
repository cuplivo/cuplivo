package com.cuplivo.cuplivo

import android.app.Application
import com.cuplivo.cuplivo.background.BackgroundRuntime
import com.cuplivo.cuplivo.workspace.WorkspacePlugin
import com.cuplivo.cuplivo.scheduled.ScheduledTasks
import com.cuplivo.cuplivo.scheduled.ProactiveCareAlarms
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

/** One Dart isolate and database owner per process, independent of its UI. */
class KelivoApplication : Application() {
    val backgroundRuntime by lazy { BackgroundRuntime(this) }
    val scheduledTasks by lazy { ScheduledTasks(this) }
    val proactiveCareAlarms by lazy { ProactiveCareAlarms(this) }
    val workspace by lazy { WorkspacePlugin(this) }
    val deviceTools by lazy { DeviceLocalToolsHandler(this) }

    private val engineHolder = lazy {
        FlutterEngine(this).also { engine ->
            val messenger = engine.dartExecutor.binaryMessenger
            backgroundRuntime.configure(messenger)
            scheduledTasks.configure(messenger)
            proactiveCareAlarms.configure(messenger)
            workspace.configure(messenger)
            deviceTools.configure(messenger)
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        }
    }

    val hasEngine get() = engineHolder.isInitialized()
    val engine: FlutterEngine get() = engineHolder.value
}
