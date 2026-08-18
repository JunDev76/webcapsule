package com.webcapsule.reactnative.runtime

import android.content.Context
import com.webcapsule.reactnative.WebCapsuleConfig
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

class AndroidRuntimeCoordinator(
  private val context: Context,
  private val storageRootOverride: File? = null,
) {
  fun ensureSession(config: WebCapsuleConfig): SessionDescriptor {
    val layout = storageRootOverride?.let(::StorageLayout)
      ?: StorageLayout.forNoBackupFilesDir(context.noBackupFilesDir)
    val locks = CapsuleLockManager(layout)
    val registries = RegistryStore(layout)
    val versions = VersionStore(layout)
    val verifier = CapsuleVerifier()
    val recovery = RecoveryManager(layout, locks, registries, versions) { requestedId ->
      if (requestedId != config.capsuleId) fail(WebCapsuleErrorCode.BUNDLED_CAPSULE_UNAVAILABLE, "Bundled capsule identity differs")
      val archive = copyBundledAsset(config, layout)
      try {
        versions.install(verifier.verify(archive, layout.stagingRoot, config.publicKeys, config.capsuleId, config.runtimeVersion)).record
      } catch (error: WebCapsuleException) {
        if (error.code == WebCapsuleErrorCode.BUNDLED_SOURCE_INVALID) throw error
        fail(WebCapsuleErrorCode.BUNDLED_CAPSULE_UNAVAILABLE, "Bundled capsule cannot be installed", error)
      } finally {
        archive.parentFile?.deleteRecursively()
      }
    }
    return SessionSelector(locks, recovery, registries, versions).select(config.capsuleId)
  }

  private fun copyBundledAsset(config: WebCapsuleConfig, layout: StorageLayout): File {
    val operation = File(layout.stagingRoot, UUID.randomUUID().toString())
    ContentStore.createDirectories(operation)
    val archive = File(operation, "bundled.capsule")
    try {
      context.assets.open(config.bundledAssetPath).use { input ->
        FileOutputStream(archive).use { output ->
          val buffer = ByteArray(64 * 1024)
          var total = 0L
          while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            if (total > 100L * 1024 * 1024) fail(WebCapsuleErrorCode.LIMIT_EXCEEDED, "Bundled capsule exceeds archive limit")
            output.write(buffer, 0, count)
          }
          output.fd.sync()
        }
      }
      return archive
    } catch (error: WebCapsuleException) {
      operation.deleteRecursively(); throw error
    } catch (error: Exception) {
      operation.deleteRecursively()
      fail(WebCapsuleErrorCode.BUNDLED_CAPSULE_UNAVAILABLE, "Bundled asset cannot be read", error)
    }
  }
}
