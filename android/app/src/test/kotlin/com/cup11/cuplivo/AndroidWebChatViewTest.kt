package com.cup11.cuplivo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidWebChatViewTest {
  @Test
  fun allowsOnlyBundledWebChatAssetsAndMermaid() {
    assertTrue(
      isAllowedWebChatAssetPath("flutter_assets/assets/web_chat/index.html"),
    )
    assertTrue(
      isAllowedWebChatAssetPath("flutter_assets/assets/web_chat/vendor/fonts/font.woff2"),
    )
    assertTrue(
      isAllowedWebChatAssetPath("flutter_assets/assets/mermaid.min.js"),
    )
    assertFalse(isAllowedWebChatAssetPath("flutter_assets/assets/app_icon.png"))
    assertFalse(
      isAllowedWebChatAssetPath("flutter_assets/assets/web_chat/../../app_icon.png"),
    )
    assertFalse(isAllowedWebChatAssetPath("/flutter_assets/assets/web_chat/index.html"))
  }

  @Test
  fun servesModulesWithJavaScriptMimeType() {
    assertEquals("text/html", webChatAssetMimeType("index.html"))
    assertEquals("text/css", webChatAssetMimeType("styles.css"))
    assertEquals("text/javascript", webChatAssetMimeType("app.mjs"))
    assertEquals("text/javascript", webChatAssetMimeType("mermaid.min.js"))
    assertEquals("font/woff2", webChatAssetMimeType("font.woff2"))
    assertEquals("application/octet-stream", webChatAssetMimeType("unknown.bin"))
  }

  @Test
  fun allowsOnlyTheExactShellUrlForEachMode() {
    assertTrue(isAllowedWebChatMainFrameUrl(WEB_CHAT_SHELL_URL, printMode = false))
    assertTrue(isAllowedWebChatMainFrameUrl(WEB_CHAT_PRINT_SHELL_URL, printMode = true))
    assertFalse(isAllowedWebChatMainFrameUrl(WEB_CHAT_PRINT_SHELL_URL, printMode = false))
    assertFalse(
      isAllowedWebChatMainFrameUrl(
        "$WEB_CHAT_PRINT_SHELL_URL&redirect=https://example.com",
        printMode = true,
      ),
    )
    assertFalse(isAllowedWebChatMainFrameUrl("file:///android_asset/index.html", true))
  }

  @Test
  fun printResourcesStayOnTheBundledHttpsOrigin() {
    assertTrue(
      isAllowedWebChatResourceUrl(
        "$WEB_CHAT_ORIGIN/assets/flutter_assets/assets/web_chat/styles.css",
      ),
    )
    assertFalse(isAllowedWebChatResourceUrl("https://example.com/image.png"))
    assertFalse(
      isAllowedWebChatResourceUrl("$WEB_CHAT_ORIGIN/assets/../private.txt"),
    )
    assertFalse(isAllowedWebChatResourceUrl("file:///android_asset/index.html"))
  }

  @Test
  fun sanitizesPrintDocumentNames() {
    assertEquals(
      "Conversation_2026",
      sanitizeWebChatPrintDocumentName(" Conversation/2026 "),
    )
    assertEquals("Cuplivo", sanitizeWebChatPrintDocumentName("\u0000/\\"))
    assertEquals(80, sanitizeWebChatPrintDocumentName("x".repeat(100)).length)
  }
}
