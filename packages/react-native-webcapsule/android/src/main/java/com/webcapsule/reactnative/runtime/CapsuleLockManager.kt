package com.webcapsule.reactnative.runtime

import java.nio.channels.FileChannel
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributes
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock

class CapsuleLockManager(private val layout: StorageLayout) {
  companion object { private val processLocks = ConcurrentHashMap<String, ReentrantLock>() }

  fun <T> withLock(capsuleId: String, action: () -> T): T {
    val key = StorageLayout.encode(capsuleId)
    val processLock = processLocks.computeIfAbsent(key) { ReentrantLock() }
    processLock.lock()
    try {
      val lockFile = layout.lock(capsuleId)
      try {
        ContentStore.createDirectories(layout.locksRoot)
        try { Files.createFile(lockFile.toPath()) } catch (_: FileAlreadyExistsException) { }
        val before = Files.readAttributes(lockFile.toPath(), BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
        if (!before.isRegularFile || before.isSymbolicLink) fail(WebCapsuleErrorCode.LOCK_FAILED, "Capsule lock path is not a regular file")
        FileChannel.open(lockFile.toPath(), StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS).use { channel ->
          val after = Files.readAttributes(lockFile.toPath(), BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
          if (!after.isRegularFile || before.fileKey() != after.fileKey()) fail(WebCapsuleErrorCode.LOCK_FAILED, "Capsule lock path changed while opening")
          channel.lock().use { return action() }
        }
      } catch (error: WebCapsuleException) { throw error }
      catch (error: UnsupportedOperationException) { fail(WebCapsuleErrorCode.LOCK_FAILED, "Filesystem does not support no-follow lock opening", error) }
      catch (error: Exception) { fail(WebCapsuleErrorCode.LOCK_FAILED, "Cannot acquire capsule lock", error) }
    } finally { processLock.unlock() }
  }
}
