package com.webcapsule.reactnative.runtime

import java.nio.file.Files
import java.util.UUID

fun interface BundledRecovery {
  /** Independently opens, verifies, and installs the explicitly configured bundled capsule. */
  fun reinstall(capsuleId: String): VersionRecord
}

data class RecoveryResult(val registry: Registry, val activeRecord: VersionRecord, val recoveredFromBundle: Boolean)

class RecoveryManager(
  private val layout: StorageLayout,
  private val locks: CapsuleLockManager,
  private val registries: RegistryStore,
  private val versions: VersionStore,
  private val bundledRecovery: BundledRecovery,
) {
  fun recover(capsuleId: String): RecoveryResult = locks.withLock(capsuleId) { recoverLocked(capsuleId) }

  internal fun recoverLocked(capsuleId: String): RecoveryResult {
    var originalFailure: Throwable? = null
    try {
      val registry = registries.read(capsuleId) ?: fail(WebCapsuleErrorCode.REGISTRY_INVALID, "Registry is missing")
      val active = verifyReferences(registry)
      cleanupStaging()
      return RecoveryResult(registry, active, false)
    } catch (error: Throwable) {
      if (error is WebCapsuleException && error.code == WebCapsuleErrorCode.UNSAFE_STORAGE_LAYOUT) throw error
      originalFailure = error
    }

    cleanupStaging()
    return try {
      val installed = bundledRecovery.reinstall(capsuleId)
      if (installed.capsuleId != capsuleId) fail(WebCapsuleErrorCode.REGISTRY_RECOVERY_FAILED, "Bundled record identity differs")
      val verified = versions.read(installed.capsuleId, installed.version)
      if (verified != installed) fail(WebCapsuleErrorCode.REGISTRY_RECOVERY_FAILED, "Bundled installation result differs")
      val registry = registries.replaceFresh(verified)
      RecoveryResult(registry, verified, true)
    } catch (bundledError: Throwable) {
      val code = if (bundledError is WebCapsuleException && bundledError.code == WebCapsuleErrorCode.BUNDLED_CAPSULE_UNAVAILABLE)
        WebCapsuleErrorCode.BUNDLED_CAPSULE_UNAVAILABLE else WebCapsuleErrorCode.REGISTRY_RECOVERY_FAILED
      val failure = WebCapsuleException(code, "Bundled-only registry recovery failed", bundledError)
      originalFailure?.let(failure::addSuppressed)
      throw failure
    }
  }

  private fun verifyReferences(registry: Registry): VersionRecord {
    val records = linkedMapOf<String, VersionRecord>()
    listOfNotNull(registry.active.version, registry.previous?.version, registry.pending?.version).forEach { version ->
      records[version] = try { versions.read(registry.capsuleId, version) } catch (error: WebCapsuleException) {
        when (error.code) {
          WebCapsuleErrorCode.VERSION_RECORD_INVALID, WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION,
          WebCapsuleErrorCode.STORAGE_IO_FAILED -> fail(WebCapsuleErrorCode.REGISTRY_INVALID, "Registry reference is not runnable", error)
          else -> throw error
        }
      }
    }
    return records[registry.active.version] ?: fail(WebCapsuleErrorCode.NO_RUNNABLE_VERSION, "Active version is absent")
  }

  private fun cleanupStaging() {
    if (!layout.stagingRoot.exists()) return
    if (Files.isSymbolicLink(layout.stagingRoot.toPath()) || !Files.isDirectory(layout.stagingRoot.toPath()))
      fail(WebCapsuleErrorCode.UNSAFE_STORAGE_LAYOUT, "Staging root is not a directory")
    val children = layout.stagingRoot.listFiles() ?: fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, "Cannot list staging root")
    children.forEach { operation ->
      try { UUID.fromString(operation.name) } catch (error: Exception) { fail(WebCapsuleErrorCode.UNSAFE_STORAGE_LAYOUT, "Unexpected staging entry name", error) }
      if (Files.isSymbolicLink(operation.toPath()) || !Files.isDirectory(operation.toPath())) fail(WebCapsuleErrorCode.UNSAFE_STORAGE_LAYOUT, "Unexpected staging entry type")
      val journal = java.io.File(operation, "publish-journal.json")
      if (journal.exists()) cleanupJournalOwnedDirectory(journal)
      if (!operation.deleteRecursively()) fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, "Cannot clean staging operation")
    }
  }

  private fun cleanupJournalOwnedDirectory(journal: java.io.File) {
    if (Files.isSymbolicLink(journal.toPath()) || !Files.isRegularFile(journal.toPath())) fail(WebCapsuleErrorCode.UNSAFE_STORAGE_LAYOUT, "Publish journal is not regular")
    val value = StrictJson.parse(Files.readAllBytes(journal.toPath())) as? Map<*, *> ?: fail(WebCapsuleErrorCode.UNSAFE_STORAGE_LAYOUT, "Publish journal is invalid")
    if (value.keys != setOf("capsuleId", "finalDirectory", "finalDirectoryOwned", "version") || value["finalDirectoryOwned"] != true)
      fail(WebCapsuleErrorCode.UNSAFE_STORAGE_LAYOUT, "Publish journal shape is invalid")
    val capsuleId = value["capsuleId"] as? String ?: fail(WebCapsuleErrorCode.UNSAFE_STORAGE_LAYOUT, "Journal capsule ID is invalid")
    val version = value["version"] as? String ?: fail(WebCapsuleErrorCode.UNSAFE_STORAGE_LAYOUT, "Journal version is invalid")
    val expected = layout.versionDirectory(capsuleId, version).absoluteFile
    if (value["finalDirectory"] != expected.absolutePath) fail(WebCapsuleErrorCode.UNSAFE_STORAGE_LAYOUT, "Journal final directory differs")
    if (expected.exists()) {
      if (Files.isSymbolicLink(expected.toPath()) || !Files.isDirectory(expected.toPath()) || expected.list()?.isNotEmpty() == true)
        return
      if (!expected.delete()) fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, "Cannot remove journal-owned empty version directory")
    }
  }
}
