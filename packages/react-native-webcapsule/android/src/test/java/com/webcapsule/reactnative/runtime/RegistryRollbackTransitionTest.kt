package com.webcapsule.reactnative.runtime

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.rules.TemporaryFolder

class RegistryRollbackTransitionTest {
  private val temporary = TemporaryFolder.builder().assureDeletion().build().also { it.create() }

  @Test fun `attempt healthy and final rollback are named bounded transitions`() {
    val memory = MemoryRegistryFile(RegistryCodec.serialize(pending(0)))
    val store = RegistryStore(StorageLayout(File(temporary.root, "transitions")), { memory })
    val first = store.incrementPendingAttempt(ID, store.read(ID)!!)
    assertEquals(1, first.pending!!.attempts)
    val second = store.incrementPendingAttempt(ID, first)
    assertEquals(2, second.pending!!.attempts)
    expect(WebCapsuleErrorCode.REGISTRY_INVALID) { store.incrementPendingAttempt(ID, second) }
    val session = session(second)
    val rolled = store.rollbackPending(ID, session, "1.0.0")
    assertEquals("1.0.0", rolled.active.version)
    assertTrue(rolled.active.healthy)
    assertNull(rolled.pending); assertNull(rolled.previous)
    assertEquals(listOf("2.0.0"), rolled.blockedVersions)
    assertEquals("2.0.0", rolled.highestSeenVersion)
  }

  @Test fun `healthy commit requires exact session identity`() {
    val memory = MemoryRegistryFile(RegistryCodec.serialize(pending(1)))
    val store = RegistryStore(StorageLayout(File(temporary.root, "healthy")), { memory })
    val registry = store.read(ID)!!
    val healthy = store.commitHealthy(ID, session(registry))
    assertTrue(healthy.active.healthy); assertNull(healthy.pending)
    expect(WebCapsuleErrorCode.SESSION_MISMATCH) { store.commitHealthy(ID, session(registry)) }
  }

  @Test fun `bundled fallback blocks failed version and preserves highest seen`() {
    val memory = MemoryRegistryFile(RegistryCodec.serialize(pending(2).copy(previous = null)))
    val store = RegistryStore(StorageLayout(File(temporary.root, "bundle")), { memory })
    val registry = store.read(ID)!!
    val bundled = record("1.0.0")
    val next = store.registerBundledFallback(ID, registry, bundled)
    assertEquals(ActiveVersion("1.0.0", false), next.active)
    assertEquals(PendingVersion("1.0.0", 0), next.pending)
    assertEquals(listOf("2.0.0"), next.blockedVersions)
    assertEquals("2.0.0", next.highestSeenVersion)
    assertFalse(next.active.healthy)
  }

  private fun pending(attempts: Long) = Registry(1, ID, attempts, ActiveVersion("2.0.0", false), PreviousVersion("1.0.0"), PendingVersion("2.0.0", attempts), "2.0.0", emptyList())
  private fun session(registry: Registry) = SessionDescriptor("s", ID, "2.0.0", "index.html", "a".repeat(64), registry.generation, 0, emptyMap(), "2.0.0", registry.pending!!.attempts)
  private fun record(version: String) = VersionRecord(1, ID, version, "release", "2026-08-18T10:00:00Z", "index.html", "a".repeat(64), emptyList())
  private fun expect(code: WebCapsuleErrorCode, action: () -> Unit) { try { action(); throw AssertionError("Expected $code") } catch (error: WebCapsuleException) { assertEquals(code, error.code) } }

  private class MemoryRegistryFile(initial: ByteArray?) : RegistryFile {
    private var bytes = initial
    override fun read() = bytes?.copyOf()
    override fun write(bytes: ByteArray, faultInjector: RegistryWriteFaultInjector) { faultInjector.hit(RegistryWriteFaultPoint.BEFORE_START); val next = bytes.copyOf(); faultInjector.hit(RegistryWriteFaultPoint.AFTER_WRITE); this.bytes = next; faultInjector.hit(RegistryWriteFaultPoint.AFTER_FINISH) }
  }

  companion object { const val ID = "com.example.app" }
}
