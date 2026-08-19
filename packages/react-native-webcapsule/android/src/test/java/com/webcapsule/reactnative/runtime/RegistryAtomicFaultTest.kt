package com.webcapsule.reactnative.runtime

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.rules.TemporaryFolder

class RegistryAtomicFaultTest {
  private val temporary = TemporaryFolder.builder().assureDeletion().build().also { it.create() }

  @Test fun `attempt healthy rollback and bundled transitions are old or complete new at every write fault`() {
    RegistryWriteFaultPoint.entries.forEach { point ->
      verifyFault(point, pending(0)) { store, old -> store.incrementPendingAttempt(ID, old) }
      verifyFault(point, pending(1)) { store, old -> store.commitHealthy(ID, session(old)) }
      verifyFault(point, pending(2)) { store, old -> store.rollbackPending(ID, session(old), "1.0.0") }
      verifyFault(point, pending(2).copy(previous = null)) { store, old -> store.registerBundledFallback(ID, old, record("0.9.0")) }
    }
  }

  private fun verifyFault(point: RegistryWriteFaultPoint, old: Registry, transition: (RegistryStore, Registry) -> Registry) {
    val file = AtomicMemoryRegistryFile(RegistryCodec.serialize(old), point)
    val store = RegistryStore(StorageLayout(File(temporary.root, "${point.name}-${old.generation}-${old.previous != null}")), { file })
    try { transition(store, old) } catch (_: WebCapsuleException) { }
    val parsed = RegistryCodec.parse(file.read()!!, ID)
    assertTrue(parsed == old || parsed.generation == old.generation + 1)
  }

  private fun pending(attempts: Long) = Registry(1, ID, attempts, ActiveVersion("2.0.0", false), PreviousVersion("1.0.0"), PendingVersion("2.0.0", attempts), "2.0.0", emptyList())
  private fun session(registry: Registry) = SessionDescriptor("s", ID, "2.0.0", "index.html", "a".repeat(64), registry.generation, 0, emptyMap(), "2.0.0", registry.pending!!.attempts)
  private fun record(version: String) = VersionRecord(1, ID, version, "release", "2026-08-18T10:00:00Z", "index.html", "a".repeat(64), emptyList())

  private class AtomicMemoryRegistryFile(initial: ByteArray, private val failAt: RegistryWriteFaultPoint) : RegistryFile {
    private var durable = initial.copyOf()
    override fun read() = durable.copyOf()
    override fun write(bytes: ByteArray, faultInjector: RegistryWriteFaultInjector) {
      var finished = false
      try {
        RegistryWriteFaultPoint.entries.forEach { point ->
          if (point == RegistryWriteFaultPoint.AFTER_FINISH) { durable = bytes.copyOf(); finished = true }
          if (point == failAt) fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, "injected")
        }
      } catch (error: Throwable) {
        if (!finished) Unit
        throw error
      }
    }
  }

  companion object { const val ID = "com.example.app" }
}
