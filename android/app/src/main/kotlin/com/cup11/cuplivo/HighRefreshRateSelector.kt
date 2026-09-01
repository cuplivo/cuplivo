package com.cup11.cuplivo

/** Resolution-qualified display mode snapshot used by [HighRefreshRateSelector]. */
data class SupportedDisplayMode(
  val physicalWidth: Int,
  val physicalHeight: Int,
  val refreshRate: Float,
)

/**
 * Picks the highest refresh rate among supported modes that share the active
 * mode's physical resolution. Returns null when no mode matches. Pure logic:
 * no Android framework types, so it is JVM-unit-testable.
 */
object HighRefreshRateSelector {
  fun select(
    activeWidth: Int,
    activeHeight: Int,
    modes: List<SupportedDisplayMode>,
  ): Float? = modes
    .asSequence()
    .filter { it.physicalWidth == activeWidth && it.physicalHeight == activeHeight }
    .maxOfOrNull { it.refreshRate }
}
