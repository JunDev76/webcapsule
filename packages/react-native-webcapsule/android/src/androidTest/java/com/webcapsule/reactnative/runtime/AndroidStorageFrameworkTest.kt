package com.webcapsule.reactnative.runtime

import androidx.core.util.AtomicFile
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermission
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidStorageFrameworkTest {
  private fun directory(name: String): File {
    val root = File(ApplicationProvider.getApplicationContext<android.content.Context>().noBackupFilesDir, "instrumentation-$name")
    root.deleteRecursively()
    assertTrue(root.mkdirs())
    return root
  }

  @Test
  fun hardLinkPublicationIsCreateIfAbsentAndPreservesExistingDestination() {
    val root = directory("hard-link")
    val source = File(root, "source").apply { writeText("new") }
    val destination = File(root, "destination").apply { writeText("old") }
    val oldKey = Files.readAttributes(destination.toPath(), java.nio.file.attribute.BasicFileAttributes::class.java).fileKey()

    assertThrows(FileAlreadyExistsException::class.java) {
      Files.createLink(destination.toPath(), source.toPath())
    }
    assertEquals("old", destination.readText())
    assertEquals(oldKey, Files.readAttributes(destination.toPath(), java.nio.file.attribute.BasicFileAttributes::class.java).fileKey())

    // Publication order is link-then-chmod. Android enforces
    // fs.protected_hardlinks, which refuses link() when the source is not
    // writable by the caller, so the source must still be writable here.
    destination.delete()
    Files.createLink(destination.toPath(), source.toPath())
    val sourceAttributes = Files.readAttributes(source.toPath(), java.nio.file.attribute.BasicFileAttributes::class.java)
    val destinationAttributes = Files.readAttributes(destination.toPath(), java.nio.file.attribute.BasicFileAttributes::class.java)
    assertEquals(sourceAttributes.fileKey(), destinationAttributes.fileKey())

    // The shared inode is made read-only after linking, so both names observe it.
    Files.setPosixFilePermissions(destination.toPath(), setOf(PosixFilePermission.OWNER_READ))
    assertFalse(Files.isWritable(destination.toPath()))
    assertFalse(Files.isWritable(source.toPath()))

    // Unlinking the staging name needs directory write permission, not file
    // write permission, so it still succeeds against the read-only inode.
    assertTrue(source.delete())
    assertEquals("new", destination.readText())
  }

  @Test
  fun linkingAReadOnlySourceIsRefusedByProtectedHardlinks() {
    val root = directory("protected-hardlink")
    val source = File(root, "source").apply { writeText("new") }
    Files.setPosixFilePermissions(source.toPath(), setOf(PosixFilePermission.OWNER_READ))

    // Documents why publication must not chmod before linking: the kernel treats
    // a source the caller cannot write as an unsafe hard-link source.
    assertThrows(java.nio.file.AccessDeniedException::class.java) {
      Files.createLink(File(root, "destination").toPath(), source.toPath())
    }
  }

  @Test
  fun atomicFileFailureRestoresOldBytesAndFinishPublishesNewBytes() {
    val file = File(directory("atomic"), "registry.json")
    val atomic = AtomicFile(file)
    atomic.startWrite().let { stream ->
      stream.write("old".toByteArray())
      atomic.finishWrite(stream)
    }

    atomic.startWrite().let { stream ->
      stream.write("partial".toByteArray())
      atomic.failWrite(stream)
    }
    assertArrayEquals("old".toByteArray(), atomic.readFully())

    atomic.startWrite().let { stream ->
      stream.write("new".toByteArray())
      atomic.finishWrite(stream)
    }
    assertArrayEquals("new".toByteArray(), atomic.readFully())
    assertNotEquals("old", file.readText())
  }
}
