package com.webcapsule.reactnative.runtime

import android.content.Context
import com.webcapsule.reactnative.WebCapsuleConfig
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.net.URI
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

internal fun interface BundledArchiveSource { fun open(path: String): InputStream }

data class UpdateRequest(
  val config: WebCapsuleConfig,
  val indexUrl: URI,
  val channel: String,
)

sealed class UpdateInstallResult {
  data class Installed(
    val previousVersion: String,
    val currentVersion: String,
    val highestSeenVersion: String,
    val generation: Long,
  ) : UpdateInstallResult()
  data class UpToDate(
    val currentVersion: String,
    val highestSeenVersion: String,
    val generation: Long,
  ) : UpdateInstallResult()
}

class UpdateCoordinator private constructor(
  private val transport: UpdateTransport,
  private val layout: StorageLayout,
  private val updateRoot: File,
  private val bundledSource: BundledArchiveSource,
  private val beforeCommit: () -> Unit,
) {
  constructor(context: Context, transport: UpdateTransport = HttpsUpdateTransport()) : this(
    transport,
    StorageLayout.forNoBackupFilesDir(context.noBackupFilesDir),
    File(context.cacheDir, "webcapsule-update/v1"),
    BundledArchiveSource { context.assets.open(it) },
    {},
  )

  internal constructor(
    transport: UpdateTransport,
    storageRoot: File,
    updateRoot: File,
    bundledSource: BundledArchiveSource,
    beforeCommit: () -> Unit = {},
  ) : this(transport, StorageLayout(storageRoot), updateRoot, bundledSource, beforeCommit)

  companion object { private val running = ConcurrentHashMap.newKeySet<String>() }

  fun install(request: UpdateRequest): UpdateInstallResult {
    val config = request.config
    if (!running.add(config.capsuleId)) fail(WebCapsuleErrorCode.UPDATE_IN_PROGRESS, "An update is already running for this capsule")
    val locks = CapsuleLockManager(layout)
    val registries = RegistryStore(layout)
    val versions = VersionStore(layout)
    val verifier = CapsuleVerifier()
    val recovery = recovery(config, locks, registries, versions, verifier)
    var downloaded: DownloadedCapsule? = null
    try {
      val snapshot = locks.withLock(config.capsuleId) {
        val recovered = recovery.recoverLocked(config.capsuleId).registry
        if (!recovered.active.healthy || recovered.pending != null) fail(WebCapsuleErrorCode.UPDATE_TRIAL_IN_PROGRESS, "A pending trial already exists")
        recovered
      }
      val indexBytes = transport.fetchIndex(request.indexUrl)
      val index = UpdateIndexVerifier.verify(indexBytes, config.capsuleId, request.channel, config.publicKeys)
      val release = UpdateIndexVerifier.select(index, config.runtimeVersion, snapshot.highestSeenVersion, snapshot.blockedVersions.toSet())
        ?: return UpdateInstallResult.UpToDate(snapshot.active.version, snapshot.highestSeenVersion, snapshot.generation)
      downloaded = transport.fetchCapsule(release, updateRoot)
      val verified = verifier.verify(downloaded.file, layout.stagingRoot, config.publicKeys, config.capsuleId, config.runtimeVersion)
      if (verified.manifest.version != release.version) {
        verified.operationDirectory.deleteRecursively()
        fail(WebCapsuleErrorCode.INVALID_UPDATE_INDEX, "Downloaded capsule version differs from release")
      }
      beforeCommit()
      return locks.withLock(config.capsuleId) {
        val current = registries.read(config.capsuleId)
        if (current != snapshot || !current.active.healthy || current.pending != null) {
          verified.operationDirectory.deleteRecursively()
          fail(WebCapsuleErrorCode.UPDATE_STATE_CHANGED, "Registry changed while downloading update")
        }
        versions.read(current.capsuleId, current.active.version)
        current.previous?.let { versions.read(current.capsuleId, it.version) }
        val installed = versions.install(verified).record
        val registry = registries.registerPendingUpdate(config.capsuleId, snapshot, installed)
        UpdateInstallResult.Installed(snapshot.active.version, registry.active.version, registry.highestSeenVersion, registry.generation)
      }
    } finally {
      downloaded?.operationDirectory?.deleteRecursively()
      running.remove(config.capsuleId)
    }
  }

  private fun recovery(
    config: WebCapsuleConfig,
    locks: CapsuleLockManager,
    registries: RegistryStore,
    versions: VersionStore,
    verifier: CapsuleVerifier,
  ) = RecoveryManager(layout, locks, registries, versions) { requestedId ->
    if (requestedId != config.capsuleId) fail(WebCapsuleErrorCode.BUNDLED_CAPSULE_UNAVAILABLE, "Bundled capsule identity differs")
    val operation = File(layout.stagingRoot, UUID.randomUUID().toString())
    ContentStore.createDirectories(operation)
    val archive = File(operation, "bundled.capsule")
    try {
      bundledSource.open(config.bundledAssetPath).use { input -> FileOutputStream(archive).use { output ->
        val buffer = ByteArray(64 * 1024); var total = 0L
        while (true) { val count = input.read(buffer); if (count < 0) break; total += count
          if (total > 100L * 1024 * 1024) fail(WebCapsuleErrorCode.LIMIT_EXCEEDED, "Bundled capsule exceeds archive limit")
          output.write(buffer, 0, count)
        }
        output.fd.sync()
      } }
      versions.install(verifier.verify(archive, layout.stagingRoot, config.publicKeys, config.capsuleId, config.runtimeVersion)).record
    } finally { operation.deleteRecursively() }
  }
}
