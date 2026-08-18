package com.webcapsule.reactnative.runtime

import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.text.Normalizer

class StorageLayout(val root: File) {
  val blobsRoot = File(root, "blobs/sha256")
  val versionsRoot = File(root, "versions")
  val registriesRoot = File(root, "registries")
  val stagingRoot = File(root, "staging")
  val locksRoot = File(root, "locks")

  fun blob(hash: String): File {
    requireHash(hash)
    return File(File(blobsRoot, hash.substring(0, 2)), hash)
  }

  fun versionDirectory(capsuleId: String, version: String): File =
    File(File(versionsRoot, encode(capsuleId)), encode(version))

  fun registry(capsuleId: String): File = File(registriesRoot, "${encode(capsuleId)}.json")

  fun lock(capsuleId: String): File = File(locksRoot, "${encode(capsuleId)}.lock")

  companion object {
    private val lowercaseHex = Regex("^[0-9a-f]+$")
    private val hash = Regex("^[0-9a-f]{64}$")

    fun forNoBackupFilesDir(noBackupFilesDir: File): StorageLayout =
      StorageLayout(File(noBackupFilesDir, "webcapsule/v1"))

    fun encode(value: String): String {
      if (Normalizer.normalize(value, Normalizer.Form.NFC) != value) {
        fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Storage key is not NFC")
      }
      return value.toByteArray(StandardCharsets.UTF_8).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    fun decode(value: String): String {
      if (value.isEmpty() || value.length % 2 != 0 || !lowercaseHex.matches(value)) {
        fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Invalid storage key encoding")
      }
      val bytes = ByteArray(value.length / 2) { index ->
        value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
      }
      val decoded = try {
        StandardCharsets.UTF_8.newDecoder()
          .onMalformedInput(CodingErrorAction.REPORT)
          .onUnmappableCharacter(CodingErrorAction.REPORT)
          .decode(ByteBuffer.wrap(bytes)).toString()
      } catch (error: Exception) {
        fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Storage key is not UTF-8", error)
      }
      if (Normalizer.normalize(decoded, Normalizer.Form.NFC) != decoded || encode(decoded) != value) {
        fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Storage key is not canonical")
      }
      return decoded
    }

    internal fun requireHash(value: String) {
      if (!hash.matches(value)) fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Invalid blob hash")
    }
  }
}
