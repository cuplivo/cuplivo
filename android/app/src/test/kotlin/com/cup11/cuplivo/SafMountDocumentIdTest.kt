package com.cup11.cuplivo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Grammar tests for SAF document addressing (issue #528 regression).
 *
 * The old bridge decoded every URI with [DocumentFile.fromTreeUri], which
 * keeps only the tree id and resolves ANY subtree URI to the tree root —
 * so the walker re-enumerated the mount root on every directory step.
 * `documentIdFor` must pick the URI's own document-ID segment instead.
 */
class SafMountDocumentIdTest {

  @Test
  fun rootTreeUriReturnsTreeId() {
    assertEquals(
      "primary:Vault",
      documentIdFor(listOf("tree", "primary:Vault")),
    )
  }

  @Test
  fun childDocumentUriReturnsItsOwnId() {
    assertEquals(
      "primary:Vault/.crush",
      documentIdFor(listOf("tree", "primary:Vault", "document", "primary:Vault/.crush")),
    )
  }

  @Test
  fun childrenTailStillReturnsChildId() {
    assertEquals(
      "primary:Vault/.crush",
      documentIdFor(
        listOf("tree", "primary:Vault", "document", "primary:Vault/.crush", "children"),
      ),
    )
  }

  @Test
  fun deepChildDocumentUriReturnsDeepId() {
    assertEquals(
      "primary:Vault/.crush/2024/notes.md",
      documentIdFor(
        listOf("tree", "primary:Vault", "document", "primary:Vault/.crush/2024/notes.md"),
      ),
    )
  }

  @Test
  fun rejectsForeignShapes() {
    assertNull(documentIdFor(emptyList()))
    assertNull(documentIdFor(listOf("document", "primary:x")))
    assertNull(documentIdFor(listOf("tree")))
    assertNull(documentIdFor(listOf("tree", "primary:x", "document")))
    assertNull(documentIdFor(listOf("file", "x")))
  }

  @Test
  fun rejectsEmptyIds() {
    assertNull(documentIdFor(listOf("tree", "")))
    assertNull(documentIdFor(listOf("tree", "t", "document", "")))
  }

  @Test
  fun canonicalShapeAcceptsExactlyDocumentUri() {
    assertTrue(
      isCanonicalTreeDocumentUriShape(
        listOf("tree", "primary:Vault", "document", "primary:Vault/notes.md"),
      ),
    )
  }

  @Test
  fun canonicalShapeRejectsChildrenTail() {
    // The #528-style echo: a provider returning the requested children URI
    // (5 segments) must not parse as a canonical created document.
    assertFalse(
      isCanonicalTreeDocumentUriShape(
        listOf("tree", "primary:Vault", "document", "primary:Vault/.crush", "children"),
      ),
    )
  }

  @Test
  fun canonicalShapeRejectsOtherShapes() {
    assertFalse(isCanonicalTreeDocumentUriShape(emptyList()))
    assertFalse(isCanonicalTreeDocumentUriShape(listOf("tree", "primary:Vault")))
    assertFalse(isCanonicalTreeDocumentUriShape(listOf("tree", "", "document", "x")))
    assertFalse(isCanonicalTreeDocumentUriShape(listOf("tree", "t", "document", "")))
    assertFalse(isCanonicalTreeDocumentUriShape(listOf("document", "primary:x")))
  }
}
