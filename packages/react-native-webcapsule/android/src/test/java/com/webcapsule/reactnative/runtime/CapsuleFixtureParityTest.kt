package com.webcapsule.reactnative.runtime

import com.fasterxml.jackson.databind.ObjectMapper
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CapsuleFixtureParityTest {
  private val mapper=ObjectMapper()
  private val root=File(System.getProperty("webcapsule.fixtureRoot") ?: error("webcapsule.fixtureRoot missing")).canonicalFile
  @Test fun sharedCapsulesHaveExactResults() {
    val contract=mapper.readTree(File(root,"expected-results.json"))
    contract["fixtures"].filter{it["kind"].asText()=="capsule"&&it["platforms"].any{p->p.asText()=="android"}}.forEach { fixture ->
      val verification=fixture["verification"]
      val keyId=verification["trustedKeyId"]?.asText() ?: "test-only"
      val publicKey=File(root,verification["trustedPublicKey"].asText()).readText()
      val staging=Files.createTempDirectory("webcapsule-fixture-").toFile()
      try {
        val result=runCatching { CapsuleVerifier().verify(File(root,fixture["path"].asText()),staging,mapOf(keyId to publicKey),verification["expectedCapsuleId"].asText(),verification["runtimeVersion"].asText()) }
        if(fixture["accepted"].asBoolean()) { assertTrue("${fixture["id"]}: ${result.exceptionOrNull()}",result.isSuccess);result.getOrNull()?.operationDirectory?.deleteRecursively() }
        else assertEquals(fixture["id"].asText(),fixture["errorCode"].asText(),(result.exceptionOrNull() as? WebCapsuleException)?.code?.name)
      } finally { staging.deleteRecursively() }
    }
  }
}
