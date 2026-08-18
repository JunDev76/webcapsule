package com.webcapsule.reactnative

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.bridge.ReactContext
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.uimanager.events.RCTEventEmitter
import java.util.TreeMap

class WebCapsuleViewManager : SimpleViewManager<WebCapsuleWebView>() {
  private data class PendingConfig(
    var capsuleId: String? = null,
    var bundledAssetPath: String? = null,
    var publicKeys: Map<String, String>? = null,
    var runtimeVersion: String? = null,
    var error: String? = null,
  )

  private val pending = java.util.WeakHashMap<WebCapsuleWebView, PendingConfig>()

  override fun getName() = "WebCapsuleView"

  override fun createViewInstance(reactContext: ThemedReactContext): WebCapsuleWebView =
    WebCapsuleWebView(reactContext).also { view ->
      pending[view] = PendingConfig()
      view.errorListener = { code, message -> emitError(view, code, message) }
      view.loadListener = { capsuleId, version -> emitLoad(view, capsuleId, version) }
    }

  @ReactProp(name = "capsuleId")
  fun setCapsuleId(view: WebCapsuleWebView, value: String?) {
    pending.getValue(view).capsuleId = value
  }

  @ReactProp(name = "bundledAssetPath")
  fun setBundledAssetPath(view: WebCapsuleWebView, value: String?) {
    pending.getValue(view).bundledAssetPath = value
  }

  @ReactProp(name = "publicKeys")
  fun setPublicKeys(view: WebCapsuleWebView, value: ReadableMap?) {
    val values = pending.getValue(view)
    try {
      values.publicKeys = value?.let(::readStringMap)
      values.error = null
    } catch (error: Exception) {
      values.publicKeys = null
      values.error = error.message ?: "publicKeys is invalid"
    }
  }

  @ReactProp(name = "runtimeVersion")
  fun setRuntimeVersion(view: WebCapsuleWebView, value: String?) {
    pending.getValue(view).runtimeVersion = value
  }

  override fun onAfterUpdateTransaction(view: WebCapsuleWebView) {
    super.onAfterUpdateTransaction(view)
    val values = pending.getValue(view)
    val missing = buildList {
      if (values.capsuleId == null) add("capsuleId")
      if (values.bundledAssetPath == null) add("bundledAssetPath")
      if (values.publicKeys == null) add("publicKeys")
      if (values.runtimeVersion == null) add("runtimeVersion")
    }
    val argumentError = values.error ?: missing.takeIf { it.isNotEmpty() }?.joinToString(prefix = "Missing required props: ")
    if (argumentError != null) {
      view.clearRuntime()
      emitError(view, "INVALID_ARGUMENT", argumentError)
      return
    }
    val config = WebCapsuleConfig(values.capsuleId!!, values.bundledAssetPath!!, values.publicKeys!!, values.runtimeVersion!!)
    val validationError = WebCapsuleConfigValidator.validate(config)
    if (validationError != null) {
      view.clearRuntime()
      emitError(view, "INVALID_ARGUMENT", validationError)
    } else view.attachRuntime(config)
  }

  override fun onDropViewInstance(view: WebCapsuleWebView) {
    pending.remove(view)
    view.destroy()
    super.onDropViewInstance(view)
  }

  override fun getExportedCustomDirectEventTypeConstants(): Map<String, Any> = mapOf(
    "topLoad" to mapOf("registrationName" to "onLoad"),
    "topError" to mapOf("registrationName" to "onError"),
  )

  private fun readStringMap(value: ReadableMap): Map<String, String> {
    val result = TreeMap<String, String>()
    val iterator = value.keySetIterator()
    while (iterator.hasNextKey()) {
      val key = iterator.nextKey()
      if (value.getType(key).name != "String") {
        throw IllegalArgumentException("publicKeys values must be strings")
      }
      result[key] = requireNotNull(value.getString(key))
    }
    return result.toMap()
  }

  @Suppress("DEPRECATION")
  private fun emitLoad(view: WebCapsuleWebView, capsuleId: String, version: String) {
    val payload = Arguments.createMap().apply {
      putString("capsuleId", capsuleId)
      putString("version", version)
    }
    (view.context as ReactContext)
      .getJSModule(RCTEventEmitter::class.java)
      .receiveEvent(view.id, "topLoad", payload)
  }

  @Suppress("DEPRECATION")
  private fun emitError(view: WebCapsuleWebView, code: String, message: String) {
    val payload = Arguments.createMap().apply {
      putString("code", code)
      putString("message", message)
    }
    (view.context as ReactContext)
      .getJSModule(RCTEventEmitter::class.java)
      .receiveEvent(view.id, "topError", payload)
  }
}
