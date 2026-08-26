package com.webcapsule.reactnative.runtime

import java.io.File
import java.io.FileInputStream
import java.io.RandomAccessFile
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermission
import java.security.MessageDigest

internal class ContentStore(private val layout: StorageLayout) {
  fun publish(blob: VerifiedBlob): Boolean {
    verifyRegular(blob.file, blob.size, blob.sha256, WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, requireReadOnly = false)
    syncFile(blob.file)
    val destination = layout.blob(blob.sha256)
    destination.parentFile?.let(::createDirectories)
    // The staging blob stays writable while linking. Android enforces
    // fs.protected_hardlinks, which refuses link() when the caller cannot also
    // write the source. Immutability is applied to the shared inode right after
    // the link succeeds, so the published name is never mutated.
    try {
      Files.createLink(destination.toPath(), blob.file.toPath())
    } catch (error: FileAlreadyExistsException) {
      completeInterruptedPublication(destination, blob.size, blob.sha256)
      if (!blob.file.delete()) io("Cannot remove reused staging blob")
      return false
    } catch (error: UnsupportedOperationException) {
      fail(WebCapsuleErrorCode.ATOMIC_PUBLISH_UNSUPPORTED, "Filesystem does not support hard-link publication", error)
    } catch (error: Exception) {
      fail(WebCapsuleErrorCode.ATOMIC_PUBLISH_UNSUPPORTED, "Atomic create-if-absent publication failed", error)
    }
    makeReadOnly(destination)
    if (!blob.file.delete()) io("Cannot unlink published staging blob")
    verifyRegular(destination, blob.size, blob.sha256, WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, requireReadOnly = true)
    return true
  }

  fun verify(record: VersionRecord) {
    record.files.forEach { file ->
      val blob = layout.blob(file.sha256)
      if (!Files.exists(blob.toPath(), LinkOption.NOFOLLOW_LINKS)) fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Referenced blob is missing")
      verifyRegular(blob, file.size, file.sha256, WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, requireReadOnly = true)
    }
  }

  companion object {
    internal fun createDirectories(directory: File) {
      try { Files.createDirectories(directory.toPath()) }
      catch (error: Exception) { fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, "Cannot create storage directory", error) }
      if (!Files.isDirectory(directory.toPath(), LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(directory.toPath()))
        fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Storage parent is not a directory")
    }

    internal fun syncFile(file: File) {
      try { RandomAccessFile(file, "r").use { it.fd.sync() } }
      catch (error: Exception) { fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, "File fsync failed", error) }
    }

    internal fun makeReadOnly(file: File) {
      try {
        Files.setPosixFilePermissions(file.toPath(), setOf(
          PosixFilePermission.OWNER_READ, PosixFilePermission.GROUP_READ, PosixFilePermission.OTHERS_READ,
        ))
      } catch (error: UnsupportedOperationException) {
        fail(WebCapsuleErrorCode.ATOMIC_PUBLISH_UNSUPPORTED, "Filesystem cannot enforce immutable blob permissions", error)
      } catch (error: Exception) {
        fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, "Cannot make blob read-only", error)
      }
    }

    /**
     * Finishes a publication that was interrupted between linking and the
     * permission change. The destination content is never altered: type, size,
     * and SHA-256 must match exactly, and only a still-writable mode is settled
     * to 0444. Any content difference remains a storage invariant violation.
     */
    internal fun completeInterruptedPublication(destination: File, size: Long, hash: String) {
      verifyRegular(destination, size, hash, WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, requireReadOnly = false)
      if (Files.isWritable(destination.toPath())) makeReadOnly(destination)
      verifyRegular(destination, size, hash, WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, requireReadOnly = true)
    }

    internal fun verifyRegular(file: File, size: Long, hash: String, code: WebCapsuleErrorCode, requireReadOnly: Boolean = false) {
      try {
        val path = file.toPath()
        if (Files.isSymbolicLink(path) || !Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) || Files.size(path) != size)
          fail(code, "Blob type or size differs")
        if (requireReadOnly && Files.isWritable(path)) fail(code, "Published blob is writable")
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
          val buffer = ByteArray(64 * 1024)
          while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
        }
        val observed = digest.digest().joinToString("") { "%02x".format(it) }
        if (observed != hash) fail(code, "Blob hash differs")
      } catch (error: WebCapsuleException) { throw error }
      catch (error: Exception) { fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, "Cannot verify blob", error) }
    }

    internal fun io(message: String, cause: Throwable? = null): Nothing = fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, message, cause)
  }
}
