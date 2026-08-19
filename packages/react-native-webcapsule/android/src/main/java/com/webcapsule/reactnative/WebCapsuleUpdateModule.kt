package com.webcapsule.reactnative

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.webcapsule.reactnative.runtime.UpdateCoordinator
import com.webcapsule.reactnative.runtime.UpdateInstallResult
import com.webcapsule.reactnative.runtime.UpdateIndexVerifier
import com.webcapsule.reactnative.runtime.UpdateRequest
import com.webcapsule.reactnative.runtime.WebCapsuleErrorCode
import com.webcapsule.reactnative.runtime.WebCapsuleException
import java.util.concurrent.Executors

internal object WebCapsuleUpdateOptionsParser {
  private val fields = setOf("capsuleId", "bundledAssetPath", "publicKeys", "runtimeVersion", "indexUrl", "channel")

  fun parse(root: Map<String, Any?>): UpdateRequest {
    if (root.keys != fields) throw WebCapsuleException(WebCapsuleErrorCode.INVALID_ARGUMENT, "Update options fields differ")
    fun string(key: String) = root[key] as? String
      ?: throw WebCapsuleException(WebCapsuleErrorCode.INVALID_ARGUMENT, "$key must be a string")
    val rawKeys = root["publicKeys"] as? Map<*, *>
      ?: throw WebCapsuleException(WebCapsuleErrorCode.INVALID_ARGUMENT, "publicKeys must be an object")
    val keys = linkedMapOf<String, String>()
    rawKeys.forEach { (key, value) ->
      if (key !is String || value !is String) throw WebCapsuleException(WebCapsuleErrorCode.INVALID_ARGUMENT, "publicKeys entries must be strings")
      keys[key] = value
    }
    val config = WebCapsuleConfig(string("capsuleId"), string("bundledAssetPath"), keys, string("runtimeVersion"))
    WebCapsuleConfigValidator.validate(config)?.let { throw WebCapsuleException(WebCapsuleErrorCode.INVALID_ARGUMENT, it) }
    return UpdateRequest(config, UpdateIndexVerifier.strictHttps(string("indexUrl")), string("channel"))
  }
}

class WebCapsuleUpdateModule(private val reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext) {
  private val executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "webcapsule-update").apply { isDaemon = true } }

  override fun getName() = "WebCapsuleUpdate"

  @ReactMethod
  fun installWebCapsuleUpdate(options: ReadableMap, promise: Promise) {
    val request = try { parse(options) } catch (error: WebCapsuleException) { promise.reject(error.code.name, error.message, error); return }
    try {
      executor.execute {
        try {
          val result = UpdateCoordinator(reactContext.applicationContext).install(request)
        val output = Arguments.createMap()
        when (result) {
          is UpdateInstallResult.Installed -> {
            output.putString("status", "installed")
            output.putString("previousVersion", result.previousVersion)
            output.putString("currentVersion", result.currentVersion)
            output.putString("highestSeenVersion", result.highestSeenVersion)
            output.putString("generation", result.generation.toString())
          }
          is UpdateInstallResult.UpToDate -> {
            output.putString("status", "up-to-date")
            output.putString("currentVersion", result.currentVersion)
            output.putString("highestSeenVersion", result.highestSeenVersion)
            output.putString("generation", result.generation.toString())
          }
        }
          promise.resolve(output)
        } catch (error: WebCapsuleException) { promise.reject(error.code.name, error.message, error) }
        catch (error: Throwable) { promise.reject(WebCapsuleErrorCode.INSTALL_FAILED.name, "Update installation failed", error) }
      }
    } catch (error: java.util.concurrent.RejectedExecutionException) {
      promise.reject(WebCapsuleErrorCode.INSTALL_FAILED.name, "Update module is unavailable", error)
    }
  }

  override fun invalidate() { executor.shutdownNow(); super.invalidate() }

  internal fun parse(root: ReadableMap): UpdateRequest {
    val values = linkedMapOf<String, Any?>()
    val iterator = root.keySetIterator()
    while (iterator.hasNextKey()) {
      val key = iterator.nextKey()
      values[key] = when (root.getType(key)) {
        com.facebook.react.bridge.ReadableType.String -> root.getString(key)
        com.facebook.react.bridge.ReadableType.Map -> {
          val nested = root.getMap(key)!!; val entries = linkedMapOf<String, Any?>(); val nestedIterator = nested.keySetIterator()
          while (nestedIterator.hasNextKey()) { val nestedKey = nestedIterator.nextKey(); entries[nestedKey] = if (nested.getType(nestedKey) == com.facebook.react.bridge.ReadableType.String) nested.getString(nestedKey) else null }
          entries
        }
        else -> null
      }
    }
    return WebCapsuleUpdateOptionsParser.parse(values)
  }
}
