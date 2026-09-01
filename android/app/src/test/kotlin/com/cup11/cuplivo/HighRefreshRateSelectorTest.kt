package com.cup11.cuplivo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HighRefreshRateSelectorTest {

  @Test
  fun picksHighestRefreshRateAtActiveResolution() {
    val rate = HighRefreshRateSelector.select(
      1080,
      2340,
      listOf(
        SupportedDisplayMode(1440, 3120, 120f),
        SupportedDisplayMode(1080, 2340, 60f),
        SupportedDisplayMode(1080, 2340, 90f),
      ),
    )
    assertEquals(90f, rate!!)
  }

  @Test
  fun ignoresModesWithDifferentResolution() {
    val rate = HighRefreshRateSelector.select(
      1080,
      2340,
      listOf(
        SupportedDisplayMode(1440, 3120, 120f),
        SupportedDisplayMode(720, 1600, 90f),
      ),
    )
    assertNull(rate)
  }

  @Test
  fun emptySupportedModesYieldsNull() {
    assertNull(HighRefreshRateSelector.select(1080, 2340, emptyList()))
  }

  @Test
  fun singleMatchingModeWins() {
    val rate = HighRefreshRateSelector.select(
      1440,
      3120,
      listOf(SupportedDisplayMode(1440, 3120, 120f)),
    )
    assertEquals(120f, rate!!)
  }
}
