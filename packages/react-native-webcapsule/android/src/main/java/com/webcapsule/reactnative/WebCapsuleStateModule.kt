package com.webcapsule.reactnative

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.webcapsule.reactnative.runtime.AndroidRuntimeCoordinator
import com.webcapsule.reactnative.runtime.WebCapsuleErrorCode
import com.webcapsule.reactnative.runtime.WebCapsuleException
import java.util.concurrent.Executors

internal object WebCapsuleStateOptionsParser {
  private val fields = setOf("capsuleId", "bundledAssetPath", "publicKeys", "runtimeVersion")

  fun parse(root: Map<String, Any?>): WebCapsuleConfig {
    if (root.keys != fields) throw WebCapsuleException(WebCapsuleErrorCode.INVALID_ARGUMENT, "State options fields differ")
    fun string(key: String) = root[key] as? String
      ?: throw WebCapsuleException(WebCapsuleErrorCode.INVALID_ARGUMENT, "$key must be a string")
    val rawKeys = root["publicKeys"] as? Map<*, *>
      ?: throw WebCapsuleException(WebCapsuleErrorCode.INVALID_ARGUMENT, "publicKeys must be an object")
    val keys = linkedMapOf<String, String>()
    rawKeys.forEach { (key, value) ->
      if (key !is String || value !is String) throw WebCapsuleException(WebCapsuleErrorCode.INVALID_ARGUMENT, "publicKeys entries must be strings")
      keys[key] = value
    }
    return WebCapsuleConfig(string("capsuleId"), string("bundledAssetPath"), keys, string("runtimeVersion")).also {
      WebCapsuleConfigValidator.validate(it)?.let { message -> throw WebCapsuleException(WebCapsuleErrorCode.INVALID_ARGUMENT, message) }
    }
  }
}

class WebCapsuleStateModule(private val reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext) {
  private val executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "webcapsule-state").apply { isDaemon = true } }
  override fun getName() = "WebCapsuleState"

  @ReactMethod fun getWebCapsuleRuntimeState(options: ReadableMap, promise: Promise) {
    val config = try { parseConfig(options) } catch (error: WebCapsuleException) { promise.reject(error.code.name, error.message, error); return }
    executor.execute {
      try {
        val registry = AndroidRuntimeCoordinator(reactContext.applicationContext).ensureState(config)
        val output = Arguments.createMap().apply {
          putString("capsuleId", registry.capsuleId)
          putString("activeVersion", registry.active.version)
          putBoolean("activeHealthy", registry.active.healthy)
          if (registry.previous == null) putNull("previousVersion") else putString("previousVersion", registry.previous.version)
          if (registry.pending == null) putNull("pending") else putMap("pending", Arguments.createMap().apply {
            putString("version", registry.pending.version); putString("attempts", registry.pending.attempts.toString())
          })
          putString("highestSeenVersion", registry.highestSeenVersion)
          putArray("blockedVersions", Arguments.fromList(registry.blockedVersions))
          putString("generation", registry.generation.toString())
        }
        promise.resolve(output)
      } catch (error: WebCapsuleException) { promise.reject(error.code.name, error.message, error) }
      catch (error: Throwable) { promise.reject(WebCapsuleErrorCode.STORAGE_IO_FAILED.name, "Runtime state cannot be read", error) }
    }
  }

  override fun invalidate() { executor.shutdownNow(); super.invalidate() }

  private fun parseConfig(root: ReadableMap): WebCapsuleConfig {
    val values = linkedMapOf<String, Any?>()
    val iterator = root.keySetIterator()
    while (iterator.hasNextKey()) {
      val key = iterator.nextKey()
      values[key] = when (root.getType(key)) {
        com.facebook.react.bridge.ReadableType.String -> root.getString(key)
        com.facebook.react.bridge.ReadableType.Map -> root.getMap(key)?.toHashMap()
        else -> null
      }
    }
    return WebCapsuleStateOptionsParser.parse(values)
  }
}
