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
)

class SessionSelector(
  private val locks: CapsuleLockManager,
  private val recovery: RecoveryManager,
  private val registries: RegistryStore,
  private val versions: VersionStore,
  private val elapsedRealtime: () -> Long = SystemClock::elapsedRealtime,
  private val sessionId: () -> String = { UUID.randomUUID().toString() },
) {
  fun select(capsuleId: String): SessionDescriptor = locks.withLock(capsuleId) {
    val recovered = recovery.recoverLocked(capsuleId)
    var registry = recovered.registry
    var attempt: Long? = null
    if (!registry.active.healthy) {
      val pending = registry.pending
        ?: fail(WebCapsuleErrorCode.REGISTRY_INVALID, "Unhealthy active has no pending trial")
      if (pending.version != registry.active.version || pending.attempts == 9_007_199_254_740_991L) {
        fail(WebCapsuleErrorCode.REGISTRY_INVALID, "Pending trial cannot be attempted")
      }
      attempt = pending.attempts + 1
      registry = registries.update(capsuleId, registry.generation) { current ->
        current.copy(
          generation = current.generation + 1,
          pending = pending.copy(attempts = attempt),
        )
      }
    }
    val record = versions.read(capsuleId, registry.active.version)
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
    )
  }
}
