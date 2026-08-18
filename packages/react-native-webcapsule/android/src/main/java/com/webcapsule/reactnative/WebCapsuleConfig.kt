package com.webcapsule.reactnative

data class WebCapsuleConfig(
  val capsuleId: String,
  val bundledAssetPath: String,
  val publicKeys: Map<String, String>,
  val runtimeVersion: String,
)

internal object WebCapsuleConfigValidator {
  private val bundledAssetPattern = Regex("^webcapsule/[A-Za-z0-9._-]+\\.capsule$")

  fun validate(config: WebCapsuleConfig): String? {
    if (config.capsuleId.isEmpty()) return "capsuleId must not be empty"
    if (!bundledAssetPattern.matches(config.bundledAssetPath)) {
      return "bundledAssetPath must match webcapsule/<filename>.capsule"
    }
    val filename = config.bundledAssetPath.removePrefix("webcapsule/").removeSuffix(".capsule")
    if (filename == "." || filename == "..") return "bundledAssetPath filename is invalid"
    if (config.publicKeys.isEmpty()) return "publicKeys must not be empty"
    if (config.publicKeys.any { (keyId, pem) -> keyId.isEmpty() || pem.isEmpty() }) {
      return "publicKeys must contain non-empty key IDs and PEM values"
    }
    if (config.runtimeVersion.isEmpty()) return "runtimeVersion must not be empty"
    return null
  }
}
