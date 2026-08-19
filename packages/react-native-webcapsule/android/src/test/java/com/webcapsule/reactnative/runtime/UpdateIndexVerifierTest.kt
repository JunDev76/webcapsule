package com.webcapsule.reactnative.runtime

import java.io.File
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64
import org.erdtman.jcs.JsonCanonicalizer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail as junitFail
import org.junit.Test

class UpdateIndexVerifierTest {
  private val fixtureRoot = File(System.getProperty("webcapsule.fixtureRoot"))
  private val publicPem = File(fixtureRoot, "keys/test-only-public.pem").readText()
  private val privateKey = privateKey(File(fixtureRoot, "keys/test-only-private.pem").readText())

  @Test fun `verifies noncanonical signed JSON and selects first compatible advancing release`() {
    val bytes = signedIndex(listOf(
      release("3.0.0", "9.0.0"),
      release("2.0.0", "1.0.0"),
      release("1.5.0", "1.0.0"),
    ), pretty = true)
    val index = UpdateIndexVerifier.verify(bytes, "com.example.fixture", "stable", mapOf("test-only" to publicPem))
    assertEquals("2.0.0", UpdateIndexVerifier.select(index, "1.0.0", "1.0.0", emptySet())!!.version)
    assertNull(UpdateIndexVerifier.select(index, "1.0.0", "2.0.0", emptySet()))
  }

  @Test fun `rejects equivalent SemVer precedence`() {
    val bytes = signedIndex(listOf(release("2.0.0+one", "1.0.0"), release("2.0.0+two", "1.0.0")))
    expect(WebCapsuleErrorCode.INVALID_ORDER) {
      UpdateIndexVerifier.verify(bytes, "com.example.fixture", "stable", mapOf("test-only" to publicPem))
    }
  }

  @Test fun `shared signed update index fixtures match expected results`() {
    val publicKey = File(fixtureRoot, "keys/test-only-public.pem").readText()
    UpdateIndexVerifier.verify(File(fixtureRoot, "update-index-v1/valid-signed.json").readBytes(), "com.example.android.e2e", "stable", mapOf("test-only" to publicKey))
    expect(WebCapsuleErrorCode.SIGNATURE_MISMATCH) {
      UpdateIndexVerifier.verify(File(fixtureRoot, "update-index-v1/signature-mismatch.json").readBytes(), "com.example.android.e2e", "beta", mapOf("test-only" to publicKey))
    }
  }

  @Test fun `rejects URL credentials and fragments`() {
    listOf("https://user@example.com/a", "https://example.com/a#x", "http://example.com/a").forEach { url ->
      expect(WebCapsuleErrorCode.INVALID_URL) { UpdateIndexVerifier.strictHttps(url) }
    }
  }

  private fun release(version: String, minimum: String) = "{\"minimumRuntimeVersion\":\"$minimum\",\"sha256\":\"${"a".repeat(64)}\",\"size\":1,\"url\":\"https://example.com/$version.capsule\",\"version\":\"$version\"}"
  private fun signedIndex(releases: List<String>, pretty: Boolean = false): ByteArray {
    val unsigned = "{\"capsuleId\":\"com.example.fixture\",\"channel\":\"stable\",\"keyId\":\"test-only\",\"releases\":[${releases.joinToString(",")}],\"schemaVersion\":1}"
    val canonical = JsonCanonicalizer(unsigned).encodedUTF8
    val signature = Signature.getInstance("Ed25519").run { initSign(privateKey); update("WEBCAPSULE-UPDATE-INDEX-V1\n".toByteArray() + canonical); sign() }
    val encoded = Base64.getEncoder().encodeToString(signature)
    val signed = unsigned.dropLast(1) + ",\"signature\":\"$encoded\"}"
    return if (pretty) signed.replace(",", ",\n  ").toByteArray() else signed.toByteArray()
  }
  private fun privateKey(pem: String): PrivateKey {
    val der = Base64.getMimeDecoder().decode(pem.substringAfter("-----BEGIN PRIVATE KEY-----").substringBefore("-----END PRIVATE KEY-----"))
    return KeyFactory.getInstance("Ed25519").generatePrivate(PKCS8EncodedKeySpec(der))
  }
  private fun expect(code: WebCapsuleErrorCode, action: () -> Unit) {
    try { action(); junitFail("Expected $code") } catch (error: WebCapsuleException) { assertEquals(code, error.code) }
  }
}
