package com.webcapsule.reactnative.runtime

import java.io.File
import kotlin.io.path.createTempDirectory
import org.junit.Assert.assertEquals
import org.junit.Test

class CapsuleVerifierLimitsTest {
  @Test fun injectedArchiveLimitFailsBeforeParsing() {
    val archive=File.createTempFile("webcapsule-limit-",".capsule")
    try { archive.writeBytes(byteArrayOf(1,2)); val error=runCatching{CapsuleVerifier(CapsuleVerifier.Limits(archiveBytes=1)).verify(archive,createTempDirectory("webcapsule-limit-").toFile(),emptyMap(),"com.example.fixture","1.0.0")}.exceptionOrNull() as WebCapsuleException;assertEquals(WebCapsuleErrorCode.LIMIT_EXCEEDED,error.code) } finally { archive.delete() }
  }
}
