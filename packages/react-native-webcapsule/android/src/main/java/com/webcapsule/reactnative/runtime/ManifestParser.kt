package com.webcapsule.reactnative.runtime

import java.net.URI
import java.text.Normalizer
import java.time.Instant
import java.time.format.DateTimeParseException

internal object ManifestParser {
  private val capsuleId = Regex("^[a-z0-9]+(?:[.-][a-z0-9]+)+$")
  private val keyId = Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
  private val hash = Regex("^[0-9a-f]{64}$")
  private val mediaType = Regex("^[A-Za-z0-9!#\$&^_.+-]+/[A-Za-z0-9!#\$&^_.+-]+$")
  private val semver = Regex("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\\+([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?$")
  private val timestamp = Regex("^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})Z$")

  fun parse(bytes: ByteArray): CapsuleManifest {
    val root = StrictJson.parse(bytes).obj("manifest")
    root.exact("formatVersion", "capsuleId", "version", "entry", "createdAt", "minimumRuntimeVersion", "keyId", "files", "policy")
    val format = root.int("formatVersion")
    if (format != 1) fail(WebCapsuleErrorCode.UNSUPPORTED_FORMAT_VERSION, "Unsupported format version")
    val id = root.string("capsuleId"); if (id.length > 255 || !capsuleId.matches(id)) fail(WebCapsuleErrorCode.INVALID_CAPSULE_ID, "Invalid capsule ID")
    val version = root.string("version"); assertVersion(version)
    val created = root.string("createdAt"); assertTimestamp(created)
    val minimum = root.string("minimumRuntimeVersion"); assertVersion(minimum)
    val kid = root.string("keyId"); if (!keyId.matches(kid)) fail(WebCapsuleErrorCode.INVALID_KEY_ID, "Invalid key ID")
    val files = root.array("files").map { value ->
      val file = value.obj("file"); file.exact("path", "sha256", "size", "mediaType")
      val path = file.string("path"); assertSafePath(path)
      val digest = file.string("sha256"); if (!hash.matches(digest)) fail(WebCapsuleErrorCode.INVALID_HASH, "Invalid SHA-256")
      val size = file.long("size"); if (size < 0 || size > 50L * 1024 * 1024) fail(WebCapsuleErrorCode.LIMIT_EXCEEDED, "Invalid file size")
      val type = file.string("mediaType"); if (!mediaType.matches(type)) fail(WebCapsuleErrorCode.INVALID_MEDIA_TYPE, "Invalid media type")
      CapsuleFileEntry(path, digest, size, type)
    }
    if (files.size > 10_000) fail(WebCapsuleErrorCode.LIMIT_EXCEEDED, "File count limit exceeded")
    assertPathSet(files.map { it.path })
    val sorted = files.map { it.path.toByteArray() }.zipWithNext().all { compareBytes(it.first, it.second) < 0 }
    if (!sorted && files.size > 1) fail(WebCapsuleErrorCode.INVALID_ORDER, "Files are not byte sorted")
    val entry = root.string("entry"); assertSafePath(entry)
    if (files.none { it.path == entry }) fail(WebCapsuleErrorCode.INVALID_MANIFEST, "Entry is absent")
    val policy = parsePolicy(root["policy"])
    return CapsuleManifest(format, id, version, entry, created, minimum, kid, files, policy)
  }

  private fun parsePolicy(value: Any?): CapsulePolicy {
    val root = value.obj("policy"); root.exact("network", "navigation", "bridgeCapabilities")
    val network = root["network"].obj("network")
    val mode = network.string("mode")
    val origins = when (mode) {
      "deny" -> { network.exact("mode"); null }
      "allowlist" -> { network.exact("mode", "origins"); network.array("origins").map { origin(it.stringValue()).also { } }.map { it as String } }
      else -> fail(WebCapsuleErrorCode.INVALID_POLICY, "Invalid network mode")
    }
    if (origins != null && origins.size != origins.toSet().size) fail(WebCapsuleErrorCode.INVALID_POLICY, "Duplicate origin")
    val navigation = root["navigation"].obj("navigation"); navigation.exact("externalOrigins")
    val external = navigation.array("externalOrigins").map { origin(it.stringValue()) }
    if (external.size != external.toSet().size) fail(WebCapsuleErrorCode.INVALID_POLICY, "Duplicate origin")
    val capabilities = root.array("bridgeCapabilities").map { it.stringValue() }
    if (capabilities.size != capabilities.toSet().size) fail(WebCapsuleErrorCode.INVALID_POLICY, "Duplicate capability")
    return CapsulePolicy(NetworkPolicy(mode, origins), NavigationPolicy(external), capabilities)
  }

  private fun origin(value: String): String {
    val uri = try { URI(value) } catch (_: Exception) { fail(WebCapsuleErrorCode.INVALID_POLICY, "Invalid origin") }
    if (uri.scheme != "https" || uri.rawAuthority == null || uri.userInfo != null || uri.port != -1 || uri.rawPath != "" || uri.rawQuery != null || uri.rawFragment != null || uri.host == null || value.endsWith("/"))
      fail(WebCapsuleErrorCode.INVALID_POLICY, "Invalid HTTPS origin")
    return value
  }

  fun assertVersion(value: String) { if (!semver.matches(value)) fail(WebCapsuleErrorCode.INVALID_VERSION, "Invalid SemVer") }
  fun compareVersions(a: String, b: String): Int {
    assertVersion(a); assertVersion(b)
    fun core(v: String) = v.substringBefore('+').substringBefore('-').split('.').map { java.math.BigInteger(it) }
    val ac=core(a); val bc=core(b); for(i in 0..2) ac[i].compareTo(bc[i]).let { if(it!=0)return it }
    val ap=a.substringBefore('+').substringAfter('-', ""); val bp=b.substringBefore('+').substringAfter('-', "")
    if(ap.isEmpty() || bp.isEmpty()) return if(ap.isEmpty() && bp.isEmpty()) 0 else if(ap.isEmpty()) 1 else -1
    val aa=ap.split('.'); val bb=bp.split('.'); for(i in 0 until minOf(aa.size,bb.size)) { val x=aa[i]; val y=bb[i]; val c=if(x.all(Char::isDigit)&&y.all(Char::isDigit)) java.math.BigInteger(x).compareTo(java.math.BigInteger(y)) else if(x.all(Char::isDigit)) -1 else if(y.all(Char::isDigit)) 1 else x.compareTo(y); if(c!=0)return c }; return aa.size.compareTo(bb.size)
  }
  private fun assertTimestamp(value: String) { val match=timestamp.matchEntire(value) ?: fail(WebCapsuleErrorCode.INVALID_TIMESTAMP,"Invalid timestamp"); if(match.groupValues[6].toInt()%2!=0) fail(WebCapsuleErrorCode.INVALID_TIMESTAMP,"Odd timestamp second"); try { Instant.parse(value) } catch(_:DateTimeParseException){ fail(WebCapsuleErrorCode.INVALID_TIMESTAMP,"Invalid timestamp") } }
  fun assertSafePath(value:String) { if(value.isEmpty()||value.startsWith('/')||value.endsWith('/')||value.contains('\\')||value.any{it.code<=31||it.code==127}||Regex("%(?:2f|5c)",RegexOption.IGNORE_CASE).containsMatchIn(value)||Normalizer.normalize(value,Normalizer.Form.NFC)!=value||value.split('/').any{it.isEmpty()||it=="."||it==".."}) fail(WebCapsuleErrorCode.INVALID_PATH,"Unsafe path") }
  fun assertPathSet(paths:List<String>){ val exact=mutableSetOf<String>(); val folded=mutableMapOf<String,String>(); for(path in paths){if(!exact.add(path))fail(WebCapsuleErrorCode.DUPLICATE_PATH,"Duplicate path"); val fold=path.map{if(it in 'A'..'Z')it.lowercaseChar()else it}.joinToString(""); val old=folded.put(fold,path); if(old!=null&&old!=path)fail(WebCapsuleErrorCode.CASE_COLLISION,"Case collision")}}
  private fun compareBytes(a:ByteArray,b:ByteArray):Int { for(i in 0 until minOf(a.size,b.size)){val c=(a[i].toInt()and 255)-(b[i].toInt()and 255);if(c!=0)return c};return a.size-b.size }
}

private fun Any?.obj(label:String):Map<String,Any?> = this as? Map<String,Any?> ?: fail(WebCapsuleErrorCode.INVALID_MANIFEST,"$label must be object")
private fun Map<String,Any?>.exact(vararg keys:String){if(this.keys!=keys.toSet())fail(WebCapsuleErrorCode.INVALID_MANIFEST,"Object fields differ")}
private fun Map<String,Any?>.string(key:String)=this[key].stringValue()
private fun Any?.stringValue()=this as? String ?: fail(WebCapsuleErrorCode.INVALID_MANIFEST,"Expected string")
private fun Map<String,Any?>.long(key:String)=this[key] as? Long ?: fail(WebCapsuleErrorCode.INVALID_MANIFEST,"Expected integer")
private fun Map<String,Any?>.int(key:String):Int {val v=long(key);if(v !in Int.MIN_VALUE..Int.MAX_VALUE)fail(WebCapsuleErrorCode.INVALID_MANIFEST,"Expected integer");return v.toInt()}
private fun Map<String,Any?>.array(key:String)=this[key] as? List<Any?> ?: fail(WebCapsuleErrorCode.INVALID_MANIFEST,"Expected array")
