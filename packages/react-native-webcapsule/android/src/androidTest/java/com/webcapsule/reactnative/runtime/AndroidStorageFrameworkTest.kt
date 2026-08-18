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

    destination.delete()
    Files.setPosixFilePermissions(source.toPath(), setOf(PosixFilePermission.OWNER_READ))
    Files.createLink(destination.toPath(), source.toPath())
    val sourceAttributes = Files.readAttributes(source.toPath(), java.nio.file.attribute.BasicFileAttributes::class.java)
    val destinationAttributes = Files.readAttributes(destination.toPath(), java.nio.file.attribute.BasicFileAttributes::class.java)
    assertEquals(sourceAttributes.fileKey(), destinationAttributes.fileKey())
    assertFalse(Files.isWritable(destination.toPath()))
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
