package com.webcapsule.reactnative.runtime

import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidResourceFrameworkTest {
  private val context = ApplicationProvider.getApplicationContext<android.content.Context>()
  private val session = SessionDescriptor(
    sessionId = "session",
    capsuleId = "com.example.fixture",
    version = "1.0.0",
    entry = "index.html",
    recordSha256 = "0".repeat(64),
    registryGeneration = 1,
    createdElapsedRealtime = 0,
    files = mapOf("index.html" to SessionFile("index.html", "0".repeat(64), 6, "text/html; charset=utf-8")),
    trialVersion = null,
    trialAttempt = null,
  )
  private val handler = PinnedRequestHandler(StorageLayout(File(context.noBackupFilesDir, "uri-test")), session) { throw it }
  private val prefix = "https://webcapsule.local/com.example.fixture/1.0.0/"

  @Test
  fun canonicalPinnedUriIsAccepted() {
    assertEquals("index.html", handler.validate(Uri.parse(prefix + "index.html?ignored=yes")))
  }

  @Test
  fun malformedAndNonCanonicalUrisAreDeniedUsingOriginalEncodedPath() {
    listOf(
      "https://other.invalid/com.example.fixture/1.0.0/index.html",
      "https://webcapsule.local:443/com.example.fixture/1.0.0/index.html",
      prefix + "index%2ehtml",
      prefix + "index%2Fhtml",
      prefix + "%252e%252e/index.html",
      prefix + "index%ZZhtml",
      prefix + "INDEX.HTML",
    ).forEach { value ->
      val error = assertThrows(WebCapsuleException::class.java) { handler.validate(Uri.parse(value)) }
      assertEquals(WebCapsuleErrorCode.RESOURCE_DENIED, error.code)
    }
  }
}
