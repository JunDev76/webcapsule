package com.webcapsule.reactnative.runtime

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.rules.TemporaryFolder

class RegistryUpdateTransitionTest {
  private val temporary = TemporaryFolder.builder().assureDeletion().build().also { it.create() }

  @Test fun `atomically registers new version as pending active`() {
    val layout = StorageLayout(File(temporary.root, "registry"))
    var bytes: ByteArray? = RegistryCodec.serialize(Registry(1, "com.example.app", 4, ActiveVersion("1.0.0", true), null, null, "1.0.0", emptyList()))
    val file = object : RegistryFile {
      override fun read(): ByteArray? = bytes
      override fun write(value: ByteArray, faultInjector: RegistryWriteFaultInjector) { bytes = value }
    }
    val store = RegistryStore(layout, { file })
    val old = store.read("com.example.app")!!
    val record = VersionRecord(1, "com.example.app", "2.0.0", "release", "2026-08-18T10:00:00Z", "index.html", "0".repeat(64), emptyList())
    val updated = store.registerPendingUpdate("com.example.app", old, record)
    assertEquals(5, updated.generation)
    assertEquals("2.0.0", updated.active.version)
    assertFalse(updated.active.healthy)
    assertEquals("1.0.0", updated.previous!!.version)
    assertEquals(PendingVersion("2.0.0", 0), updated.pending)
    assertEquals("2.0.0", updated.highestSeenVersion)
  }
}
