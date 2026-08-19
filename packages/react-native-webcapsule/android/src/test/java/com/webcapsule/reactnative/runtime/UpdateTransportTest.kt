package com.webcapsule.reactnative.runtime

import java.io.ByteArrayInputStream
import java.io.File
import java.net.SocketTimeoutException
import java.net.URI
import java.nio.file.Files
import java.security.MessageDigest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.fail as junitFail
import org.junit.Test

class UpdateTransportTest {
  @Test fun `index accepts exact boundary and disconnects`() {
    val body = ByteArray(1024 * 1024) { ' '.code.toByte() }.also { it[0] = '{'.code.toByte(); it[it.lastIndex] = '}'.code.toByte() }
    val connection = FakeConnection(body, headers = listOf(body.size.toString()))
    val transport = transport(connection)
    assertArrayEquals(body, transport.fetchIndex(URI("https://example.com/index.json")))
    assertEquals(1, connection.disconnects)
  }

  @Test fun `index rejects boundary plus one and length mismatch`() {
    expect(WebCapsuleErrorCode.LIMIT_EXCEEDED) { transport(FakeConnection(ByteArray(1024 * 1024 + 1))).fetchIndex(URI("https://example.com/i")) }
    expect(WebCapsuleErrorCode.CONTENT_LENGTH_MISMATCH) { transport(FakeConnection("{}".toByteArray(), headers = listOf("3"))).fetchIndex(URI("https://example.com/i")) }
  }

  @Test fun `rejects status duplicate negative and malformed content length`() {
    expect(WebCapsuleErrorCode.HTTP_STATUS_INVALID) { transport(FakeConnection(byteArrayOf(), status = 302)).fetchIndex(URI("https://example.com/i")) }
    listOf(listOf("1", "1"), listOf("-1"), listOf("x"), listOf("1, 1")).forEach { values ->
      expect(WebCapsuleErrorCode.CONTENT_LENGTH_MISMATCH) { transport(FakeConnection("{}".toByteArray(), headers = values)).fetchIndex(URI("https://example.com/i")) }
    }
  }

  @Test fun `maps timeout separately from IO`() {
    val timeout = HttpsUpdateTransport(UpdateConnectionFactory { throw SocketTimeoutException("timeout") })
    expect(WebCapsuleErrorCode.NETWORK_TIMEOUT) { timeout.fetchIndex(URI("https://example.com/i")) }
    val io = HttpsUpdateTransport(UpdateConnectionFactory { throw java.io.IOException("io") })
    expect(WebCapsuleErrorCode.NETWORK_FAILED) { io.fetchIndex(URI("https://example.com/i")) }
  }

  @Test fun `capsule verifies bytes and hash and cleans failures`() {
    val root = Files.createTempDirectory("transport-test").toFile()
    val body = "capsule".toByteArray()
    val release = release(body)
    val downloaded = transport(FakeConnection(body, headers = listOf(body.size.toString()))).fetchCapsule(release, root)
    assertArrayEquals(body, downloaded.file.readBytes())
    downloaded.operationDirectory.deleteRecursively()
    val bad = release.copy(sha256 = "0".repeat(64))
    expect(WebCapsuleErrorCode.HASH_MISMATCH) { transport(FakeConnection(body)).fetchCapsule(bad, root) }
    assertFalse(root.listFiles()!!.any())
    root.deleteRecursively()
  }

  @Test fun `capsule rejects descriptor length and unsafe temporary root`() {
    val root = Files.createTempDirectory("transport-test").toFile()
    val body = "capsule".toByteArray()
    expect(WebCapsuleErrorCode.CONTENT_LENGTH_MISMATCH) {
      transport(FakeConnection(body, headers = listOf("1"))).fetchCapsule(release(body), root)
    }
    assertFalse(root.listFiles()!!.any())
    val target = Files.createTempDirectory("transport-target")
    val link = File(target.parent.toFile(), "transport-link-${System.nanoTime()}")
    Files.createSymbolicLink(link.toPath(), target)
    expect(WebCapsuleErrorCode.UNSAFE_STORAGE_LAYOUT) { transport(FakeConnection(body)).fetchCapsule(release(body), link) }
    link.delete(); target.toFile().deleteRecursively(); root.deleteRecursively()
  }

  private fun transport(connection: FakeConnection) = HttpsUpdateTransport(UpdateConnectionFactory { connection })
  private fun release(bytes: ByteArray) = UpdateRelease("2.0.0", URI("https://example.com/v2.capsule"), MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }, bytes.size.toLong(), "1.0.0")
  private fun expect(code: WebCapsuleErrorCode, action: () -> Unit) {
    try { action(); junitFail("Expected $code") } catch (error: WebCapsuleException) { assertEquals(code, error.code) }
  }

  private class FakeConnection(
    private val body: ByteArray,
    override val status: Int = 200,
    private val headers: List<String> = emptyList(),
  ) : UpdateHttpConnection {
    var disconnects = 0
    override val input = ByteArrayInputStream(body)
    override fun headerValues(name: String) = if (name.equals("Content-Length", true)) headers else emptyList()
    override fun disconnect() { disconnects++ }
  }
}
