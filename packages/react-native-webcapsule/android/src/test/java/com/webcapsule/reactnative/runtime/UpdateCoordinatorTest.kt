package com.webcapsule.reactnative.runtime

import com.webcapsule.reactnative.WebCapsuleConfig
import java.io.ByteArrayInputStream
import java.io.File
import java.net.URI
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test
import org.junit.rules.TemporaryFolder

class UpdateCoordinatorTest {
  private val temporary = TemporaryFolder.builder().assureDeletion().build().also { it.create() }
  private val fixtureRoot = File(System.getProperty("webcapsule.fixtureRoot"))
  private val publicPem = File(fixtureRoot, "keys/test-only-public.pem").readText()
  private val v1 = File(fixtureRoot, "capsules/android-e2e-v1.capsule")
  private val v2 = File(fixtureRoot, "capsules/android-e2e-v2.capsule")
  private val index = File(fixtureRoot, "update-index-v1/valid-signed.json").readBytes()
  private val config = WebCapsuleConfig("com.example.android.e2e", "webcapsule/v1.capsule", mapOf("test-only" to publicPem), "1.0.0")

  @Test fun `installs v2 and atomically registers exact pending transition while old session stays pinned`() {
    val env = environment(); val old = env.selector.select(config.capsuleId)
    val result = env.coordinator(FakeTransport(index, v2)).install(request()) as UpdateInstallResult.Installed
    val registry = env.registries.read(config.capsuleId)!!
    assertEquals("1.0.0", result.previousVersion); assertEquals("2.0.0", result.currentVersion)
    assertEquals(2, registry.generation); assertEquals(ActiveVersion("2.0.0", false), registry.active)
    assertEquals(PreviousVersion("1.0.0"), registry.previous); assertEquals(PendingVersion("2.0.0", 0), registry.pending)
    assertEquals("1.0.0", old.version)
    val next = env.selector.select(config.capsuleId); assertEquals("2.0.0", next.version); assertEquals("2.0.0", next.trialVersion)
  }

  @Test fun `up to date does not fetch capsule or mutate registry bytes`() {
    val env = environment(highest = "2.0.0"); val before = env.layout.registry(config.capsuleId).readBytes(); val transport = FakeTransport(index, v2)
    assertTrue(env.coordinator(transport).install(request()) is UpdateInstallResult.UpToDate)
    assertEquals(0, transport.capsuleFetches); assertArrayEquals(before, env.layout.registry(config.capsuleId).readBytes())
  }

  @Test fun `existing pending fails before index fetch`() {
    val env = environment(); env.registries.update(config.capsuleId, 1) { it.copy(generation = 2, active = ActiveVersion("1.0.0", false), pending = PendingVersion("1.0.0", 0)) }
    val transport = FakeTransport(index, v2); expect(WebCapsuleErrorCode.UPDATE_TRIAL_IN_PROGRESS) { env.coordinator(transport).install(request()) }
    assertEquals(0, transport.indexFetches)
  }

  @Test fun `index descriptor and capsule verification failures preserve registry and clean temporary directories`() {
    val badHash = String(index).replace(Regex("\"sha256\": \"[0-9a-f]{64}\""), "\"sha256\": \"${"0".repeat(64)}\"").toByteArray()
    val cases = listOf(
      File(fixtureRoot, "update-index-v1/signature-mismatch.json").readBytes() to v2,
      badHash to v2,
      index to File(fixtureRoot, "capsules/signature-mismatch.capsule"),
      index to v1,
    )
    cases.forEach { (indexBytes, capsule) ->
      val env = environment(); val before = env.layout.registry(config.capsuleId).readBytes()
      try { env.coordinator(FakeTransport(indexBytes, capsule)).install(request()); fail("expected failure") } catch (_: WebCapsuleException) {}
      assertArrayEquals(before, env.layout.registry(config.capsuleId).readBytes()); assertTrue(env.updateRoot.listFiles()?.isEmpty() != false)
      assertTrue(env.layout.stagingRoot.listFiles()?.isEmpty() != false)
    }
  }

  @Test fun `stale registry is never overwritten and verified operation is cleaned`() {
    lateinit var env: Environment
    env = environment()
    val coordinator = env.coordinator(FakeTransport(index, v2)) {
      env.registries.update(config.capsuleId, 1) { it.copy(generation = 2) }
    }
    expect(WebCapsuleErrorCode.UPDATE_STATE_CHANGED) { coordinator.install(request()) }
    assertEquals(2, env.registries.read(config.capsuleId)!!.generation)
    assertTrue(env.layout.stagingRoot.listFiles()?.isEmpty() != false); assertTrue(env.updateRoot.listFiles()?.isEmpty() != false)
  }

  @Test fun `same capsule concurrent request fails immediately and storage lock is free during network fetch`() {
    val env = environment(); val entered = CountDownLatch(1); val release = CountDownLatch(1)
    val transport = FakeTransport(index, v2, entered, release); val failure = AtomicReference<Throwable?>()
    val thread = Thread { try { env.coordinator(transport).install(request()) } catch (error: Throwable) { failure.set(error) } }.also { it.start() }
    assertTrue(entered.await(5, TimeUnit.SECONDS))
    CapsuleLockManager(env.layout).withLock(config.capsuleId) { assertTrue(true) }
    expect(WebCapsuleErrorCode.UPDATE_IN_PROGRESS) { env.coordinator(FakeTransport(index, v2)).install(request()) }
    release.countDown(); thread.join(10_000); failure.get()?.let { throw it }
  }

  private fun environment(highest: String = "1.0.0"): Environment {
    val root = File(temporary.newFolder(), "storage"); val layout = StorageLayout(root); val versions = VersionStore(layout)
    val archive = File(temporary.newFolder(), "v1.capsule"); v1.copyTo(archive)
    val installed = versions.install(CapsuleVerifier().verify(archive, layout.stagingRoot, config.publicKeys, config.capsuleId, config.runtimeVersion)).record
    val registries = RegistryStore(layout); registries.createInitial(installed)
    registries.update(config.capsuleId, 0) { it.copy(generation = 1, active = ActiveVersion("1.0.0", true), pending = null, highestSeenVersion = highest) }
    val locks = CapsuleLockManager(layout)
    val recovery = RecoveryManager(layout, locks, registries, versions) { installed }
    return Environment(layout, File(temporary.newFolder(), "updates"), registries, SessionSelector(locks, recovery, registries, versions, { 1 }, { UUID.randomUUID().toString() }))
  }

  private fun request() = UpdateRequest(config, URI("https://example.com/index.json"), "stable")
  private inner class FakeTransport(private val indexBytes: ByteArray, private val capsule: File, private val entered: CountDownLatch? = null, private val release: CountDownLatch? = null) : UpdateTransport {
    var indexFetches = 0; var capsuleFetches = 0
    override fun fetchIndex(uri: URI): ByteArray { indexFetches++; entered?.countDown(); release?.await(5, TimeUnit.SECONDS); return indexBytes }
    override fun fetchCapsule(release: UpdateRelease, updateRoot: File): DownloadedCapsule {
      capsuleFetches++; val operation = File(updateRoot, UUID.randomUUID().toString()); operation.mkdirs(); val target = File(operation, "download.capsule"); capsule.copyTo(target); return DownloadedCapsule(target, operation)
    }
  }
  private inner class Environment(val layout: StorageLayout, val updateRoot: File, val registries: RegistryStore, val selector: SessionSelector) {
    fun coordinator(transport: UpdateTransport, beforeCommit: () -> Unit = {}) = UpdateCoordinator(transport, layout.root, updateRoot, BundledArchiveSource { v1.inputStream() }, beforeCommit)
  }
  private fun expect(code: WebCapsuleErrorCode, action: () -> Unit) { try { action(); fail("Expected $code") } catch (error: WebCapsuleException) { assertEquals(code, error.code) } }
}
