package com.webcapsule.reactnative.runtime

import java.io.File
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneOffset
import java.util.Base64
import java.util.UUID

class CapsuleVerifier(private val limits:Limits=Limits()) {
  data class Limits(val archiveBytes:Long=100L*1024*1024,val expandedBytes:Long=250L*1024*1024,val fileBytes:Long=50L*1024*1024,val fileCount:Int=10_000,val manifestBytes:Long=5L*1024*1024)
  fun verify(archive:File,stagingRoot:File,publicKeys:Map<String,String>,expectedCapsuleId:String,runtimeVersion:String):VerifiedCapsule {
    ManifestParser.assertVersion(runtimeVersion)
    val operation=File(stagingRoot,UUID.randomUUID().toString());if(!operation.mkdirs())fail(WebCapsuleErrorCode.STORAGE_IO_FAILED,"Cannot create operation staging")
    try { StrictZipReader(archive,limits.archiveBytes).use { zip ->
      val entries=zip.entries;if(entries.size<2||entries.size>limits.fileCount+2)fail(WebCapsuleErrorCode.LIMIT_EXCEEDED,"Entry count invalid")
      if(entries[0].name!="capsule.json"||entries[1].name!="capsule.sig")fail(WebCapsuleErrorCode.INVALID_ORDER,"Metadata order invalid")
      val metadata=File(operation,"metadata");metadata.mkdirs()
      val manifestFile=File(metadata,"capsule.json");zip.extract(entries[0],manifestFile,limits.manifestBytes)
      val signatureFile=File(metadata,"capsule.sig");zip.extract(entries[1],signatureFile,89)
      val manifestStored=manifestFile.readBytes();if(manifestStored.isEmpty()||manifestStored.last()!=10.toByte()||(manifestStored.size>1&&manifestStored[manifestStored.size-2]==10.toByte()))fail(WebCapsuleErrorCode.INVALID_MANIFEST,"Manifest must end with one LF")
      val json=manifestStored.copyOf(manifestStored.size-1);val manifest=ManifestParser.parse(json);val canonical=StrictJson.canonicalize(json)
      if(!canonical.contentEquals(json))fail(WebCapsuleErrorCode.INVALID_MANIFEST,"Manifest is not canonical")
      if(manifest.capsuleId!=expectedCapsuleId)fail(WebCapsuleErrorCode.ID_MISMATCH,"Capsule ID mismatch")
      if(ManifestParser.compareVersions(runtimeVersion,manifest.minimumRuntimeVersion)<0)fail(WebCapsuleErrorCode.RUNTIME_INCOMPATIBLE,"Runtime incompatible")
      val signatureText=signatureFile.readBytes();if(signatureText.size!=89||signatureText.last()!=10.toByte())fail(WebCapsuleErrorCode.INVALID_SIGNATURE,"Signature encoding invalid")
      val encoded=String(signatureText,0,88,StandardCharsets.US_ASCII);if(!Regex("^[A-Za-z0-9+/]{86}==$",RegexOption.IGNORE_CASE).matches(encoded))fail(WebCapsuleErrorCode.INVALID_SIGNATURE,"Signature encoding invalid")
      val signature=try{Base64.getDecoder().decode(encoded)}catch(e:Exception){fail(WebCapsuleErrorCode.INVALID_SIGNATURE,"Signature Base64 invalid",e)};if(signature.size!=64)fail(WebCapsuleErrorCode.INVALID_SIGNATURE,"Signature length invalid")
      val pem=publicKeys[manifest.keyId]?:fail(WebCapsuleErrorCode.KEY_ID_MISMATCH,"No exact trusted key ID")
      SignatureVerifier.verify(canonical,signature,pem)
      val contentPaths=entries.drop(2).map{if(it.name.startsWith("files/"))it.name.removePrefix("files/") else it.name};ManifestParser.assertPathSet(contentPaths);val expected=listOf("capsule.json","capsule.sig")+manifest.files.map{"files/${it.path}"};if(entries.map{it.name}!=expected)fail(WebCapsuleErrorCode.INVALID_ORDER,"Archive set/order mismatch")
      val dos=dos(manifest.createdAt);if(entries.any{it.time!=dos.first||it.day!=dos.second})fail(WebCapsuleErrorCode.INVALID_TIMESTAMP,"ZIP timestamp mismatch")
      val blobs=mutableListOf<VerifiedBlob>();var total=0L
      manifest.files.forEachIndexed { index,file -> val target=File(operation,"blobs/${file.sha256}");val observed=zip.extract(entries[index+2],target,minOf(file.size,limits.fileBytes));total=Math.addExact(total,observed.size);if(total>limits.expandedBytes)fail(WebCapsuleErrorCode.LIMIT_EXCEEDED,"Expanded archive limit exceeded");if(observed.size!=file.size)fail(WebCapsuleErrorCode.HASH_MISMATCH,"File size mismatch");if(observed.sha256!=file.sha256)fail(WebCapsuleErrorCode.HASH_MISMATCH,"File hash mismatch");blobs+=VerifiedBlob(file.path,file.sha256,file.size,target) }
      val manifestHash=MessageDigest.getInstance("SHA-256").digest(canonical).joinToString(""){"%02x".format(it)}
      metadata.deleteRecursively();return VerifiedCapsule(manifest,canonical,manifestHash,blobs.toList(),operation)
    }} catch(error:Throwable){operation.deleteRecursively();if(error is WebCapsuleException)throw error;fail(WebCapsuleErrorCode.ARCHIVE_INVALID,"Capsule verification failed",error)}
  }
  private fun dos(value:String):Pair<Int,Int>{val date=Instant.parse(value).atZone(ZoneOffset.UTC);return ((date.second ushr 1) or (date.minute shl 5) or (date.hour shl 11)) to (date.dayOfMonth or (date.monthValue shl 5) or ((date.year-1980) shl 9))}
}
