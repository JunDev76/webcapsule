package com.webcapsule.reactnative.runtime

import java.net.URI
import java.nio.charset.StandardCharsets
import java.util.Base64

data class UpdateRelease(
  val version: String,
  val url: URI,
  val sha256: String,
  val size: Long,
  val minimumRuntimeVersion: String,
)

data class VerifiedUpdateIndex(
  val capsuleId: String,
  val channel: String,
  val keyId: String,
  val releases: List<UpdateRelease>,
)

object UpdateIndexVerifier {
  private val capsuleIdPattern = Regex("^[a-z0-9]+(?:[.-][a-z0-9]+)+$")
  private val channelPattern = Regex("^[a-z0-9][a-z0-9._-]{0,63}$")
  private val keyIdPattern = Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
  private val hashPattern = Regex("^[0-9a-f]{64}$")
  private val signaturePattern = Regex("^[A-Za-z0-9+/]{86}==$")
  private val rootFields = setOf("schemaVersion", "capsuleId", "channel", "releases", "keyId", "signature")
  private val releaseFields = setOf("version", "url", "sha256", "size", "minimumRuntimeVersion")

  fun verify(
    bytes: ByteArray,
    expectedCapsuleId: String,
    expectedChannel: String,
    publicKeys: Map<String, String>,
  ): VerifiedUpdateIndex {
    if (bytes.isEmpty() || bytes.size > 1024 * 1024) fail(WebCapsuleErrorCode.LIMIT_EXCEEDED, "Update index size is invalid")
    val root = (StrictJson.parse(bytes) as? Map<*, *>) ?: invalid("Update index must be an object")
    exact(root, rootFields, "Update index")
    if (integer(root, "schemaVersion") != 1L) invalid("Unsupported update index schema")
    val capsuleId = string(root, "capsuleId")
    val channel = string(root, "channel")
    val keyId = string(root, "keyId")
    if (!capsuleIdPattern.matches(capsuleId)) fail(WebCapsuleErrorCode.INVALID_CAPSULE_ID, "Invalid capsule ID")
    if (!channelPattern.matches(channel)) invalid("Invalid channel")
    if (!keyIdPattern.matches(keyId)) fail(WebCapsuleErrorCode.INVALID_KEY_ID, "Invalid key ID")
    if (capsuleId != expectedCapsuleId || channel != expectedChannel) {
      fail(WebCapsuleErrorCode.INVALID_UPDATE_INDEX, "Update index identity differs")
    }
    val releases = (root["releases"] as? List<*>)?.map { parseRelease(it) } ?: invalid("releases must be an array")
    if (releases.isEmpty()) invalid("At least one release is required")
    if (releases.zipWithNext().any { ManifestParser.compareVersions(it.first.version, it.second.version) <= 0 }) {
      fail(WebCapsuleErrorCode.INVALID_ORDER, "Releases must have unique descending SemVer precedence")
    }
    val encoded = string(root, "signature")
    if (!signaturePattern.matches(encoded)) fail(WebCapsuleErrorCode.INVALID_SIGNATURE, "Invalid update index signature encoding")
    val signature = try { Base64.getDecoder().decode(encoded) } catch (error: Exception) {
      fail(WebCapsuleErrorCode.INVALID_SIGNATURE, "Invalid update index signature", error)
    }
    if (signature.size != 64) fail(WebCapsuleErrorCode.INVALID_SIGNATURE, "Invalid update index signature length")
    val unsigned = LinkedHashMap<Any?, Any?>(root).also { it.remove("signature") }
    val canonical = try {
      StrictJson.canonicalize(json(unsigned).toByteArray(StandardCharsets.UTF_8))
    } catch (error: Exception) {
      invalid("Cannot canonicalize update index", error)
    }
    val pem = publicKeys[keyId] ?: fail(WebCapsuleErrorCode.KEY_ID_MISMATCH, "No exact trusted update key ID")
    SignatureVerifier.verifyUpdateIndex(canonical, signature, pem)
    return VerifiedUpdateIndex(capsuleId, channel, keyId, releases)
  }

  fun select(index: VerifiedUpdateIndex, runtimeVersion: String, highestSeenVersion: String, blockedVersions: Set<String>): UpdateRelease? {
    ManifestParser.assertVersion(runtimeVersion)
    ManifestParser.assertVersion(highestSeenVersion)
    return index.releases.firstOrNull {
      ManifestParser.compareVersions(it.minimumRuntimeVersion, runtimeVersion) <= 0 &&
        ManifestParser.compareVersions(it.version, highestSeenVersion) > 0 && it.version !in blockedVersions
    }
  }

  private fun parseRelease(value: Any?): UpdateRelease {
    val map = value as? Map<*, *> ?: invalid("Release must be an object")
    exact(map, releaseFields, "Release")
    val version = string(map, "version"); ManifestParser.assertVersion(version)
    val minimum = string(map, "minimumRuntimeVersion"); ManifestParser.assertVersion(minimum)
    val digest = string(map, "sha256")
    if (!hashPattern.matches(digest)) fail(WebCapsuleErrorCode.INVALID_HASH, "Invalid release SHA-256")
    val size = integer(map, "size")
    if (size > 100L * 1024 * 1024) fail(WebCapsuleErrorCode.LIMIT_EXCEEDED, "Release size exceeds capsule limit")
    val uri = strictHttps(string(map, "url"))
    return UpdateRelease(version, uri, digest, size, minimum)
  }

  fun strictHttps(value: String): URI {
    val uri = try { URI(value) } catch (error: Exception) { fail(WebCapsuleErrorCode.INVALID_URL, "Invalid HTTPS URL", error) }
    if (!uri.isAbsolute || uri.scheme != "https" || uri.host == null || uri.rawAuthority == null ||
      uri.userInfo != null || uri.rawFragment != null || uri.port != -1
    ) {
      fail(WebCapsuleErrorCode.INVALID_URL, "URL must be absolute HTTPS without userinfo, fragment, or explicit port")
    }
    return uri
  }

  private fun exact(map: Map<*, *>, fields: Set<String>, label: String) { if (map.keys.toSet() != fields) invalid("$label fields differ") }
  private fun string(map: Map<*, *>, key: String) = map[key] as? String ?: invalid("$key must be a string")
  private fun integer(map: Map<*, *>, key: String) = (map[key] as? Long)?.takeIf { it >= 0 } ?: invalid("$key must be a non-negative integer")
  private fun invalid(message: String, cause: Throwable? = null): Nothing = fail(WebCapsuleErrorCode.INVALID_UPDATE_INDEX, message, cause)

  private fun json(value: Any?): String = when (value) {
    null -> "null"
    is String -> quote(value)
    is Long, is Int -> value.toString()
    is Boolean -> value.toString()
    is List<*> -> value.joinToString(",", "[", "]") { json(it) }
    is Map<*, *> -> value.entries.joinToString(",", "{", "}") { json(it.key as String) + ":" + json(it.value) }
    else -> invalid("Unsupported update index value")
  }

  private fun quote(value: String) = buildString {
    append('"')
    value.forEach { character ->
      when (character) {
        '"' -> append("\\\"")
        '\\' -> append("\\\\")
        '\b' -> append("\\b")
        '\u000c' -> append("\\f")
        '\n' -> append("\\n")
        '\r' -> append("\\r")
        '\t' -> append("\\t")
        else -> if (character.code < 0x20) append("\\u%04x".format(character.code)) else append(character)
      }
    }
    append('"')
  }
}
