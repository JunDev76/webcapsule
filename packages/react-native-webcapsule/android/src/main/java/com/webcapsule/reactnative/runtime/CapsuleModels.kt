package com.webcapsule.reactnative.runtime

import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

data class CapsuleFileEntry(val path: String, val sha256: String, val size: Long, val mediaType: String)
data class NetworkPolicy(val mode: String, val origins: List<String>?)
data class NavigationPolicy(val externalOrigins: List<String>)
data class CapsulePolicy(
  val network: NetworkPolicy,
  val navigation: NavigationPolicy,
  val bridgeCapabilities: List<String>,
)
data class CapsuleManifest(
  val formatVersion: Int,
  val capsuleId: String,
  val version: String,
  val entry: String,
  val createdAt: String,
  val minimumRuntimeVersion: String,
  val keyId: String,
  val files: List<CapsuleFileEntry>,
  val policy: CapsulePolicy,
)
data class VerifiedBlob(val path: String, val sha256: String, val size: Long, val file: File)
class VerifiedCapsule internal constructor(
  val manifest: CapsuleManifest,
  val canonicalManifest: ByteArray,
  val manifestSha256: String,
  val blobs: List<VerifiedBlob>,
  val operationDirectory: File,
) {
  private val consumed = AtomicBoolean(false)

  internal fun claimForInstall() {
    if (!consumed.compareAndSet(false, true)) {
      fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Verified capsule was already consumed")
    }
  }
}
