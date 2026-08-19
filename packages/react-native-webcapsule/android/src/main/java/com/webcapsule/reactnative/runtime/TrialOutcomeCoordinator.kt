package com.webcapsule.reactnative.runtime

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

class PendingTrialGuard {
  class Token internal constructor(
    private val capsuleId: String,
    private val owner: PendingTrialGuard,
  ) {
    private val released = AtomicBoolean()
    fun release() {
      if (released.compareAndSet(false, true)) owner.release(capsuleId, this)
    }
  }

  private val active = ConcurrentHashMap<String, Token>()

  fun acquire(capsuleId: String): Token {
    val token = Token(capsuleId, this)
    if (active.putIfAbsent(capsuleId, token) != null) {
      fail(WebCapsuleErrorCode.TRIAL_SESSION_IN_PROGRESS, "A pending trial is already running")
    }
    return token
  }

  private fun release(capsuleId: String, token: Token) {
    active.remove(capsuleId, token)
  }

  companion object { val process = PendingTrialGuard() }
}

sealed class TrialOutcome {
  data class Healthy(val registry: Registry) : TrialOutcome()
  data class Pending(val registry: Registry) : TrialOutcome()
  data class RolledBack(val registry: Registry, val failedVersion: String, val restoredVersion: String) : TrialOutcome()
  data class BundledFallback(val registry: Registry, val failedVersion: String, val bundledVersion: String) : TrialOutcome()
  data class Terminal(val failedVersion: String) : TrialOutcome()
}

fun interface TrustedBundledInstaller {
  fun install(capsuleId: String): VersionRecord
}

class TrialOutcomeCoordinator(
  private val locks: CapsuleLockManager,
  private val registries: RegistryStore,
  private val versions: VersionStore,
  private val bundledInstaller: TrustedBundledInstaller,
) {
  private val completedFailures = ConcurrentHashMap<String, TrialOutcome>()
  fun commitHealthy(session: SessionDescriptor): TrialOutcome = locks.withLock(session.capsuleId) {
    versions.read(session.capsuleId, session.version)
    if (session.trialVersion == null) {
      val registry = registries.read(session.capsuleId) ?: fail(WebCapsuleErrorCode.SESSION_MISMATCH, "Registry disappeared during session")
      if (!registry.active.healthy || registry.active.version != session.version) fail(WebCapsuleErrorCode.SESSION_MISMATCH, "Healthy session is no longer active")
      TrialOutcome.Healthy(registry)
    } else TrialOutcome.Healthy(registries.commitHealthy(session.capsuleId, session))
  }

  fun recordExplicitFailure(session: SessionDescriptor): TrialOutcome {
    completedFailures[session.sessionId]?.let { return it }
    return locks.withLock(session.capsuleId) {
      completedFailures[session.sessionId]?.let { return@withLock it }
      val outcome = if (session.trialVersion == null) {
        val registry = registries.read(session.capsuleId) ?: fail(WebCapsuleErrorCode.SESSION_MISMATCH, "Registry disappeared during session")
        TrialOutcome.Healthy(registry)
      } else {
        val registry = matchingRegistry(session)
        if (registry.pending!!.attempts < MAX_PENDING_ATTEMPTS) TrialOutcome.Pending(registry)
        else reconcileLocked(registry, session)
      }
      completedFailures[session.sessionId] = outcome
      outcome
    }
  }

  fun reconcileExhaustedPending(capsuleId: String): TrialOutcome? = locks.withLock(capsuleId) {
    reconcileExhaustedPendingLocked(capsuleId)
  }

  internal fun reconcileExhaustedPendingLocked(capsuleId: String): TrialOutcome? {
    val registry = registries.read(capsuleId) ?: fail(WebCapsuleErrorCode.REGISTRY_INVALID, "Registry is missing")
    if (registry.active.healthy || registry.pending?.attempts != MAX_PENDING_ATTEMPTS) return null
    return reconcileLocked(registry, null)
  }

  private fun reconcileLocked(registry: Registry, session: SessionDescriptor?): TrialOutcome {
    val failed = registry.active.version
    val previous = registry.previous?.version
    if (previous != null) {
      try {
        versions.read(registry.capsuleId, previous)
        val next = if (session != null) registries.rollbackPending(registry.capsuleId, session, previous)
        else registries.rollbackExhausted(registry.capsuleId, registry, previous)
        return TrialOutcome.RolledBack(next, failed, previous)
      } catch (error: WebCapsuleException) {
        if (error.code == WebCapsuleErrorCode.SESSION_MISMATCH || error.code == WebCapsuleErrorCode.REGISTRY_INVALID) throw error
      }
    }

    val bundled = try { bundledInstaller.install(registry.capsuleId) } catch (error: Throwable) {
      if (previous == null) return TrialOutcome.Terminal(failed)
      fail(WebCapsuleErrorCode.ROLLBACK_TARGET_UNAVAILABLE, "Neither previous nor bundled capsule is runnable", error)
    }
    val verified = try { versions.read(bundled.capsuleId, bundled.version) } catch (error: Throwable) {
      fail(WebCapsuleErrorCode.ROLLBACK_FAILED, "Bundled fallback installation is incomplete", error)
    }
    if (verified != bundled || bundled.capsuleId != registry.capsuleId || bundled.version == failed) {
      if (previous == null && bundled.version == failed) return TrialOutcome.Terminal(failed)
      fail(WebCapsuleErrorCode.ROLLBACK_FAILED, "Bundled fallback identity is invalid")
    }
    val next = registries.registerBundledFallback(registry.capsuleId, registry, bundled)
    return TrialOutcome.BundledFallback(next, failed, bundled.version)
  }

  private fun matchingRegistry(session: SessionDescriptor): Registry {
    val registry = registries.read(session.capsuleId)
      ?: fail(WebCapsuleErrorCode.SESSION_MISMATCH, "Registry disappeared during trial")
    if (registry.generation != session.registryGeneration || registry.active.healthy ||
      registry.active.version != session.version || registry.pending?.version != session.trialVersion ||
      registry.pending?.attempts != session.trialAttempt) {
      fail(WebCapsuleErrorCode.SESSION_MISMATCH, "Pending trial no longer matches session")
    }
    return registry
  }
}
