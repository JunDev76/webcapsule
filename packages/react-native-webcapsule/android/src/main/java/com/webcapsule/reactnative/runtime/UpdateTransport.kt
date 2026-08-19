package com.webcapsule.reactnative.runtime

import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URI
import java.net.URL
import java.nio.file.Files
import java.nio.file.LinkOption
import java.security.MessageDigest
import java.util.UUID
import javax.net.ssl.HttpsURLConnection

private const val INDEX_LIMIT = 1024L * 1024
private const val CAPSULE_LIMIT = 100L * 1024 * 1024

data class DownloadedCapsule(val file: File, val operationDirectory: File)

interface UpdateTransport {
  fun fetchIndex(uri: URI): ByteArray
  fun fetchCapsule(release: UpdateRelease, updateRoot: File): DownloadedCapsule
}

internal interface UpdateHttpConnection {
  val status: Int
  val input: InputStream
  fun headerValues(name: String): List<String>
  fun disconnect()
}

internal fun interface UpdateConnectionFactory {
  fun open(uri: URI): UpdateHttpConnection
}

private class PlatformUpdateHttpConnection(private val connection: HttpsURLConnection) : UpdateHttpConnection {
  override val status: Int get() = connection.responseCode
  override val input: InputStream get() = connection.inputStream
  override fun headerValues(name: String): List<String> = connection.headerFields.entries
    .filter { it.key?.equals(name, ignoreCase = true) == true }
    .flatMap { it.value ?: emptyList() }
  override fun disconnect() = connection.disconnect()
}

class HttpsUpdateTransport internal constructor(
  private val connections: UpdateConnectionFactory = UpdateConnectionFactory { uri ->
    val connection = URL(uri.toString()).openConnection() as? HttpsURLConnection
      ?: fail(WebCapsuleErrorCode.NETWORK_FAILED, "URL did not create an HTTPS connection")
    connection.apply {
      instanceFollowRedirects = false
      connectTimeout = 10_000
      readTimeout = 30_000
      useCaches = false
      defaultUseCaches = false
      requestMethod = "GET"
      setRequestProperty("Accept-Encoding", "identity")
    }
    PlatformUpdateHttpConnection(connection)
  },
) : UpdateTransport {
  override fun fetchIndex(uri: URI): ByteArray {
    UpdateIndexVerifier.strictHttps(uri.toString())
    val connection = open(uri)
    try {
      requireSuccess(connection)
      val declared = contentLength(connection)
      if (declared != null && declared > INDEX_LIMIT) fail(WebCapsuleErrorCode.LIMIT_EXCEEDED, "Update index exceeds 1 MiB")
      val bytes = connection.input.use { input ->
        val output = java.io.ByteArrayOutputStream()
        copyBounded(input, INDEX_LIMIT) { bytes, count -> output.write(bytes, 0, count) }.also { total ->
          if (declared != null && total != declared) fail(WebCapsuleErrorCode.CONTENT_LENGTH_MISMATCH, "Update index Content-Length differs")
        }
        output.toByteArray()
      }
      StrictJson.parse(bytes)
      return bytes
    } catch (error: Throwable) {
      mapNetworkError("Update index request failed", error)
    } finally {
      connection.disconnect()
    }
  }

  override fun fetchCapsule(release: UpdateRelease, updateRoot: File): DownloadedCapsule {
    prepareSafeRoot(updateRoot)
    val operation = File(updateRoot, UUID.randomUUID().toString())
    if (!operation.mkdir()) fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, "Cannot create update temporary directory")
    val target = File(operation, "download.capsule")
    var connection: UpdateHttpConnection? = null
    try {
      connection = open(release.url)
      requireSuccess(connection)
      val declared = contentLength(connection)
      if (declared != null && declared != release.size) fail(WebCapsuleErrorCode.CONTENT_LENGTH_MISMATCH, "Capsule Content-Length differs")
      val digest = MessageDigest.getInstance("SHA-256")
      val total = connection.input.use { input ->
        FileOutputStream(target).use { output ->
          copyBounded(input, minOf(release.size, CAPSULE_LIMIT)) { bytes, count ->
            digest.update(bytes, 0, count)
            output.write(bytes, 0, count)
          }.also { output.fd.sync() }
        }
      }
      if (total != release.size) fail(WebCapsuleErrorCode.CONTENT_LENGTH_MISMATCH, "Capsule byte size differs")
      val hash = digest.digest().joinToString("") { "%02x".format(it) }
      if (hash != release.sha256) fail(WebCapsuleErrorCode.HASH_MISMATCH, "Downloaded capsule SHA-256 differs")
      return DownloadedCapsule(target, operation)
    } catch (error: Throwable) {
      operation.deleteRecursively()
      mapNetworkError("Capsule request failed", error)
    } finally {
      connection?.disconnect()
    }
  }

  private fun open(uri: URI): UpdateHttpConnection = try {
    connections.open(uri)
  } catch (error: Throwable) {
    mapNetworkError("Cannot open HTTPS connection", error)
  }

  private fun requireSuccess(connection: UpdateHttpConnection) {
    val status = try { connection.status } catch (error: Throwable) { mapNetworkError("HTTP request failed", error) }
    if (status != HttpURLConnection.HTTP_OK) fail(WebCapsuleErrorCode.HTTP_STATUS_INVALID, "HTTP status must be 200")
  }

  private fun contentLength(connection: UpdateHttpConnection): Long? {
    val values = connection.headerValues("Content-Length")
    if (values.isEmpty()) return null
    if (values.size != 1 || values.single().contains(',')) fail(WebCapsuleErrorCode.CONTENT_LENGTH_MISMATCH, "Multiple Content-Length values are forbidden")
    return values.single().trim().toLongOrNull()?.takeIf { it >= 0 }
      ?: fail(WebCapsuleErrorCode.CONTENT_LENGTH_MISMATCH, "Invalid Content-Length")
  }

  private fun copyBounded(input: InputStream, limit: Long, consume: (ByteArray, Int) -> Unit): Long {
    val buffer = ByteArray(64 * 1024)
    var total = 0L
    while (true) {
      val count = input.read(buffer)
      if (count < 0) return total
      total += count
      if (total > limit) fail(WebCapsuleErrorCode.LIMIT_EXCEEDED, "Response exceeds its byte limit")
      consume(buffer, count)
    }
  }

  private fun prepareSafeRoot(root: File) {
    if (root.exists()) {
      if (Files.isSymbolicLink(root.toPath()) || !Files.isDirectory(root.toPath(), LinkOption.NOFOLLOW_LINKS)) {
        fail(WebCapsuleErrorCode.UNSAFE_STORAGE_LAYOUT, "Update temporary root is not a real directory")
      }
    } else if (!root.mkdirs()) {
      fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, "Cannot create update temporary root")
    }
  }

  private fun mapNetworkError(message: String, error: Throwable): Nothing {
    if (error is WebCapsuleException) throw error
    if (error is SocketTimeoutException) fail(WebCapsuleErrorCode.NETWORK_TIMEOUT, message, error)
    fail(WebCapsuleErrorCode.NETWORK_FAILED, message, error)
  }
}
