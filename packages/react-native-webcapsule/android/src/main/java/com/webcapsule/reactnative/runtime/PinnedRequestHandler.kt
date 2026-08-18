package com.webcapsule.reactnative.runtime

import android.net.Uri
import android.webkit.WebResourceResponse
import androidx.webkit.WebViewAssetLoader
import java.io.FileInputStream
import java.io.InputStream
import java.nio.channels.Channels
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardOpenOption
import java.security.MessageDigest

class PinnedRequestHandler(
  private val layout: StorageLayout,
  private val session: SessionDescriptor,
  private val fatal: (WebCapsuleException) -> Unit,
) : WebViewAssetLoader.PathHandler {
  private val prefix = "/${PercentCodec.encode(session.capsuleId)}/${PercentCodec.encode(session.version)}/"

  fun validate(uri: Uri): String {
    if (uri.scheme != "https" || uri.host != "webcapsule.local" || uri.port != -1 || uri.userInfo != null) denied("Origin differs")
    val encoded = uri.encodedPath ?: denied("Request path is absent")
    if (!encoded.startsWith(prefix)) denied("Session prefix differs")
    val content = encoded.removePrefix(prefix)
    if (content.isEmpty()) denied("Content path is absent")
    val decoded = content.split('/').joinToString("/") { PercentCodec.decodeSegment(it) }
    ManifestParser.assertPathSet(listOf(decoded))
    if (decoded !in session.files) denied("Resource is not declared")
    return decoded
  }

  override fun handle(path: String): WebResourceResponse? {
    val normalized = path.removePrefix("/")
    val expectedPrefix = "${PercentCodec.encode(session.capsuleId)}/${PercentCodec.encode(session.version)}/"
    if (!normalized.startsWith(expectedPrefix)) return null
    val encodedContent = normalized.removePrefix(expectedPrefix)
    val decoded = try { encodedContent.split('/').joinToString("/") { PercentCodec.decodeSegment(it) } }
      catch (_: WebCapsuleException) { return null }
    val metadata = session.files[decoded] ?: return null
    return try { response(metadata) } catch (error: WebCapsuleException) {
      fatal(error)
      errorResponse(500, "Storage invariant violation")
    }
  }

  private fun response(metadata: SessionFile): WebResourceResponse {
    val file = layout.blob(metadata.sha256)
    val path = file.toPath()
    if (Files.isSymbolicLink(path) || !Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) invariant("Blob is not regular")
    val before = try { Files.readAttributes(path, java.nio.file.attribute.BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS) }
      catch (error: Exception) { invariant("Cannot inspect blob", error) }
    if (Files.isWritable(path)) invariant("Published blob is writable")
    val channel = try { FileChannel.open(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS) }
      catch (error: Exception) { invariant("Cannot open blob", error) }
    try {
      if (channel.size() != metadata.size) invariant("Blob size differs")
      val digest = MessageDigest.getInstance("SHA-256")
      val buffer = java.nio.ByteBuffer.allocate(64 * 1024)
      while (channel.read(buffer) >= 0) {
        if (buffer.position() == 0) continue
        buffer.flip(); digest.update(buffer); buffer.clear()
      }
      val observed = digest.digest().joinToString("") { "%02x".format(it) }
      val after = Files.readAttributes(path, java.nio.file.attribute.BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
      if (observed != metadata.sha256 || channel.size() != metadata.size || before.fileKey() != after.fileKey() || before.size() != after.size() || Files.isWritable(path)) invariant("Blob changed")
      channel.position(0)
      val stream = Channels.newInputStream(channel)
      val mediaType = metadata.mediaType.substringBefore(';').trim()
      val encoding = metadata.mediaType.substringAfter("charset=", "").substringBefore(';').trim().ifEmpty { null }
      return WebResourceResponse(mediaType, encoding, 200, "OK", mapOf("Content-Length" to metadata.size.toString()), stream)
    } catch (error: Throwable) {
      channel.close()
      throw error
    }
  }

  private fun errorResponse(status: Int, reason: String) = WebResourceResponse(
    "text/plain", null, status, reason, emptyMap(), InputStream.nullInputStream(),
  )

  private fun denied(message: String): Nothing = fail(WebCapsuleErrorCode.RESOURCE_DENIED, message)
  private fun invariant(message: String, cause: Throwable? = null): Nothing =
    fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, message, cause)
}

object PercentCodec {
  private val hex = "0123456789ABCDEF"
  fun encode(value: String): String = buildString {
    value.toByteArray(Charsets.UTF_8).forEach { byte ->
      val unsigned = byte.toInt() and 0xff
      if ((unsigned in 'A'.code..'Z'.code) || (unsigned in 'a'.code..'z'.code) ||
        (unsigned in '0'.code..'9'.code) || unsigned == '-'.code || unsigned == '.'.code || unsigned == '_'.code || unsigned == '~'.code) append(unsigned.toChar())
      else { append('%'); append(hex[unsigned ushr 4]); append(hex[unsigned and 15]) }
    }
  }

  fun decodeSegment(value: String): String {
    if (value.isEmpty()) fail(WebCapsuleErrorCode.RESOURCE_DENIED, "Empty path segment")
    val output = java.io.ByteArrayOutputStream()
    var index = 0
    while (index < value.length) {
      val character = value[index]
      if (character == '%') {
        if (index + 2 >= value.length) fail(WebCapsuleErrorCode.RESOURCE_DENIED, "Malformed percent escape")
        val hi = value[index + 1].digitToIntOrNull(16); val lo = value[index + 2].digitToIntOrNull(16)
        if (hi == null || lo == null) fail(WebCapsuleErrorCode.RESOURCE_DENIED, "Malformed percent escape")
        val byte = (hi shl 4) or lo
        if (byte == '/'.code || byte == '\\'.code) fail(WebCapsuleErrorCode.RESOURCE_DENIED, "Encoded separator is forbidden")
        output.write(byte); index += 3
      } else {
        if (character.code > 0x7f || character == '\\') fail(WebCapsuleErrorCode.RESOURCE_DENIED, "Path is not canonical encoded UTF-8")
        output.write(character.code); index++
      }
    }
    val bytes = output.toByteArray()
    val decoded = try { Charsets.UTF_8.newDecoder().onMalformedInput(java.nio.charset.CodingErrorAction.REPORT).decode(java.nio.ByteBuffer.wrap(bytes)).toString() }
      catch (error: Exception) { fail(WebCapsuleErrorCode.RESOURCE_DENIED, "Path is not UTF-8", error) }
    if (encode(decoded) != value) fail(WebCapsuleErrorCode.RESOURCE_DENIED, "Path encoding is not canonical")
    return decoded
  }
}
