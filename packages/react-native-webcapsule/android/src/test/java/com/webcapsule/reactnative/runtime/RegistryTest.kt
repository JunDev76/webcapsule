package com.webcapsule.reactnative.runtime

import java.io.File
import java.nio.charset.StandardCharsets
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.rules.TemporaryFolder

class RegistryTest {
  private val temporary = TemporaryFolder.builder().assureDeletion().build().also { it.create() }

  @Test fun `registry is canonical strict and invariant checked`() {
    val registry = initial()
    val bytes = RegistryCodec.serialize(registry)
    assertEquals(registry, RegistryCodec.parse(bytes, registry.capsuleId))
    expect(WebCapsuleErrorCode.REGISTRY_INVALID) { RegistryCodec.parse(bytes.dropLast(1).toByteArray(), registry.capsuleId) }
    val extra = String(bytes, StandardCharsets.UTF_8).replace("{\"active\"", "{\"extra\":0,\"active\"")
    expect(WebCapsuleErrorCode.REGISTRY_INVALID) { RegistryCodec.parse(extra.toByteArray(), registry.capsuleId) }
    expect(WebCapsuleErrorCode.REGISTRY_INVALID) { RegistryCodec.serialize(registry.copy(active = registry.active.copy(healthy = true))) }
    expect(WebCapsuleErrorCode.REGISTRY_INVALID) { RegistryCodec.serialize(registry.copy(blockedVersions = listOf("1.0.0"))) }
  }

  @Test fun `store requires exact generation increment`() {
    val layout = StorageLayout(File(temporary.root, "generation")); val memory = MemoryRegistryFile()
    val store = RegistryStore(layout, { memory })
    store.createInitial(record())
    expect(WebCapsuleErrorCode.REGISTRY_INVALID) { store.update("com.example.app", 1) { it.copy(generation = 2) } }
    val next = store.update("com.example.app", 0) { it.copy(generation = 1, active = it.active.copy(healthy = true), pending = null) }
    assertEquals(1, next.generation)
    expect(WebCapsuleErrorCode.REGISTRY_INVALID) { store.update("com.example.app", 1) { it.copy(generation = 3) } }
  }

  @Test fun `write failure preserves old registry`() {
    val layout = StorageLayout(File(temporary.root, "fault")); val memory = MemoryRegistryFile()
    RegistryStore(layout, { memory }).createInitial(record())
    val failing = RegistryStore(layout, { memory }, RegistryWriteFaultInjector { if (it == RegistryWriteFaultPoint.AFTER_WRITE) fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, "fault") })
    expect(WebCapsuleErrorCode.STORAGE_IO_FAILED) { failing.update("com.example.app", 0) { it.copy(generation = 1, active = it.active.copy(healthy = true), pending = null) } }
    assertFalse(RegistryStore(layout, { memory }).read("com.example.app")!!.active.healthy)
  }

  @Test fun `capsule lock serializes threads`() {
    val layout = StorageLayout(File(temporary.root, "locks")); val manager = CapsuleLockManager(layout)
    val inside = AtomicInteger(); val maximum = AtomicInteger(); val start = CountDownLatch(1); val pool = Executors.newFixedThreadPool(4)
    val futures = (1..4).map { pool.submit { start.await(); manager.withLock("com.example.app") { maximum.updateAndGet { maxOf(it, inside.incrementAndGet()) }; Thread.sleep(20); inside.decrementAndGet() } } }
    start.countDown(); futures.forEach { it.get() }; pool.shutdown()
    assertEquals(1, maximum.get()); assertTrue(layout.lock("com.example.app").isFile)
  }

  private fun initial() = Registry(1, "com.example.app", 0, ActiveVersion("1.0.0", false), null, PendingVersion("1.0.0", 0), "1.0.0", emptyList())
  private fun record() = VersionRecord(1, "com.example.app", "1.0.0", "release-2027", "2026-08-16T10:00:00Z", "index.html", "a".repeat(64), listOf(CapsuleFileEntry("index.html", "b".repeat(64), 1, "text/html")))
  private fun expect(code: WebCapsuleErrorCode, action: () -> Unit) { try { action(); throw AssertionError("Expected $code") } catch (error: WebCapsuleException) { assertEquals(code, error.code) } }

  private class MemoryRegistryFile : RegistryFile {
    private var bytes: ByteArray? = null
    override fun read(): ByteArray? = bytes?.copyOf()
    override fun write(bytes: ByteArray, faultInjector: RegistryWriteFaultInjector) {
      faultInjector.hit(RegistryWriteFaultPoint.BEFORE_START); faultInjector.hit(RegistryWriteFaultPoint.AFTER_START)
      val candidate = bytes.copyOf(); faultInjector.hit(RegistryWriteFaultPoint.AFTER_WRITE); faultInjector.hit(RegistryWriteFaultPoint.AFTER_SYNC)
      this.bytes = candidate; faultInjector.hit(RegistryWriteFaultPoint.AFTER_FINISH)
    }
  }
}
