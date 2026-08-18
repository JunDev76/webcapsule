package com.webcapsule.reactnative.runtime

import android.os.Handler
import android.os.SystemClock
import java.nio.charset.StandardCharsets

internal data class ReadyMessage(
  val type: String,
  val protocolVersion: Long,
  val sessionId: String,
  val capsuleId: String,
  val version: String,
)

internal object ReadyMessageParser {
  private val fields = setOf("type", "protocolVersion", "sessionId", "capsuleId", "version")

  fun parse(value: String): ReadyMessage {
    val root = try { StrictJson.parse(value.toByteArray(StandardCharsets.UTF_8)) as? Map<*, *> }
    catch (error: WebCapsuleException) { fail(WebCapsuleErrorCode.READY_MESSAGE_INVALID, "Ready message is invalid JSON", error) }
      ?: fail(WebCapsuleErrorCode.READY_MESSAGE_INVALID, "Ready message must be an object")
    if (root.keys.any { it !is String } || root.keys.toSet() != fields) {
      fail(WebCapsuleErrorCode.READY_MESSAGE_INVALID, "Ready message fields differ")
    }
    val type = root["type"] as? String ?: fail(WebCapsuleErrorCode.READY_MESSAGE_INVALID, "Ready type must be a string")
    val protocol = root["protocolVersion"] as? Long ?: fail(WebCapsuleErrorCode.READY_MESSAGE_INVALID, "Ready protocolVersion must be an integer")
    val sessionId = root["sessionId"] as? String ?: fail(WebCapsuleErrorCode.READY_MESSAGE_INVALID, "Ready sessionId must be a string")
    val capsuleId = root["capsuleId"] as? String ?: fail(WebCapsuleErrorCode.READY_MESSAGE_INVALID, "Ready capsuleId must be a string")
    val version = root["version"] as? String ?: fail(WebCapsuleErrorCode.READY_MESSAGE_INVALID, "Ready version must be a string")
    if (type != "ready" || protocol != 1L) fail(WebCapsuleErrorCode.READY_MESSAGE_INVALID, "Ready protocol is unsupported")
    return ReadyMessage(type, protocol, sessionId, capsuleId, version)
  }
}

internal interface HealthScheduler {
  fun now(): Long
  fun schedule(delayMillis: Long, action: () -> Unit): Any
  fun cancel(token: Any)
}

internal class HandlerHealthScheduler(private val handler: Handler) : HealthScheduler {
  override fun now(): Long = SystemClock.elapsedRealtime()
  override fun schedule(delayMillis: Long, action: () -> Unit): Any = Runnable(action).also { handler.postDelayed(it, delayMillis) }
  override fun cancel(token: Any) { handler.removeCallbacks(token as Runnable) }
}

internal class HealthCommitter(
  private val locks: CapsuleLockManager,
  private val registries: RegistryStore,
  private val versions: VersionStore,
) {
  fun commit(session: SessionDescriptor) = locks.withLock(session.capsuleId) {
    val registry = registries.read(session.capsuleId)
      ?: fail(WebCapsuleErrorCode.SESSION_MISMATCH, "Registry disappeared during session")
    if (registry.generation != session.registryGeneration || registry.active.version != session.version) {
      fail(WebCapsuleErrorCode.SESSION_MISMATCH, "Registry changed during session")
    }
    versions.read(session.capsuleId, session.version)
    if (registry.active.healthy) return@withLock
    val pending = registry.pending
    if (pending?.version != session.trialVersion || pending?.attempts != session.trialAttempt) {
      fail(WebCapsuleErrorCode.SESSION_MISMATCH, "Pending attempt changed during session")
    }
    registries.update(session.capsuleId, session.registryGeneration) { current ->
      if (current.active.version != session.version || current.active.healthy ||
        current.pending?.version != session.trialVersion || current.pending?.attempts != session.trialAttempt) {
        fail(WebCapsuleErrorCode.SESSION_MISMATCH, "Pending trial no longer matches session")
      }
      current.copy(
        generation = current.generation + 1,
        active = current.active.copy(healthy = true),
        pending = null,
      )
    }
  }
}

internal class HealthCoordinator(
  private val session: SessionDescriptor,
  private val scheduler: HealthScheduler,
  private val commit: () -> Unit,
  private val success: () -> Unit,
  private val failure: (WebCapsuleException) -> Unit,
) {
  private enum class State { WAITING_FOR_ENTRY, WAITING_FOR_READY, STABILIZING, SUCCEEDED, FAILED, CLOSED }
  private var state = State.WAITING_FOR_ENTRY
  private var timer: Any? = null

  init {
    val remaining = session.createdElapsedRealtime + READY_TIMEOUT_MILLIS - scheduler.now()
    if (remaining <= 0) failOnce(WebCapsuleErrorCode.READY_TIMEOUT, "Ready deadline expired")
    else timer = scheduler.schedule(remaining) { failOnce(WebCapsuleErrorCode.READY_TIMEOUT, "Ready deadline expired") }
  }

  fun entryLoaded() {
    if (state == State.WAITING_FOR_ENTRY) state = State.WAITING_FOR_READY
  }

  fun ready(json: String, sourceOrigin: String, isMainFrame: Boolean) {
    if (state == State.STABILIZING) return failOnce(WebCapsuleErrorCode.READY_MESSAGE_INVALID, "Duplicate ready message")
    if (state != State.WAITING_FOR_READY) return failOnce(WebCapsuleErrorCode.READY_MESSAGE_INVALID, "Ready arrived before entry completed")
    if (!isMainFrame || sourceOrigin != ORIGIN) return failOnce(WebCapsuleErrorCode.READY_MESSAGE_INVALID, "Ready source is not the pinned main frame")
    val message = try { ReadyMessageParser.parse(json) } catch (error: WebCapsuleException) { return failOnce(error.code, error.message ?: "Invalid ready message", error) }
    if (message.sessionId != session.sessionId || message.capsuleId != session.capsuleId || message.version != session.version) {
      return failOnce(WebCapsuleErrorCode.SESSION_MISMATCH, "Ready identity differs from session")
    }
    timer?.let(scheduler::cancel)
    state = State.STABILIZING
    timer = scheduler.schedule(STABILIZATION_MILLIS) {
      try {
        commit()
        if (state == State.STABILIZING) {
          state = State.SUCCEEDED
          timer = null
          success()
        }
      } catch (error: WebCapsuleException) {
        failOnce(error.code, error.message ?: "Health commit failed", error)
      }
    }
  }

  fun entryFailed(message: String) = failOnce(WebCapsuleErrorCode.ENTRY_LOAD_FAILED, message)
  fun invalidReady(message: String) = failOnce(WebCapsuleErrorCode.READY_MESSAGE_INVALID, message)
  fun fatal(message: String) = failOnce(WebCapsuleErrorCode.STABILIZATION_FAILED, message)

  fun close() {
    timer?.let(scheduler::cancel)
    timer = null
    if (state != State.SUCCEEDED && state != State.FAILED) state = State.CLOSED
  }

  private fun failOnce(code: WebCapsuleErrorCode, message: String, cause: Throwable? = null) {
    if (state == State.SUCCEEDED || state == State.FAILED || state == State.CLOSED) return
    timer?.let(scheduler::cancel)
    timer = null
    state = State.FAILED
    failure(WebCapsuleException(code, message, cause))
  }

  companion object {
    const val ORIGIN = "https://webcapsule.local"
    const val READY_TIMEOUT_MILLIS = 15_000L
    const val STABILIZATION_MILLIS = 3_000L
  }
}
