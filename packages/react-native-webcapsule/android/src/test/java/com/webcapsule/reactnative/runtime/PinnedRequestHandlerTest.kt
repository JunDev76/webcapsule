package com.webcapsule.reactnative.runtime

import android.net.Uri
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.rules.TemporaryFolder
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class PinnedRequestHandlerTest {
  private val temporary = TemporaryFolder.builder().assureDeletion().build().also { it.create() }
  private val session = SessionDescriptor(
    "session", "com.example.한글", "1.0.0+빌드", "dir/index.html", "a".repeat(64), 1, 10,
    mapOf("dir/index.html" to SessionFile("dir/index.html", "b".repeat(64), 1, "text/html; charset=utf-8")),
    null, null,
  )

  @Test fun `encoder uses uppercase canonical UTF-8 escapes`() {
    assertEquals("com.example.%ED%95%9C%EA%B8%80", PercentCodec.encode(session.capsuleId))
    assertEquals("1.0.0%2B%EB%B9%8C%EB%93%9C", PercentCodec.encode(session.version))
  }

  @Test fun `validator accepts exact pinned request and ignores query`() {
    val handler = handler()
    val uri = Uri.parse("https://webcapsule.local/com.example.%ED%95%9C%EA%B8%80/1.0.0%2B%EB%B9%8C%EB%93%9C/dir/index.html?cache=1")
    assertEquals("dir/index.html", handler.validate(uri))
  }

  @Test fun `validator rejects noncanonical and mismatched requests`() {
    val invalid = listOf(
      "http://webcapsule.local/com.example.%ED%95%9C%EA%B8%80/1.0.0%2B%EB%B9%8C%EB%93%9C/dir/index.html",
      "https://user@webcapsule.local/com.example.%ED%95%9C%EA%B8%80/1.0.0%2B%EB%B9%8C%EB%93%9C/dir/index.html",
      "https://webcapsule.local:443/com.example.%ED%95%9C%EA%B8%80/1.0.0%2B%EB%B9%8C%EB%93%9C/dir/index.html",
      "https://webcapsule.local/other/1.0.0/dir/index.html",
      "https://webcapsule.local/com.example.%ED%95%9C%EA%B8%80/1.0.0%2B%EB%B9%8C%EB%93%9C/dir%2Findex.html",
      "https://webcapsule.local/com.example.%ed%95%9c%ea%b8%80/1.0.0%2B%EB%B9%8C%EB%93%9C/dir/index.html",
      "https://webcapsule.local/com.example.%25ED%2595%259C%25EA%25B8%2580/1.0.0%2B%EB%B9%8C%EB%93%9C/dir/index.html",
      "https://webcapsule.local/com.example.%ED%95%9C%EA%B8%80/1.0.0%2B%EB%B9%8C%EB%93%9C/undeclared.js",
    )
    invalid.forEach { value -> expect(WebCapsuleErrorCode.RESOURCE_DENIED) { handler().validate(Uri.parse(value)) } }
  }

  private fun handler() = PinnedRequestHandler(StorageLayout(File(temporary.root, "store")), session) { }
  private fun expect(code: WebCapsuleErrorCode, action: () -> Unit) {
    try { action(); throw AssertionError("Expected $code") }
    catch (error: WebCapsuleException) { assertEquals(code, error.code) }
  }
}
