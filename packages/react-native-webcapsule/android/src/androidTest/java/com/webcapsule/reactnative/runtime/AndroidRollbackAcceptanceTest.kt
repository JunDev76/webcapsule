package com.webcapsule.reactnative.runtime

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidRollbackAcceptanceTest {
  @Test fun explicitFailuresUseRealAtomicFileHardLinksAndRestorePrevious() {
    val env = environment("rollback")
    try {
      val first = env.selector.select(ID)
      assertEquals(1, first.trialAttempt)
      assertTrue(env.outcomes.recordExplicitFailure(first) is TrialOutcome.Pending)
      first.trialToken!!.release()
      val second = env.selector.select(ID)
      assertEquals(2, second.trialAttempt)
      val rolled = env.outcomes.recordExplicitFailure(second) as TrialOutcome.RolledBack
      second.trialToken!!.release()
      assertEquals(ActiveVersion("1.0.0", true), rolled.registry.active)
      assertNull(rolled.registry.pending)
      assertEquals(listOf("2.0.0"), rolled.registry.blockedVersions)
      assertEquals("2.0.0", rolled.registry.highestSeenVersion)
      assertEquals("1.0.0", env.selector.select(ID).version)
    } finally { env.root.deleteRecursively() }
  }

  @Test fun concurrentPendingGuardAndRestartReconciliationAreDeterministic() {
    val env = environment("guard")
    try {
      val first = env.selector.select(ID)
      assertThrows(WebCapsuleException::class.java) { env.selector.select(ID) }
      first.trialToken!!.release()
      val second = env.selector.select(ID)
      second.trialToken!!.release()
      assertTrue(env.outcomes.reconcileExhaustedPending(ID) is TrialOutcome.RolledBack)
      assertEquals("1.0.0", env.selector.select(ID).version)
    } finally { env.root.deleteRecursively() }
  }

  private fun environment(name: String): Env {
    val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    val root = File(context.noBackupFilesDir, "rollback-$name-${UUID.randomUUID()}")
    val layout = StorageLayout(root); val versions = VersionStore(layout); val registries = RegistryStore(layout); val locks = CapsuleLockManager(layout)
    val publicKey = context.assets.open("keys/test-only-public.pem").bufferedReader().readText()
    fun install(asset: String): VersionRecord {
      val archive = File(context.cacheDir, "rollback-${UUID.randomUUID()}.capsule")
      context.assets.open(asset).use { input -> archive.outputStream().use(input::copyTo) }
      return try { versions.install(CapsuleVerifier().verify(archive, layout.stagingRoot, mapOf("test-only" to publicKey), ID, "1.0.0")).record }
      finally { archive.delete() }
    }
    val v1 = install("webcapsule/android-e2e-v1.capsule")
    val v2 = install("webcapsule/android-e2e-v2.capsule")
    registries.createInitial(v1)
    registries.update(ID, 0) { it.copy(generation = 1, active = ActiveVersion(v1.version, true), pending = null) }
    val healthy = registries.read(ID)!!
    registries.registerPendingUpdate(ID, healthy, v2)
    val recovery = RecoveryManager(layout, locks, registries, versions) { v1 }
    val outcomes = TrialOutcomeCoordinator(locks, registries, versions) { v1 }
    val selector = SessionSelector(locks, recovery, registries, versions, trialGuard = PendingTrialGuard(), reconcileLocked = { outcomes.reconcileExhaustedPendingLocked(ID) })
    return Env(root, selector, outcomes)
  }

  private data class Env(val root: File, val selector: SessionSelector, val outcomes: TrialOutcomeCoordinator)
  companion object { const val ID = "com.example.android.e2e" }
}
