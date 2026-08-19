package com.webcapsule.reactnative.runtime

import com.fasterxml.jackson.databind.ObjectMapper
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class UpdateIndexFixtureParityTest {
  private val root = File(System.getProperty("webcapsule.fixtureRoot"))
  private val publicKey = File(root, "keys/test-only-public.pem").readText()

  @Test fun `all shared update index fixtures match expected top-level result`() {
    val contract = ObjectMapper().readTree(File(root, "expected-results.json"))
    val fixtures = contract["fixtures"].filter { it["kind"].asText() == "signed-update-index" && it["platforms"].any { p -> p.asText() == "android" } }
    assertEquals(14, fixtures.size)
    fixtures.forEach { fixture ->
      val verification = fixture["verification"]
      try {
        UpdateIndexVerifier.verify(File(root, fixture["path"].asText()).readBytes(), verification["expectedCapsuleId"].asText(), verification["expectedChannel"].asText(), mapOf("test-only" to publicKey))
        if (!fixture["accepted"].asBoolean()) fail("${fixture["id"].asText()} should fail")
      } catch (error: WebCapsuleException) {
        if (fixture["accepted"].asBoolean()) throw error
        assertEquals(fixture["id"].asText(), fixture["errorCode"].asText(), error.code.name)
      }
    }
  }
}
