package com.webcapsule.reactnative.runtime

import java.nio.charset.StandardCharsets
import org.erdtman.jcs.JsonCanonicalizer

data class VersionRecord(
  val schemaVersion: Int,
  val capsuleId: String,
  val version: String,
  val keyId: String,
  val createdAt: String,
  val entry: String,
  val manifestSha256: String,
  val files: List<CapsuleFileEntry>,
)

internal object VersionRecordCodec {
  private val topFields = setOf("schemaVersion", "capsuleId", "version", "keyId", "createdAt", "entry", "manifestSha256", "files")
  private val fileFields = setOf("path", "sha256", "size", "mediaType")

  fun fromVerified(capsule: VerifiedCapsule): VersionRecord = VersionRecord(
    schemaVersion = 1,
    capsuleId = capsule.manifest.capsuleId,
    version = capsule.manifest.version,
    keyId = capsule.manifest.keyId,
    createdAt = capsule.manifest.createdAt,
    entry = capsule.manifest.entry,
    manifestSha256 = capsule.manifestSha256,
    files = capsule.manifest.files,
  )

  fun serialize(record: VersionRecord): ByteArray {
    validate(record)
    val files = record.files.joinToString(",") { file ->
      "{\"mediaType\":${quote(file.mediaType)},\"path\":${quote(file.path)},\"sha256\":${quote(file.sha256)},\"size\":${file.size}}"
    }
    val json = "{\"capsuleId\":${quote(record.capsuleId)},\"createdAt\":${quote(record.createdAt)},\"entry\":${quote(record.entry)},\"files\":[$files],\"keyId\":${quote(record.keyId)},\"manifestSha256\":${quote(record.manifestSha256)},\"schemaVersion\":1,\"version\":${quote(record.version)}}"
    return (json + "\n").toByteArray(StandardCharsets.UTF_8)
  }

  fun parse(bytes: ByteArray): VersionRecord {
    if (bytes.isEmpty() || bytes.last() != '\n'.code.toByte() ||
      (bytes.size > 1 && bytes[bytes.lastIndex - 1] == '\n'.code.toByte())) {
      invalid("Version record must end with exactly one LF")
    }
    val json = bytes.copyOf(bytes.size - 1)
    val root = StrictJson.parse(json) as? Map<*, *> ?: invalid("Version record must be an object")
    if (root.keys.any { it !is String } || root.keys.toSet() != topFields) invalid("Version record fields differ")
    val filesValue = root["files"] as? List<*> ?: invalid("files must be an array")
    val files = filesValue.map { value ->
      val file = value as? Map<*, *> ?: invalid("file must be an object")
      if (file.keys.any { it !is String } || file.keys.toSet() != fileFields) invalid("File fields differ")
      CapsuleFileEntry(string(file, "path"), string(file, "sha256"), long(file, "size"), string(file, "mediaType"))
    }
    val schema = long(root, "schemaVersion")
    if (schema != 1L) invalid("Unsupported version record schema")
    val record = VersionRecord(1, string(root, "capsuleId"), string(root, "version"), string(root, "keyId"), string(root, "createdAt"), string(root, "entry"), string(root, "manifestSha256"), files)
    validate(record)
    if (!serialize(record).contentEquals(bytes)) invalid("Version record is not canonical")
    return record
  }

  fun validate(record: VersionRecord) {
    if (record.schemaVersion != 1) invalid("Unsupported version record schema")
    val synthetic = "{\"formatVersion\":1,\"capsuleId\":${quote(record.capsuleId)},\"version\":${quote(record.version)},\"entry\":${quote(record.entry)},\"createdAt\":${quote(record.createdAt)},\"minimumRuntimeVersion\":\"0.0.0\",\"keyId\":${quote(record.keyId)},\"files\":[${record.files.joinToString(",") { "{\"path\":${quote(it.path)},\"sha256\":${quote(it.sha256)},\"size\":${it.size},\"mediaType\":${quote(it.mediaType)}}" }}],\"policy\":{\"network\":{\"mode\":\"deny\"},\"navigation\":{\"externalOrigins\":[]},\"bridgeCapabilities\":[]}}"
    try {
      ManifestParser.parse(synthetic.toByteArray(StandardCharsets.UTF_8))
    } catch (error: WebCapsuleException) {
      invalid("Version record semantics are invalid", error)
    }
    StorageLayout.requireHash(record.manifestSha256)
  }

  private fun quote(value: String): String = String(JsonCanonicalizer("[${basicQuote(value)}]").encodedUTF8, StandardCharsets.UTF_8).removePrefix("[").removeSuffix("]")
  private fun basicQuote(value: String): String = buildString {
    append('"')
    value.forEach { character -> when (character) {
      '"' -> append("\\\""); '\\' -> append("\\\\"); '\b' -> append("\\b"); '\u000c' -> append("\\f"); '\n' -> append("\\n"); '\r' -> append("\\r"); '\t' -> append("\\t")
      else -> if (character.code < 0x20) append("\\u%04x".format(character.code)) else append(character)
    } }
    append('"')
  }
  private fun string(map: Map<*, *>, key: String): String = map[key] as? String ?: invalid("$key must be a string")
  private fun long(map: Map<*, *>, key: String): Long = map[key] as? Long ?: invalid("$key must be an integer")
  private fun invalid(message: String, cause: Throwable? = null): Nothing = fail(WebCapsuleErrorCode.VERSION_RECORD_INVALID, message, cause)
}
