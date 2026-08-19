package com.webcapsule.reactnative

import com.webcapsule.reactnative.runtime.WebCapsuleErrorCode
import com.webcapsule.reactnative.runtime.WebCapsuleException
import org.junit.Assert.assertEquals
import org.junit.Test

class WebCapsuleStateModuleTest {
  private fun valid(): MutableMap<String, Any?> = linkedMapOf(
    "capsuleId" to "com.example.app",
    "bundledAssetPath" to "webcapsule/v1.capsule",
    "publicKeys" to mapOf("release" to "pem"),
    "runtimeVersion" to "1.0.0",
  )

  @Test fun `parser accepts exact options and public key map`() {
    val result = WebCapsuleStateOptionsParser.parse(valid())
    assertEquals("com.example.app", result.capsuleId)
    assertEquals(mapOf("release" to "pem"), result.publicKeys)
  }

  @Test fun `parser rejects missing extra null wrong types and invalid public key maps`() {
    listOf(
      valid().also { it.remove("runtimeVersion") },
      valid().also { it["extra"] = "x" },
      valid().also { it["capsuleId"] = null },
      valid().also { it["runtimeVersion"] = 1 },
      valid().also { it["publicKeys"] = null },
      valid().also { it["publicKeys"] = mapOf(1 to "pem") },
      valid().also { it["publicKeys"] = mapOf("release" to 1) },
    ).forEach { value -> expect(WebCapsuleErrorCode.INVALID_ARGUMENT) { WebCapsuleStateOptionsParser.parse(value) } }
  }

  @Test fun `state integer contract uses decimal strings`() {
    assertEquals("9007199254740991", 9_007_199_254_740_991L.toString())
    assertEquals("2", 2L.toString())
  }

  private fun expect(code: WebCapsuleErrorCode, action: () -> Unit) {
    try { action(); throw AssertionError("Expected $code") }
    catch (error: WebCapsuleException) { assertEquals(code, error.code) }
  }
}
