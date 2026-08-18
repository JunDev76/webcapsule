package com.webcapsule.reactnative.runtime

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.rules.TemporaryFolder

class RecoveryManagerTest {
  private val temporary = TemporaryFolder.builder().assureDeletion().build().also { it.create() }

  @Test fun `missing registry invokes bundled recovery and preserves original failure`() {
    val layout = StorageLayout(File(temporary.root, "missing"))
    val manager = manager(layout) { fail(WebCapsuleErrorCode.BUNDLED_CAPSULE_UNAVAILABLE, "missing asset") }
    try { manager.recover("com.example.app"); throw AssertionError("Expected failure") }
    catch (error: WebCapsuleException) {
      assertEquals(WebCapsuleErrorCode.BUNDLED_CAPSULE_UNAVAILABLE, error.code)
      assertEquals(1, error.suppressed.size)
      assertTrue(error.suppressed[0] is WebCapsuleException)
    }
  }

  @Test fun `unexpected staging layout is never deleted`() {
    val layout = StorageLayout(File(temporary.root, "staging")); layout.stagingRoot.mkdirs()
    val unexpected = File(layout.stagingRoot, "not-a-uuid").apply { writeText("do not delete") }
    val manager = manager(layout) { fail(WebCapsuleErrorCode.BUNDLED_CAPSULE_UNAVAILABLE, "missing asset") }
    try { manager.recover("com.example.app") } catch (_: WebCapsuleException) { }
    assertTrue(unexpected.isFile)
    assertEquals("do not delete", unexpected.readText())
  }

  private fun manager(layout: StorageLayout, bundled: BundledRecovery): RecoveryManager = RecoveryManager(
    layout, CapsuleLockManager(layout), RegistryStore(layout), VersionStore(layout), bundled,
  )
}
