package com.webcapsule.reactnative.runtime

import java.nio.charset.StandardCharsets
import org.erdtman.jcs.JsonCanonicalizer

internal const val MAX_SAFE_INTEGER = 9_007_199_254_740_991L
internal const val MAX_PENDING_ATTEMPTS = 2L

data class ActiveVersion(val version: String, val healthy: Boolean)
data class PreviousVersion(val version: String)
data class PendingVersion(val version: String, val attempts: Long)

data class Registry(
  val schemaVersion: Int,
  val capsuleId: String,
  val generation: Long,
  val active: ActiveVersion,
  val previous: PreviousVersion?,
  val pending: PendingVersion?,
  val highestSeenVersion: String,
  val blockedVersions: List<String>,
)

internal object RegistryCodec {
  private val fields = setOf("schemaVersion", "capsuleId", "generation", "active", "previous", "pending", "highestSeenVersion", "blockedVersions")
  private val activeFields = setOf("version", "healthy")
  private val previousFields = setOf("version")
  private val pendingFields = setOf("version", "attempts")

  fun parse(bytes: ByteArray, expectedCapsuleId: String): Registry {
    if (bytes.isEmpty() || bytes.last() != '\n'.code.toByte() ||
      (bytes.size > 1 && bytes[bytes.lastIndex - 1] == '\n'.code.toByte())) invalid("Registry must end with exactly one LF")
    val root = try { StrictJson.parse(bytes.copyOf(bytes.size - 1)) as? Map<*, *> }
      catch (error: WebCapsuleException) { invalid("Registry JSON is invalid", error) }
      ?: invalid("Registry must be an object")
    exact(root, fields, "Registry")
    val schema = integer(root, "schemaVersion")
    if (schema != 1L) invalid("Unsupported registry schema")
    val activeMap = objectValue(root, "active"); exact(activeMap, activeFields, "active")
    val previous = nullableObject(root, "previous")?.also { exact(it, previousFields, "previous") }?.let { PreviousVersion(string(it, "version")) }
    val pending = nullableObject(root, "pending")?.also { exact(it, pendingFields, "pending") }?.let {
      PendingVersion(string(it, "version"), integer(it, "attempts"))
    }
    val blocked = (root["blockedVersions"] as? List<*>)?.map { it as? String ?: invalid("blockedVersions values must be strings") }
      ?: invalid("blockedVersions must be an array")
    val registry = Registry(1, string(root, "capsuleId"), integer(root, "generation"),
      ActiveVersion(string(activeMap, "version"), activeMap["healthy"] as? Boolean ?: invalid("healthy must be boolean")),
      previous, pending, string(root, "highestSeenVersion"), blocked)
    if (registry.capsuleId != expectedCapsuleId) invalid("Registry filename identity differs")
    validate(registry)
    if (!serialize(registry).contentEquals(bytes)) invalid("Registry is not canonical")
    return registry
  }

  fun serialize(registry: Registry): ByteArray {
    validate(registry)
    val previous = registry.previous?.let { "{\"version\":${quote(it.version)}}" } ?: "null"
    val pending = registry.pending?.let { "{\"attempts\":${it.attempts},\"version\":${quote(it.version)}}" } ?: "null"
    val blocked = registry.blockedVersions.joinToString(",") { quote(it) }
    val json = "{\"active\":{\"healthy\":${registry.active.healthy},\"version\":${quote(registry.active.version)}},\"blockedVersions\":[$blocked],\"capsuleId\":${quote(registry.capsuleId)},\"generation\":${registry.generation},\"highestSeenVersion\":${quote(registry.highestSeenVersion)},\"pending\":$pending,\"previous\":$previous,\"schemaVersion\":1}"
    return (json + "\n").toByteArray(StandardCharsets.UTF_8)
  }

  fun validate(registry: Registry) {
    if (registry.schemaVersion != 1 || registry.generation !in 0..MAX_SAFE_INTEGER) invalid("Registry scalar invariant failed")
    ManifestParser.assertVersion(registry.active.version)
    registry.previous?.let { ManifestParser.assertVersion(it.version) }
    registry.pending?.let {
      ManifestParser.assertVersion(it.version)
      if (it.attempts !in 0..MAX_PENDING_ATTEMPTS) invalid("Pending attempts are invalid")
    }
    ManifestParser.assertVersion(registry.highestSeenVersion)
    registry.blockedVersions.forEach(ManifestParser::assertVersion)
    if (registry.active.healthy) {
      if (registry.pending != null) invalid("Healthy active must not be pending")
    } else if (registry.pending?.version != registry.active.version) {
      invalid("Unhealthy active must be the pending trial")
    }
    if (registry.previous?.version == registry.active.version) invalid("Previous must differ from active")
    val referenced = listOfNotNull(registry.active.version, registry.previous?.version)
    if (referenced.toSet().size != referenced.size) invalid("Referenced versions must differ")
    val stateVersions = referenced + listOfNotNull(registry.pending?.version)
    if (registry.blockedVersions.toSet().size != registry.blockedVersions.size || registry.blockedVersions.any { it in stateVersions }) invalid("Blocked versions are invalid")
    if (registry.blockedVersions.zipWithNext().any { ManifestParser.compareVersions(it.first, it.second) <= 0 }) invalid("Blocked versions are not descending")
    if ((stateVersions + registry.blockedVersions).any { ManifestParser.compareVersions(registry.highestSeenVersion, it) < 0 }) invalid("highestSeenVersion is too low")
  }

  private fun exact(map: Map<*, *>, expected: Set<String>, name: String) {
    if (map.keys.any { it !is String } || map.keys.toSet() != expected) invalid("$name fields differ")
  }
  private fun objectValue(map: Map<*, *>, key: String): Map<*, *> = map[key] as? Map<*, *> ?: invalid("$key must be an object")
  private fun nullableObject(map: Map<*, *>, key: String): Map<*, *>? = map[key]?.let { it as? Map<*, *> ?: invalid("$key must be an object or null") }
  private fun string(map: Map<*, *>, key: String): String = map[key] as? String ?: invalid("$key must be a string")
  private fun integer(map: Map<*, *>, key: String): Long = (map[key] as? Long)?.takeIf { it in 0..MAX_SAFE_INTEGER } ?: invalid("$key must be a non-negative safe integer")
  private fun quote(value: String): String = String(JsonCanonicalizer("[${basicQuote(value)}]").encodedUTF8, StandardCharsets.UTF_8).removePrefix("[").removeSuffix("]")
  private fun basicQuote(value: String): String = buildString { append('"'); value.forEach { c -> when (c) { '"' -> append("\\\""); '\\' -> append("\\\\"); '\b' -> append("\\b"); '\u000c' -> append("\\f"); '\n' -> append("\\n"); '\r' -> append("\\r"); '\t' -> append("\\t"); else -> if (c.code < 0x20) append("\\u%04x".format(c.code)) else append(c) } }; append('"') }
  private fun invalid(message: String, cause: Throwable? = null): Nothing = fail(WebCapsuleErrorCode.REGISTRY_INVALID, message, cause)
}
