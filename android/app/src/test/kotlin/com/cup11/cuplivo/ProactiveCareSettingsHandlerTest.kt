package com.cup11.cuplivo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProactiveCareSettingsHandlerTest {
  @Test
  fun mapsKnownManufacturersToExplicitAutoStartDestinations() {
    assertEquals(
      "com.miui.securitycenter",
      autoStartComponentsForManufacturer("XIAOMI").first().packageName,
    )
    assertEquals(
      "com.hihonor.systemmanager",
      autoStartComponentsForManufacturer("Honor").first().packageName,
    )
    assertEquals(
      "com.oplus.safecenter",
      autoStartComponentsForManufacturer("realme").first().packageName,
    )
    assertEquals(
      "com.vivo.permissionmanager",
      autoStartComponentsForManufacturer("iQOO").first().packageName,
    )
  }

  @Test
  fun supportsAdditionalKnownOemSettingsPackages() {
    assertEquals(
      "com.samsung.android.lool",
      autoStartComponentsForManufacturer("samsung").single().packageName,
    )
    assertEquals(
      "com.asus.mobilemanager",
      autoStartComponentsForManufacturer("asus").single().packageName,
    )
    assertEquals(
      "com.meizu.safe",
      autoStartComponentsForManufacturer("meizu").single().packageName,
    )
  }

  @Test
  fun unknownManufacturerHasNoFakeGrantOrGenericOemDestination() {
    assertTrue(autoStartComponentsForManufacturer("unknown-oem").isEmpty())
  }
}
