package com.webcapsule.reactnative.runtime

import java.io.File
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardOpenOption
import java.util.UUID

data class InstallResult(val record: VersionRecord, val installed: Boolean, val publishedBlobCount: Int)

enum class InstallFaultPoint { BEFORE_BLOB_PUBLISH, AFTER_BLOB_PUBLISH, BEFORE_RECORD_WRITE, BEFORE_VERSION_PUBLISH, AFTER_VERSION_DIRECTORY_CREATE, AFTER_VERSION_PUBLISH }
fun interface InstallFaultInjector { fun hit(point: InstallFaultPoint) }

class VersionStore(private val layout: StorageLayout, private val faultInjector: InstallFaultInjector = InstallFaultInjector { }) {
  private val contentStore = ContentStore(layout)

  fun install(capsule: VerifiedCapsule): InstallResult {
    capsule.claimForInstall()
    var publishedRecord = false
    var finalDirectoryCreated = false
    try {
      validateOperation(capsule)
      val record = VersionRecordCodec.fromVerified(capsule)
      val recordBytes = VersionRecordCodec.serialize(record)
      val finalDirectory = layout.versionDirectory(record.capsuleId, record.version)
      val finalRecord = File(finalDirectory, "record.json")
      if (Files.exists(finalRecord.toPath(), LinkOption.NOFOLLOW_LINKS)) {
        verifyPublishedVersion(finalDirectory, recordBytes, record)
        // Settles a publication interrupted between linking and the permission
        // change. The bytes were just proven identical, so this completes the
        // last step instead of repairing content.
        if (Files.isWritable(finalRecord.toPath())) ContentStore.makeReadOnly(finalRecord)
        return InstallResult(record, false, 0)
      }
      if (Files.exists(finalDirectory.toPath(), LinkOption.NOFOLLOW_LINKS))
        fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Incomplete final version directory exists")

      var published = 0
      capsule.blobs.forEach { blob ->
        faultInjector.hit(InstallFaultPoint.BEFORE_BLOB_PUBLISH)
        if (contentStore.publish(blob)) published++
        faultInjector.hit(InstallFaultPoint.AFTER_BLOB_PUBLISH)
      }
      contentStore.verify(record)
      faultInjector.hit(InstallFaultPoint.BEFORE_RECORD_WRITE)
      val stagedRecord = File(capsule.operationDirectory, "record.json")
      writeNewSynced(stagedRecord, recordBytes)
      writeJournal(capsule.operationDirectory, record.capsuleId, record.version, finalDirectory)
      ContentStore.createDirectories(finalDirectory.parentFile!!)
      faultInjector.hit(InstallFaultPoint.BEFORE_VERSION_PUBLISH)
      try { Files.createDirectory(finalDirectory.toPath()); finalDirectoryCreated = true }
      catch (error: FileAlreadyExistsException) { fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Version directory appeared before publication", error) }
      catch (error: Exception) { fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, "Cannot create final version directory", error) }
      faultInjector.hit(InstallFaultPoint.AFTER_VERSION_DIRECTORY_CREATE)
      // The staged record stays writable while linking: Android enforces
      // fs.protected_hardlinks, which refuses link() when the caller cannot also
      // write the source. The published inode is made read-only immediately after.
      try { Files.createLink(finalRecord.toPath(), stagedRecord.toPath()) }
      catch (error: UnsupportedOperationException) { cleanupOwnedEmptyDirectory(finalDirectory); fail(WebCapsuleErrorCode.ATOMIC_PUBLISH_UNSUPPORTED, "Filesystem does not support record hard-link publication", error) }
      catch (error: Exception) { cleanupOwnedEmptyDirectory(finalDirectory); fail(WebCapsuleErrorCode.ATOMIC_PUBLISH_UNSUPPORTED, "Record create-if-absent publication failed", error) }
      publishedRecord = true
      ContentStore.makeReadOnly(finalRecord)
      faultInjector.hit(InstallFaultPoint.AFTER_VERSION_PUBLISH)
      verifyPublishedVersion(finalDirectory, recordBytes, record)
      return InstallResult(record, true, published)
    } finally {
      if (publishedRecord || !finalDirectoryCreated) cleanupOwnedOperation(capsule.operationDirectory)
    }
  }

  fun read(capsuleId: String, version: String): VersionRecord {
    val directory = layout.versionDirectory(capsuleId, version)
    val recordFile = strictRecordFile(directory)
    val bytes = try { Files.readAllBytes(recordFile.toPath()) } catch (error: Exception) { fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Cannot read referenced version record", error) }
    val record = try { VersionRecordCodec.parse(bytes) } catch (error: WebCapsuleException) { fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Referenced version record is invalid", error) }
    if (record.capsuleId != capsuleId || record.version != version) fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Version path and record identity differ")
    contentStore.verify(record)
    return record
  }

  private fun verifyPublishedVersion(directory: File, expectedBytes: ByteArray, expected: VersionRecord) {
    val recordFile = strictRecordFile(directory)
    val bytes = try { Files.readAllBytes(recordFile.toPath()) } catch (error: Exception) { fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Cannot read published record", error) }
    val parsed = try { VersionRecordCodec.parse(bytes) } catch (error: WebCapsuleException) { fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Published version record is invalid", error) }
    if (!bytes.contentEquals(expectedBytes) || parsed != expected) fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Published version differs")
    contentStore.verify(parsed)
  }

  private fun strictRecordFile(directory: File): File {
    if (Files.isSymbolicLink(directory.toPath()) || !Files.isDirectory(directory.toPath(), LinkOption.NOFOLLOW_LINKS)) fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Version path is not a published directory")
    val children = directory.listFiles() ?: fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, "Cannot list version directory")
    if (children.size != 1 || children[0].name != "record.json" || Files.isSymbolicLink(children[0].toPath()) || !Files.isRegularFile(children[0].toPath(), LinkOption.NOFOLLOW_LINKS))
      fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Published version directory is not exact")
    return children[0]
  }

  private fun validateOperation(capsule: VerifiedCapsule) {
    val operation = capsule.operationDirectory
    val operationCanonical = try { operation.canonicalFile } catch (error: Exception) { fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, "Cannot resolve operation directory", error) }
    if (operationCanonical.parentFile != layout.stagingRoot.canonicalFile || !Files.isDirectory(operationCanonical.toPath(), LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(operationCanonical.toPath()))
      fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Verified operation is outside storage staging")
    try { UUID.fromString(operationCanonical.name) } catch (error: Exception) { fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Operation directory name is invalid", error) }
    if (capsule.blobs.map { it.path } != capsule.manifest.files.map { it.path } || capsule.blobs.map { it.sha256 } != capsule.manifest.files.map { it.sha256 } || capsule.blobs.map { it.size } != capsule.manifest.files.map { it.size })
      fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Verified blob metadata differs from manifest")
  }

  private fun writeNewSynced(file: File, bytes: ByteArray) {
    try { Files.newOutputStream(file.toPath(), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE).use { it.write(bytes) }; ContentStore.syncFile(file) }
    catch (error: WebCapsuleException) { throw error }
    catch (error: Exception) { fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, "Cannot write version record", error) }
  }

  private fun writeJournal(operation: File, capsuleId: String, version: String, finalDirectory: File) {
    val journal = File(operation, "publish-journal.json")
    val bytes = ("{\"capsuleId\":${quote(capsuleId)},\"finalDirectory\":${quote(finalDirectory.absolutePath)},\"finalDirectoryOwned\":true,\"version\":${quote(version)}}\n").toByteArray()
    writeNewSynced(journal, bytes)
  }

  private fun quote(value: String) = org.erdtman.jcs.JsonCanonicalizer("{\"v\":${org.json.JSONObject.quote(value)}}").encodedString.substring(5).dropLast(1)
  private fun cleanupOwnedEmptyDirectory(directory: File) { if (directory.exists() && !directory.delete()) fail(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION, "Cannot remove owned empty version directory") }
  private fun cleanupOwnedOperation(operation: File) { if (operation.exists() && !operation.deleteRecursively()) fail(WebCapsuleErrorCode.STORAGE_IO_FAILED, "Cannot clean operation staging") }
}
