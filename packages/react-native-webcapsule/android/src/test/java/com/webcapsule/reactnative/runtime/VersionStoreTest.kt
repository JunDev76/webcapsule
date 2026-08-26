package com.webcapsule.reactnative.runtime

import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.rules.TemporaryFolder

class VersionStoreTest {
  private val temporary = TemporaryFolder.builder().assureDeletion().build().also { it.create() }

  @Test
  fun `storage encoding round trips strict NFC UTF-8`() {
    val value = "com.example.한글"
    val encoded = StorageLayout.encode(value)
    assertEquals(value, StorageLayout.decode(encoded))
    expect(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION) { StorageLayout.decode(encoded.uppercase()) }
    expect(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION) { StorageLayout.decode("abc") }
    expect(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION) { StorageLayout.decode("ff") }
    expect(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION) { StorageLayout.encode("e\u0301") }
  }

  @Test
  fun `installs exact record and reuses shared blob across versions`() {
    val layout = layout()
    val first = capsule(layout, "1.0.0", "shared")
    val firstResult = VersionStore(layout).install(first)
    assertTrue(firstResult.installed)
    assertEquals(1, firstResult.publishedBlobCount)

    val second = capsule(layout, "1.1.0", "shared")
    val secondResult = VersionStore(layout).install(second)
    assertTrue(secondResult.installed)
    assertEquals(0, secondResult.publishedBlobCount)
    assertEquals(1, layout.blobsRoot.walkTopDown().count { it.isFile })

    val record = File(layout.versionDirectory("com.example.app", "1.0.0"), "record.json")
    val expected = "{\"capsuleId\":\"com.example.app\",\"createdAt\":\"2026-08-16T10:00:00Z\",\"entry\":\"index.html\",\"files\":[{\"mediaType\":\"text/html\",\"path\":\"index.html\",\"sha256\":\"a4d26868017c0ccffe2efe50944ef4211834660cca834c6e9f86dec6a88246fa\",\"size\":6}],\"keyId\":\"release-2027\",\"manifestSha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"schemaVersion\":1,\"version\":\"1.0.0\"}\n"
    assertEquals(expected, record.readText(StandardCharsets.UTF_8))
  }

  @Test
  fun `identical existing version is idempotent and conflict is never overwritten`() {
    val layout = layout()
    VersionStore(layout).install(capsule(layout, "1.0.0", "shared"))
    val result = VersionStore(layout).install(capsule(layout, "1.0.0", "shared"))
    assertFalse(result.installed)

    val record = File(layout.versionDirectory("com.example.app", "1.0.0"), "record.json")
    record.setWritable(true)
    record.appendText("x")
    expect(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION) {
      VersionStore(layout).install(capsule(layout, "1.0.0", "shared"))
    }
    assertTrue(record.readText().endsWith("x"))
  }

  @Test
  fun `wrong existing blob is rejected without overwrite`() {
    val layout = layout()
    val capsule = capsule(layout, "1.0.0", "shared")
    val destination = layout.blob(capsule.blobs.single().sha256)
    destination.parentFile.mkdirs()
    destination.writeText("wrong")
    expect(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION) { VersionStore(layout).install(capsule) }
    assertEquals("wrong", destination.readText())
    assertFalse(layout.versionDirectory("com.example.app", "1.0.0").exists())
  }

  @Test
  fun `extra published version file is an invariant violation`() {
    val layout = layout()
    VersionStore(layout).install(capsule(layout, "1.0.0", "shared"))
    File(layout.versionDirectory("com.example.app", "1.0.0"), "extra").writeText("x")
    expect(WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION) {
      VersionStore(layout).install(capsule(layout, "1.0.0", "shared"))
    }
  }

  @Test
  fun `faults never leave a partial final version and clean owned staging`() {
    InstallFaultPoint.entries.forEach { point ->
      val layout = layout(point.name)
      val capsule = capsule(layout, "1.0.0", "content-$point")
      expect(WebCapsuleErrorCode.INSTALL_FAILED) {
        VersionStore(layout, InstallFaultInjector { if (it == point) fail(WebCapsuleErrorCode.INSTALL_FAILED, "injected") }).install(capsule)
      }
      val final = layout.versionDirectory("com.example.app", "1.0.0")
      when (point) {
        InstallFaultPoint.AFTER_VERSION_PUBLISH -> assertTrue(File(final, "record.json").isFile)
        InstallFaultPoint.AFTER_VERSION_DIRECTORY_CREATE -> {
          assertTrue(final.isDirectory)
          assertFalse(File(final, "record.json").exists())
          assertTrue(capsule.operationDirectory.isDirectory)
        }
        else -> assertFalse(final.exists())
      }
      if (point != InstallFaultPoint.AFTER_VERSION_DIRECTORY_CREATE) assertFalse(capsule.operationDirectory.exists())
    }
  }

  @Test
  fun `blob publication interrupted before the permission change is settled on retry`() {
    val layout = layout()
    val capsule = capsule(layout, "1.0.0", "shared")
    val destination = layout.blob(capsule.blobs.single().sha256)
    destination.parentFile.mkdirs()
    // A crash between hard-linking and the 0444 change leaves the published name
    // byte-identical but still writable.
    destination.writeText("shared")
    assertTrue(destination.setWritable(true))
    assertTrue(Files.isWritable(destination.toPath()))

    val result = VersionStore(layout).install(capsule)
    assertTrue(result.installed)
    assertEquals(0, result.publishedBlobCount)
    assertFalse(Files.isWritable(destination.toPath()))
    assertEquals("shared", destination.readText())
  }

  @Test
  fun `record publication interrupted before the permission change is settled on retry`() {
    val layout = layout()
    VersionStore(layout).install(capsule(layout, "1.0.0", "shared"))
    val record = File(layout.versionDirectory("com.example.app", "1.0.0"), "record.json")
    assertTrue(record.setWritable(true))
    assertTrue(Files.isWritable(record.toPath()))
    val expected = record.readText(StandardCharsets.UTF_8)

    val result = VersionStore(layout).install(capsule(layout, "1.0.0", "shared"))
    assertFalse(result.installed)
    assertFalse(Files.isWritable(record.toPath()))
    assertEquals(expected, record.readText(StandardCharsets.UTF_8))
  }

  @Test
  fun `record parser rejects noncanonical unknown and missing fields`() {
    val layout = layout()
    val capsule = capsule(layout, "1.0.0", "shared")
    val bytes = VersionRecordCodec.serialize(VersionRecordCodec.fromVerified(capsule))
    assertEquals("1.0.0", VersionRecordCodec.parse(bytes).version)
    expect(WebCapsuleErrorCode.VERSION_RECORD_INVALID) { VersionRecordCodec.parse(bytes.dropLast(1).toByteArray()) }
    val unknown = String(bytes, StandardCharsets.UTF_8).replace("\"schemaVersion\":1", "\"unknown\":0,\"schemaVersion\":1")
    expect(WebCapsuleErrorCode.VERSION_RECORD_INVALID) { VersionRecordCodec.parse(unknown.toByteArray()) }
  }

  private fun layout(suffix: String = "root"): StorageLayout = StorageLayout(File(temporary.root, suffix))

  private fun capsule(layout: StorageLayout, version: String, content: String): VerifiedCapsule {
    val operation = File(layout.stagingRoot, UUID.randomUUID().toString())
    val blobFile = File(operation, "blobs/blob")
    blobFile.parentFile.mkdirs()
    blobFile.writeText(content, StandardCharsets.UTF_8)
    val bytes = content.toByteArray(StandardCharsets.UTF_8)
    val hash = sha256(bytes)
    val entry = CapsuleFileEntry("index.html", hash, bytes.size.toLong(), "text/html")
    val manifest = CapsuleManifest(1, "com.example.app", version, "index.html", "2026-08-16T10:00:00Z", "1.0.0", "release-2027", listOf(entry), CapsulePolicy(NetworkPolicy("deny", null), NavigationPolicy(emptyList()), emptyList()))
    return VerifiedCapsule(manifest, byteArrayOf(), "a".repeat(64), listOf(VerifiedBlob(entry.path, hash, entry.size, blobFile)), operation)
  }

  private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

  private fun expect(code: WebCapsuleErrorCode, action: () -> Unit) {
    try {
      action()
      throw AssertionError("Expected $code")
    } catch (error: WebCapsuleException) {
      assertEquals(code, error.code)
    }
  }
}
