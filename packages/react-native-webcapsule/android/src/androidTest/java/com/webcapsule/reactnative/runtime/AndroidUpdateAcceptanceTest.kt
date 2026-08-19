package com.webcapsule.reactnative.runtime

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.webcapsule.reactnative.WebCapsuleConfig
import java.io.File
import java.net.URI
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidUpdateAcceptanceTest {
  @Test fun installsSignedV2WithRealAtomicFileAndHardLinksAndPinsExistingSession() {
    val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    val root = File(context.noBackupFilesDir, "update-acceptance-${UUID.randomUUID()}")
    val updateRoot = File(context.cacheDir, "update-acceptance-${UUID.randomUUID()}")
    try {
      val publicKey = context.assets.open("keys/test-only-public.pem").bufferedReader().readText()
      val config = WebCapsuleConfig("com.example.android.e2e", "webcapsule/android-e2e-v1.capsule", mapOf("test-only" to publicKey), "1.0.0")
      val layout = StorageLayout(root); val versions = VersionStore(layout); val registries = RegistryStore(layout); val locks = CapsuleLockManager(layout)
      val v1 = copyAsset(context, config.bundledAssetPath, File(context.cacheDir, "v1-${UUID.randomUUID()}.capsule"))
      val record = versions.install(CapsuleVerifier().verify(v1, layout.stagingRoot, config.publicKeys, config.capsuleId, config.runtimeVersion)).record
      registries.createInitial(record); registries.update(config.capsuleId, 0) { it.copy(generation = 1, active = ActiveVersion("1.0.0", true), pending = null) }
      val recovery = RecoveryManager(layout, locks, registries, versions) { record }
      val selector = SessionSelector(locks, recovery, registries, versions)
      val old = selector.select(config.capsuleId)
      val index = context.assets.open("update-index-v1/valid-signed.json").readBytes()
      val transport = object : UpdateTransport {
        override fun fetchIndex(uri: URI) = index
        override fun fetchCapsule(release: UpdateRelease, updateRoot: File): DownloadedCapsule {
          val operation = File(updateRoot, UUID.randomUUID().toString()).also { it.mkdirs() }
          return DownloadedCapsule(copyAsset(context, "webcapsule/android-e2e-v2.capsule", File(operation, "download.capsule")), operation)
        }
      }
      val result = UpdateCoordinator(transport, root, updateRoot, BundledArchiveSource { context.assets.open(it) }).install(UpdateRequest(config, URI("https://example.com/index.json"), "stable")) as UpdateInstallResult.Installed
      val registry = registries.read(config.capsuleId)!!
      assertEquals("2.0.0", result.currentVersion); assertEquals(2, registry.generation)
      assertEquals(ActiveVersion("2.0.0", false), registry.active); assertEquals(PreviousVersion("1.0.0"), registry.previous)
      assertEquals(PendingVersion("2.0.0", 0), registry.pending); assertEquals("1.0.0", old.version)
      assertEquals("2.0.0", selector.select(config.capsuleId).version)
    } finally { root.deleteRecursively(); updateRoot.deleteRecursively() }
  }

  private fun copyAsset(context: android.content.Context, path: String, target: File): File {
    target.parentFile?.mkdirs(); context.assets.open(path).use { input -> target.outputStream().use(input::copyTo) }; return target
  }
}
