package com.webcapsule.reactnative.runtime

import android.os.SystemClock
import java.security.MessageDigest
import java.util.UUID

data class SessionFile(
  val path: String,
  val sha256: String,
  val size: Long,
  val mediaType: String,
)

data class SessionDescriptor(
  val sessionId: String,
  val capsuleId: String,
  val version: String,
  val entry: String,
  val recordSha256: String,
  val registryGeneration: Long,
  val createdElapsedRealtime: Long,
  val files: Map<String, SessionFile>,
  val trialVersion: String?,
  val trialAttempt: Long?,
  val trialToken: PendingTrialGuard.Token? = null,
)

class SessionSelector(
  private val locks: CapsuleLockManager,
  private val recovery: RecoveryManager,
  private val registries: RegistryStore,
  private val versions: VersionStore,
  private val elapsedRealtime: () -> Long = SystemClock::elapsedRealtime,
  private val sessionId: () -> String = { UUID.randomUUID().toString() },
  private val trialGuard: PendingTrialGuard = PendingTrialGuard.process,
  private val reconcileLocked: () -> TrialOutcome? = { null },
) {
  fun select(capsuleId: String): SessionDescriptor = locks.withLock(capsuleId) {
    val recovered = recovery.recoverLocked(capsuleId)
    if (!recovered.registry.active.healthy && recovered.registry.pending?.attempts == MAX_PENDING_ATTEMPTS) reconcileLocked()
    var registry = recovery.recoverLocked(capsuleId).registry
    var attempt: Long? = null
    var trialToken: PendingTrialGuard.Token? = null
    if (!registry.active.healthy) {
      val pending = registry.pending
        ?: fail(WebCapsuleErrorCode.REGISTRY_INVALID, "Unhealthy active has no pending trial")
      if (pending.version != registry.active.version || pending.attempts >= MAX_PENDING_ATTEMPTS) {
        fail(WebCapsuleErrorCode.NO_RUNNABLE_VERSION, "Pending trial attempts are exhausted")
      }
      trialToken = trialGuard.acquire(capsuleId)
      try {
        registry = registries.incrementPendingAttempt(capsuleId, registry)
        attempt = registry.pending!!.attempts
      } catch (error: Throwable) {
        trialToken.release()
        throw error
      }
    }
    val record = try {
      versions.read(capsuleId, registry.active.version)
    } catch (error: Throwable) {
      trialToken?.release()
      throw error
    }
    val digest = MessageDigest.getInstance("SHA-256")
      .digest(VersionRecordCodec.serialize(record))
      .joinToString("") { "%02x".format(it) }
    SessionDescriptor(
      sessionId = sessionId(),
      capsuleId = capsuleId,
      version = record.version,
      entry = record.entry,
      recordSha256 = digest,
      registryGeneration = registry.generation,
      createdElapsedRealtime = elapsedRealtime(),
      files = record.files.associate { it.path to SessionFile(it.path, it.sha256, it.size, it.mediaType) },
      trialVersion = if (registry.active.healthy) null else registry.active.version,
      trialAttempt = attempt,
      trialToken = trialToken,
    )
  }
}
