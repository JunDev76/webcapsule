package com.webcapsule.reactnative

import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Test

class WebCapsuleConfigValidatorTest {
  private val valid = WebCapsuleConfig(
    capsuleId = "com.example.guide",
    bundledAssetPath = "webcapsule/guide-1.0.0.capsule",
    publicKeys = mapOf("release-2027" to "PUBLIC KEY"),
    runtimeVersion = "1.0.0",
  )

  @Test fun acceptsExactBundledAssetSyntax() = assertNull(WebCapsuleConfigValidator.validate(valid))

  @Test fun rejectsUrlsAndNestedAssets() {
    listOf(
      "https://example.com/guide.capsule",
      "file://guide.capsule",
      "/webcapsule/guide.capsule",
      "webcapsule/nested/guide.capsule",
      "webcapsule/guide.zip",
    ).forEach { path ->
      assertNotNull(WebCapsuleConfigValidator.validate(valid.copy(bundledAssetPath = path)))
    }
  }

  @Test fun rejectsMissingRequiredValues() {
    assertNotNull(WebCapsuleConfigValidator.validate(valid.copy(capsuleId = "")))
    assertNotNull(WebCapsuleConfigValidator.validate(valid.copy(publicKeys = emptyMap())))
    assertNotNull(WebCapsuleConfigValidator.validate(valid.copy(runtimeVersion = "")))
  }
}
