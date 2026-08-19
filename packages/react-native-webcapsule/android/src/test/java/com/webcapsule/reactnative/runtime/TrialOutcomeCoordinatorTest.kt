package com.webcapsule.reactnative.runtime

import java.io.File
import java.security.MessageDigest
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.rules.TemporaryFolder

class TrialOutcomeCoordinatorTest {
  private val temporary = TemporaryFolder.builder().assureDeletion().build().also { it.create() }

  @Test fun `first failure remains pending and duplicate failure is idempotent`() {
    val env = environment("first", attempts = 1)
    val session = session(env.registry())
    val first = env.outcomes.recordExplicitFailure(session) as TrialOutcome.Pending
    val second = env.outcomes.recordExplicitFailure(session) as TrialOutcome.Pending
    assertEquals(first.registry, second.registry)
    assertEquals(1, env.registry().pending!!.attempts)
  }

  @Test fun `complete previous is restored and failed version is blocked`() {
    val env = environment("rollback", attempts = 2)
    val outcome = env.outcomes.recordExplicitFailure(session(env.registry())) as TrialOutcome.RolledBack
    assertEquals("1.0.0", outcome.restoredVersion)
    assertEquals(ActiveVersion("1.0.0", true), outcome.registry.active)
    assertNull(outcome.registry.pending)
    assertEquals(listOf("2.0.0"), outcome.registry.blockedVersions)
    assertEquals("2.0.0", outcome.registry.highestSeenVersion)
  }

  @Test fun `startup reconciliation rolls back exhausted pending`() {
    val env = environment("startup", attempts = 2)
    assertTrue(env.outcomes.reconcileExhaustedPending(ID) is TrialOutcome.RolledBack)
    assertEquals("1.0.0", env.registry().active.version)
  }

  @Test fun `missing or corrupted previous uses trusted bundled as unhealthy pending zero`() {
    listOf("missing", "hash").forEach { mode ->
      val env = environment("fallback-$mode", attempts = 2, bundledVersion = "0.9.0")
      val previousDirectory = env.layout.versionDirectory(ID, "1.0.0")
      if (mode == "missing") File(previousDirectory, "record.json").delete()
      else {
        val record = env.versions.read(ID, "1.0.0")
        val blob = env.layout.blob(record.files.single().sha256)
        blob.setWritable(true); blob.writeText("corrupt")
      }
      val outcome = env.outcomes.reconcileExhaustedPending(ID) as TrialOutcome.BundledFallback
      assertEquals(ActiveVersion("0.9.0", false), outcome.registry.active)
      assertEquals(PendingVersion("0.9.0", 0), outcome.registry.pending)
      assertEquals(listOf("2.0.0"), outcome.registry.blockedVersions)
    }
  }

  @Test fun `initial bundled exhaustion and bundled reinstall failure are terminal`() {
    val env = environment("terminal", attempts = 2, previous = false, bundledVersion = "2.0.0")
    assertTrue(env.outcomes.reconcileExhaustedPending(ID) is TrialOutcome.Terminal)
    val failed = environment("terminal-failure", attempts = 2, previous = false, installerFails = true)
    assertTrue(failed.outcomes.reconcileExhaustedPending(ID) is TrialOutcome.Terminal)
  }

  @Test fun `stale session cannot race a healthy transition`() {
    val env = environment("race", attempts = 2)
    val session = session(env.registry())
    assertTrue(env.outcomes.commitHealthy(session) is TrialOutcome.Healthy)
    expect(WebCapsuleErrorCode.SESSION_MISMATCH) { env.outcomes.recordExplicitFailure(session) }
  }

  private fun environment(name: String, attempts: Long, previous: Boolean = true, bundledVersion: String = "0.9.0", installerFails: Boolean = false): Env {
    val layout = StorageLayout(File(temporary.root, name))
    val versions = VersionStore(layout)
    val previousRecord = if (previous) install(versions, layout, "1.0.0", "previous-$name") else null
    install(versions, layout, "2.0.0", "failed-$name")
    val registry = Registry(1, ID, attempts, ActiveVersion("2.0.0", false), previousRecord?.let { PreviousVersion(it.version) }, PendingVersion("2.0.0", attempts), "2.0.0", emptyList())
    val registries = RegistryStore(layout)
    registries.replaceFresh(versions.read(ID, "2.0.0"))
    registries.update(ID, 0) { registry.copy(generation = 1) }
    val locks = CapsuleLockManager(layout)
    val installer = TrustedBundledInstaller {
      if (installerFails) fail(WebCapsuleErrorCode.BUNDLED_CAPSULE_UNAVAILABLE, "missing bundled")
      install(versions, layout, bundledVersion, "bundled-$name")
    }
    return Env(layout, versions, registries, TrialOutcomeCoordinator(locks, registries, versions, installer))
  }

  private fun install(store: VersionStore, layout: StorageLayout, version: String, content: String): VersionRecord {
    try { return store.read(ID, version) } catch (_: WebCapsuleException) { }
    val operation = File(layout.stagingRoot, UUID.randomUUID().toString())
    val blob = File(operation, "blobs/blob").apply { parentFile.mkdirs(); writeText(content) }
    val bytes = content.toByteArray()
    val hash = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    val entry = CapsuleFileEntry("index.html", hash, bytes.size.toLong(), "text/html")
    val manifest = CapsuleManifest(1, ID, version, "index.html", "2026-08-18T10:00:00Z", "1.0.0", "release", listOf(entry), CapsulePolicy(NetworkPolicy("deny", null), NavigationPolicy(emptyList()), emptyList()))
    return store.install(VerifiedCapsule(manifest, byteArrayOf(), "a".repeat(64), listOf(VerifiedBlob(entry.path, hash, entry.size, blob)), operation)).record
  }

  private fun session(registry: Registry) = SessionDescriptor("session", ID, "2.0.0", "index.html", "a".repeat(64), registry.generation, 0, emptyMap(), "2.0.0", registry.pending!!.attempts)
  private fun expect(code: WebCapsuleErrorCode, action: () -> Unit) { try { action(); throw AssertionError("Expected $code") } catch (error: WebCapsuleException) { assertEquals(code, error.code) } }
  private data class Env(val layout: StorageLayout, val versions: VersionStore, val registries: RegistryStore, val outcomes: TrialOutcomeCoordinator) { fun registry() = registries.read(ID)!! }
  companion object { const val ID = "com.example.app" }
}
