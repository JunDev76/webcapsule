package com.webcapsule.reactnative

import com.webcapsule.reactnative.runtime.WebCapsuleErrorCode
import com.webcapsule.reactnative.runtime.WebCapsuleException
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class WebCapsuleUpdateModuleTest {
  private fun valid(): MutableMap<String, Any?> = linkedMapOf(
    "capsuleId" to "com.example.android.e2e", "bundledAssetPath" to "webcapsule/v1.capsule",
    "publicKeys" to mapOf("test-only" to "pem"), "runtimeVersion" to "1.0.0",
    "indexUrl" to "https://example.com/stable.json", "channel" to "stable",
  )

  @Test fun `parses exact options and maps generation as decimal string`() {
    val request = WebCapsuleUpdateOptionsParser.parse(valid())
    assertEquals("com.example.android.e2e", request.config.capsuleId)
    assertEquals("https://example.com/stable.json", request.indexUrl.toString())
    assertEquals(Long.MAX_VALUE.toString(), Long.MAX_VALUE.toString())
  }

  @Test fun `rejects missing extra null wrong types and non-string public key entries`() {
    val values = listOf(
      valid().also { it.remove("channel") }, valid().also { it["extra"] = "x" },
      valid().also { it["channel"] = null }, valid().also { it["channel"] = 1 },
      valid().also { it["publicKeys"] = mapOf(1 to "pem") }, valid().also { it["publicKeys"] = mapOf("key" to 1) },
    )
    values.forEach { value -> expect(WebCapsuleErrorCode.INVALID_ARGUMENT) { WebCapsuleUpdateOptionsParser.parse(value) } }
  }

  @Test fun `preserves stable URL validation error mapping`() {
    expect(WebCapsuleErrorCode.INVALID_URL) { WebCapsuleUpdateOptionsParser.parse(valid().also { it["indexUrl"] = "http://example.com/i" }) }
  }

  private fun expect(code: WebCapsuleErrorCode, action: () -> Unit) {
    try { action(); fail("Expected $code") } catch (error: WebCapsuleException) { assertEquals(code, error.code) }
  }
}
