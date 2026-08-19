package com.webcapsule.reactnative.runtime

import androidx.core.util.AtomicFile
import java.io.File
import java.io.FileOutputStream

interface RegistryFile {
  fun read(): ByteArray?
  fun write(bytes: ByteArray, faultInjector: RegistryWriteFaultInjector)
}

enum class RegistryWriteFaultPoint { BEFORE_START, AFTER_START, AFTER_WRITE, AFTER_SYNC, AFTER_FINISH }
fun interface RegistryWriteFaultInjector { fun hit(point: RegistryWriteFaultPoint) }

class AndroidAtomicRegistryFile(file: File) : RegistryFile {
  private val atomicFile = AtomicFile(file)

  override fun read(): ByteArray? = try {
    if (!atomicFile.baseFile.exists() && !File(atomicFile.baseFile.path + ".bak").exists()) null else atomicFile.readFully()
  } catch (error: Exception) {
    fail(WebCapsuleErrorCode.REGISTRY_INVALID, "Cannot read registry", error)
  }

  override fun write(bytes: ByteArray, faultInjector: RegistryWriteFaultInjector) {
    var stream: FileOutputStream? = null
    try {
      ContentStore.createDirectories(atomicFile.baseFile.parentFile!!)
      faultInjector.hit(RegistryWriteFaultPoint.BEFORE_START)
      stream = atomicFile.startWrite()
      faultInjector.hit(RegistryWriteFaultPoint.AFTER_START)
      stream.write(bytes)
      faultInjector.hit(RegistryWriteFaultPoint.AFTER_WRITE)
      stream.fd.sync()
      faultInjector.hit(RegistryWriteFaultPoint.AFTER_SYNC)
      atomicFile.finishWrite(stream)
      stream = null
      faultInjector.hit(RegistryWriteFaultPoint.AFTER_FINISH)
    } catch (error: Exception) {
      stream?.let { atomicFile.failWrite(it) }
      if (error is WebCapsuleException) throw error
      fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, "Cannot replace registry", error)
    }
  }
}

class RegistryStore(
  private val layout: StorageLayout,
  private val files: (String) -> RegistryFile = { capsuleId -> AndroidAtomicRegistryFile(layout.registry(capsuleId)) },
  private val faultInjector: RegistryWriteFaultInjector = RegistryWriteFaultInjector { },
) {
  fun read(capsuleId: String): Registry? = files(capsuleId).read()?.let { RegistryCodec.parse(it, capsuleId) }

  fun createInitial(record: VersionRecord): Registry {
    if (read(record.capsuleId) != null) fail(WebCapsuleErrorCode.REGISTRY_INVALID, "Registry already exists")
    val registry = Registry(1, record.capsuleId, 0, ActiveVersion(record.version, false), null, PendingVersion(record.version, 0), record.version, emptyList())
    files(record.capsuleId).write(RegistryCodec.serialize(registry), faultInjector)
    return registry
  }

  fun replaceFresh(record: VersionRecord): Registry {
    val registry = Registry(1, record.capsuleId, 0, ActiveVersion(record.version, false), null, PendingVersion(record.version, 0), record.version, emptyList())
    files(record.capsuleId).write(RegistryCodec.serialize(registry), faultInjector)
    return registry
  }

  fun registerPendingUpdate(capsuleId: String, expected: Registry, record: VersionRecord): Registry {
    if (!expected.active.healthy || expected.pending != null) fail(WebCapsuleErrorCode.UPDATE_TRIAL_IN_PROGRESS, "Registry already contains a trial")
    if (record.capsuleId != capsuleId || ManifestParser.compareVersions(record.version, expected.highestSeenVersion) <= 0) {
      fail(WebCapsuleErrorCode.UPDATE_STATE_CHANGED, "Update record does not advance the registry")
    }
    return try {
      update(capsuleId, expected.generation) { current ->
        if (current != expected) fail(WebCapsuleErrorCode.UPDATE_STATE_CHANGED, "Registry changed during update")
        current.copy(
          generation = current.generation + 1,
          active = ActiveVersion(record.version, false),
          previous = PreviousVersion(current.active.version),
          pending = PendingVersion(record.version, 0),
          highestSeenVersion = record.version,
        )
      }
    } catch (error: WebCapsuleException) {
      if (error.code == WebCapsuleErrorCode.REGISTRY_INVALID) fail(WebCapsuleErrorCode.UPDATE_STATE_CHANGED, "Registry changed during update", error)
      throw error
    }
  }

  fun incrementPendingAttempt(capsuleId: String, expected: Registry): Registry {
    val pending = expected.pending ?: fail(WebCapsuleErrorCode.REGISTRY_INVALID, "Pending trial is missing")
    if (expected.active.healthy || expected.active.version != pending.version || pending.attempts >= MAX_PENDING_ATTEMPTS) {
      fail(WebCapsuleErrorCode.REGISTRY_INVALID, "Pending trial cannot be attempted")
    }
    return update(capsuleId, expected.generation) { current ->
      if (current != expected) fail(WebCapsuleErrorCode.SESSION_MISMATCH, "Registry changed before trial")
      current.copy(generation = current.generation + 1, pending = pending.copy(attempts = pending.attempts + 1))
    }
  }

  fun commitHealthy(capsuleId: String, session: SessionDescriptor): Registry = sessionTransition {
    update(capsuleId, session.registryGeneration) { current ->
      assertSession(current, session)
      current.copy(generation = current.generation + 1, active = current.active.copy(healthy = true), pending = null)
    }
  }

  fun rollbackPending(capsuleId: String, session: SessionDescriptor, restoredVersion: String): Registry = sessionTransition {
    update(capsuleId, session.registryGeneration) { current ->
      assertSession(current, session)
      if (current.pending!!.attempts != MAX_PENDING_ATTEMPTS || current.previous?.version != restoredVersion) {
        fail(WebCapsuleErrorCode.SESSION_MISMATCH, "Final rollback state differs")
      }
      current.copy(
        generation = current.generation + 1,
        active = ActiveVersion(restoredVersion, true),
        previous = null,
        pending = null,
        blockedVersions = insertBlocked(current.blockedVersions, session.version),
      )
    }
  }

  fun rollbackExhausted(capsuleId: String, expected: Registry, restoredVersion: String): Registry =
    update(capsuleId, expected.generation) { current ->
      if (current != expected || current.active.healthy || current.pending?.attempts != MAX_PENDING_ATTEMPTS || current.previous?.version != restoredVersion) {
        fail(WebCapsuleErrorCode.SESSION_MISMATCH, "Exhausted pending state differs")
      }
      current.copy(
        generation = current.generation + 1,
        active = ActiveVersion(restoredVersion, true),
        previous = null,
        pending = null,
        blockedVersions = insertBlocked(current.blockedVersions, current.active.version),
      )
    }

  fun registerBundledFallback(capsuleId: String, expected: Registry, record: VersionRecord): Registry =
    update(capsuleId, expected.generation) { current ->
      if (current != expected || record.capsuleId != capsuleId || record.version == current.active.version) {
        fail(WebCapsuleErrorCode.SESSION_MISMATCH, "Bundled fallback state differs")
      }
      current.copy(
        generation = current.generation + 1,
        active = ActiveVersion(record.version, false),
        previous = null,
        pending = PendingVersion(record.version, 0),
        highestSeenVersion = if (ManifestParser.compareVersions(record.version, current.highestSeenVersion) > 0) record.version else current.highestSeenVersion,
        blockedVersions = insertBlocked(current.blockedVersions, current.active.version),
      )
    }

  fun update(capsuleId: String, expectedGeneration: Long, transform: (Registry) -> Registry): Registry {
    val current = read(capsuleId) ?: fail(WebCapsuleErrorCode.REGISTRY_INVALID, "Registry is missing")
    if (current.generation != expectedGeneration) fail(WebCapsuleErrorCode.REGISTRY_INVALID, "Registry generation conflict")
    if (current.generation == 9_007_199_254_740_991L) fail(WebCapsuleErrorCode.REGISTRY_INVALID, "Registry generation exhausted")
    val transformed = transform(current)
    if (transformed.capsuleId != capsuleId || transformed.schemaVersion != 1 || transformed.generation != current.generation + 1) {
      fail(WebCapsuleErrorCode.REGISTRY_INVALID, "Registry update identity or generation is invalid")
    }
    files(capsuleId).write(RegistryCodec.serialize(transformed), faultInjector)
    return transformed
  }

  private fun <T> sessionTransition(action: () -> T): T = try { action() } catch (error: WebCapsuleException) {
    if (error.code == WebCapsuleErrorCode.REGISTRY_INVALID) fail(WebCapsuleErrorCode.SESSION_MISMATCH, "Registry changed during session", error)
    throw error
  }

  private fun assertSession(current: Registry, session: SessionDescriptor) {
    if (current.generation != session.registryGeneration || current.active.healthy ||
      current.active.version != session.version || current.pending?.version != session.trialVersion ||
      current.pending?.attempts != session.trialAttempt) {
      fail(WebCapsuleErrorCode.SESSION_MISMATCH, "Pending trial no longer matches session")
    }
  }

  private fun insertBlocked(existing: List<String>, version: String): List<String> =
    (existing + version).distinct().sortedWith { left, right -> -ManifestParser.compareVersions(left, right) }
}
