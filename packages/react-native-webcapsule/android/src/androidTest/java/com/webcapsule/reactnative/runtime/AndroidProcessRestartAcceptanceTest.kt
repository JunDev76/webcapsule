package com.webcapsule.reactnative.runtime

import android.os.Bundle
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidProcessRestartAcceptanceTest {
  @Test fun runPhase() {
    val arguments: Bundle = InstrumentationRegistry.getArguments()
    val scenario = requireNotNull(arguments.getString("scenario"))
    val phase = requireNotNull(arguments.getString("phase"))
    val env = environment(scenario)
    when (scenario to phase) {
      "attempt1" to "prepare" -> { env.reset(); env.initialize(); val session = env.selector().select(ID); assertEquals(1, session.trialAttempt) }
      "attempt1" to "verify" -> { val session = env.selector().select(ID); assertEquals(2, session.trialAttempt); session.trialToken!!.release() }
      "attempt2" to "prepare" -> { env.reset(); env.initialize(); env.selector().select(ID).trialToken!!.release(); val second = env.selector().select(ID); assertEquals(2, second.trialAttempt) }
      "attempt2" to "verify" -> { assertTrue(env.outcomes().reconcileExhaustedPending(ID) is TrialOutcome.RolledBack); assertEquals("1.0.0", env.selector().select(ID).version) }
      else -> throw AssertionError("Unknown process restart phase")
    }
  }

  private fun environment(scenario: String): Env {
    val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    return Env(context, File(context.noBackupFilesDir, "process-restart-$scenario"))
  }

  private class Env(private val context: android.content.Context, val root: File) {
    val layout get() = StorageLayout(root)
    fun reset() { root.deleteRecursively() }
    fun initialize() {
      val versions = VersionStore(layout); val registries = RegistryStore(layout)
      val v1 = install(versions, "webcapsule/android-e2e-v1.capsule")
      val v2 = install(versions, "webcapsule/android-e2e-v2.capsule")
      registries.createInitial(v1)
      registries.update(ID, 0) { it.copy(generation = 1, active = ActiveVersion(v1.version, true), pending = null) }
      registries.registerPendingUpdate(ID, registries.read(ID)!!, v2)
    }
    fun outcomes(): TrialOutcomeCoordinator {
      val versions = VersionStore(layout); val locks = CapsuleLockManager(layout); val registries = RegistryStore(layout)
      return TrialOutcomeCoordinator(locks, registries, versions) { versions.read(ID, "1.0.0") }
    }
    fun selector(): SessionSelector {
      val versions = VersionStore(layout); val locks = CapsuleLockManager(layout); val registries = RegistryStore(layout); val outcomes = outcomes()
      val recovery = RecoveryManager(layout, locks, registries, versions) { versions.read(ID, "1.0.0") }
      return SessionSelector(locks, recovery, registries, versions, trialGuard = PendingTrialGuard(), reconcileLocked = { outcomes.reconcileExhaustedPendingLocked(ID) })
    }
    private fun install(versions: VersionStore, asset: String): VersionRecord {
      val publicKey = context.assets.open("keys/test-only-public.pem").bufferedReader().readText()
      val archive = File(context.cacheDir, "restart-${UUID.randomUUID()}.capsule")
      context.assets.open(asset).use { input -> archive.outputStream().use(input::copyTo) }
      return try { versions.install(CapsuleVerifier().verify(archive, layout.stagingRoot, mapOf("test-only" to publicKey), ID, "1.0.0")).record }
      finally { archive.delete() }
    }
  }
  companion object { const val ID = "com.example.android.e2e" }
}
