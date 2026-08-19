package com.webcapsule.reactnative

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.net.http.SslError
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.ScriptHandler
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.webcapsule.reactnative.runtime.AndroidRuntimeCoordinator
import com.webcapsule.reactnative.runtime.HandlerHealthScheduler
import com.webcapsule.reactnative.runtime.TrialOutcome
import com.webcapsule.reactnative.runtime.HealthCoordinator
import com.webcapsule.reactnative.runtime.PercentCodec
import com.webcapsule.reactnative.runtime.PinnedRequestHandler
import com.webcapsule.reactnative.runtime.SessionDescriptor
import com.webcapsule.reactnative.runtime.StorageLayout
import com.webcapsule.reactnative.runtime.WebCapsuleErrorCode
import com.webcapsule.reactnative.runtime.WebCapsuleException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.io.File
import java.util.concurrent.atomic.AtomicLong

internal fun interface DeniedRequestObserver { fun denied(uri: Uri, mainFrame: Boolean) }

class WebCapsuleWebView internal constructor(
  context: Context,
  private val storageRootOverride: File?,
  private val deniedRequestObserver: DeniedRequestObserver?,
) : WebView(context) {
  constructor(context: Context) : this(context, null, null)

  private val executor = Executors.newSingleThreadExecutor()
  private val mainHandler = Handler(Looper.getMainLooper())
  private val generation = AtomicLong()
  private var attachedConfig: WebCapsuleConfig? = null
  private var health: HealthCoordinator? = null
  private var bootstrap: ScriptHandler? = null
  private var bridgeInstalled = false
  private var activeSession: SessionDescriptor? = null
  var errorListener: ((String, String) -> Unit)? = null
  var loadListener: ((String, String) -> Unit)? = null
  var rollbackListener: ((String, String, String?, String, String) -> Unit)? = null

  init {
    settings.javaScriptEnabled = true
    settings.domStorageEnabled = true
    settings.allowFileAccess = false
    settings.allowContentAccess = false
    settings.allowFileAccessFromFileURLs = false
    settings.allowUniversalAccessFromFileURLs = false
    settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
    settings.setSupportMultipleWindows(false)
    settings.cacheMode = WebSettings.LOAD_NO_CACHE
    settings.javaScriptCanOpenWindowsAutomatically = false
    CookieManager.getInstance().setAcceptCookie(false)
    CookieManager.getInstance().setAcceptThirdPartyCookies(this, false)
    settings.safeBrowsingEnabled = true
    setDownloadListener { _, _, _, _, _ -> failSession(WebCapsuleErrorCode.STABILIZATION_FAILED, "Downloads are denied") }
    webChromeClient = object : WebChromeClient() {
      override fun onPermissionRequest(request: PermissionRequest) = request.deny()
      override fun onGeolocationPermissionsShowPrompt(origin: String?, callback: android.webkit.GeolocationPermissions.Callback) = callback.invoke(origin, false, false)
      override fun onCreateWindow(view: WebView?, isDialog: Boolean, isUserGesture: Boolean, resultMsg: android.os.Message?) = false
    }
  }

  fun attachRuntime(config: WebCapsuleConfig) {
    if (config == attachedConfig) return
    clearSession()
    attachedConfig = config
    val token = generation.incrementAndGet()
    executor.execute {
      try {
        val session = AndroidRuntimeCoordinator(context.applicationContext, storageRootOverride).ensureSession(config)
        mainHandler.post {
          if (token == generation.get()) attachSession(session)
          else session.trialToken?.release()
        }
      } catch (error: Throwable) {
        val failure = error as? WebCapsuleException
        mainHandler.post {
          if (token == generation.get()) emitError(failure?.code?.name ?: WebCapsuleErrorCode.STORAGE_IO_FAILED.name, error.message ?: "Runtime preparation failed")
        }
      }
    }
  }

  private fun attachSession(session: SessionDescriptor) {
    activeSession = session
    val token = generation.get()
    val terminal = AtomicBoolean()
    val runtime = AndroidRuntimeCoordinator(context.applicationContext, storageRootOverride)
    val outcomes = runtime.outcomeCoordinator(requireNotNull(attachedConfig))
    val required = listOf(WebViewFeature.WEB_MESSAGE_LISTENER, WebViewFeature.DOCUMENT_START_SCRIPT)
    if (required.any { !WebViewFeature.isFeatureSupported(it) }) {
      val outcome = try { outcomes.recordExplicitFailure(session) } catch (error: WebCapsuleException) {
        session.trialToken?.release()
        if (terminal.compareAndSet(false, true)) emitError(error.code.name, error.message ?: "Trial outcome failed")
        return
      }
      session.trialToken?.release()
      if (terminal.compareAndSet(false, true)) {
        val code = WebCapsuleErrorCode.READY_MESSAGE_INVALID.name
        emitError(code, "Required secure WebView bridge features are unavailable")
        emitRollback(session, outcome, code)
      }
      return
    }
    val storageLayout = storageRootOverride?.let(::StorageLayout)
      ?: StorageLayout.forNoBackupFilesDir(context.noBackupFilesDir)
    health = HealthCoordinator(
      session,
      HandlerHealthScheduler(mainHandler),
      { outcomes.commitHealthy(session) },
      {
        session.trialToken?.release()
        if (token == generation.get() && terminal.compareAndSet(false, true)) loadListener?.invoke(session.capsuleId, session.version)
      },
      { error ->
        val outcome = try { outcomes.recordExplicitFailure(session) } catch (outcomeError: WebCapsuleException) {
          session.trialToken?.release()
          if (token == generation.get() && terminal.compareAndSet(false, true)) emitError(outcomeError.code.name, outcomeError.message ?: "Trial outcome failed")
          return@HealthCoordinator
        }
        session.trialToken?.release()
        if (token == generation.get() && terminal.compareAndSet(false, true)) {
          emitError(error.code.name, error.message ?: "Session failed")
          emitRollback(session, outcome, error.code.name)
        }
      },
    )
    val bootstrapJson = "{\"capsuleId\":${json(session.capsuleId)},\"protocolVersion\":1,\"sessionId\":${json(session.sessionId)},\"type\":\"ready\",\"version\":${json(session.version)}}"
    bootstrap = WebViewCompat.addDocumentStartJavaScript(
      this,
      "Object.defineProperty(globalThis,'__WEBCAPSULE_SESSION__',{value:Object.freeze($bootstrapJson),writable:false,configurable:false,enumerable:false});",
      setOf(HealthCoordinator.ORIGIN),
    )
    WebViewCompat.addWebMessageListener(this, BRIDGE_NAME, setOf(HealthCoordinator.ORIGIN)) { _, message: WebMessageCompat, sourceOrigin: Uri, isMainFrame: Boolean, _: JavaScriptReplyProxy ->
      if (token != generation.get()) return@addWebMessageListener
      val data = message.data
      if (data == null) {
        health?.invalidReady("Ready message data is missing")
        return@addWebMessageListener
      }
      health?.ready(data, sourceOrigin.toString().removeSuffix("/"), isMainFrame)
    }
    bridgeInstalled = true

    val fatalSent = AtomicBoolean()
    val handler = PinnedRequestHandler(storageLayout, session) { error ->
      if (fatalSent.compareAndSet(false, true)) post { failSession(WebCapsuleErrorCode.STABILIZATION_FAILED, error.message ?: "Resource failure") }
    }
    val assetLoader = WebViewAssetLoader.Builder().setDomain("webcapsule.local").addPathHandler("/", handler).build()
    val entryUrl = "${HealthCoordinator.ORIGIN}/${PercentCodec.encode(session.capsuleId)}/${PercentCodec.encode(session.version)}/${session.entry.split('/').joinToString("/") { PercentCodec.encode(it) }}"
    webViewClient = object : WebViewClient() {
      override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest): WebResourceResponse? = try {
        handler.validate(request.url)
        assetLoader.shouldInterceptRequest(request.url) ?: deniedResponse()
      } catch (error: WebCapsuleException) {
        deniedRequestObserver?.denied(request.url, request.isForMainFrame)
        if (error.code == WebCapsuleErrorCode.STORAGE_INVARIANT_VIOLATION && fatalSent.compareAndSet(false, true)) post { failSession(WebCapsuleErrorCode.STABILIZATION_FAILED, error.message ?: "Resource failure") }
        deniedResponse()
      }

      override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest): Boolean {
        val denied = request.url.toString() != entryUrl
        if (denied) {
          deniedRequestObserver?.denied(request.url, request.isForMainFrame)
          failSession(WebCapsuleErrorCode.STABILIZATION_FAILED, "Navigation away from the pinned entry is denied")
        }
        return denied
      }

      override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
        if (url != entryUrl) failSession(WebCapsuleErrorCode.STABILIZATION_FAILED, "Unexpected main-frame navigation")
      }

      override fun onPageFinished(view: WebView?, url: String?) {
        if (url == entryUrl) health?.entryLoaded()
        else failSession(WebCapsuleErrorCode.ENTRY_LOAD_FAILED, "Entry URL did not finish")
      }

      override fun onReceivedError(view: WebView?, request: WebResourceRequest, error: WebResourceError?) {
        if (request.isForMainFrame) health?.entryFailed("Entry document failed to load")
      }

      override fun onReceivedHttpError(view: WebView?, request: WebResourceRequest, errorResponse: WebResourceResponse?) {
        if (request.isForMainFrame) health?.entryFailed("Entry document returned an HTTP error")
      }

      override fun onReceivedSslError(view: WebView?, handler: SslErrorHandler, error: SslError?) {
        handler.cancel()
        health?.entryFailed("Entry document encountered an SSL error")
      }

      override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
        failSession(WebCapsuleErrorCode.STABILIZATION_FAILED, "WebView render process exited")
        return true
      }
    }
    loadUrl(entryUrl)
  }

  private fun failSession(code: WebCapsuleErrorCode, message: String) {
    when (code) {
      WebCapsuleErrorCode.ENTRY_LOAD_FAILED -> health?.entryFailed(message)
      WebCapsuleErrorCode.READY_MESSAGE_INVALID -> health?.invalidReady(message)
      else -> health?.fatal(message)
    }
  }

  fun clearRuntime() {
    attachedConfig = null
    generation.incrementAndGet()
    clearSession()
    stopLoading()
    loadUrl("about:blank")
  }

  private fun clearSession() {
    health?.close()
    health = null
    activeSession?.trialToken?.release()
    activeSession = null
    bootstrap?.remove()
    bootstrap = null
    if (bridgeInstalled) WebViewCompat.removeWebMessageListener(this, BRIDGE_NAME)
    bridgeInstalled = false
  }

  private fun deniedResponse() = WebResourceResponse("text/plain", null, 404, "Not Found", emptyMap(), java.io.InputStream.nullInputStream())
  private fun emitRollback(session: SessionDescriptor, outcome: TrialOutcome, reason: String) {
    when (outcome) {
      is TrialOutcome.RolledBack -> rollbackListener?.invoke(session.capsuleId, outcome.failedVersion, outcome.restoredVersion, reason, outcome.registry.generation.toString())
      is TrialOutcome.BundledFallback -> rollbackListener?.invoke(session.capsuleId, outcome.failedVersion, outcome.bundledVersion, reason, outcome.registry.generation.toString())
      is TrialOutcome.Terminal -> rollbackListener?.invoke(session.capsuleId, outcome.failedVersion, null, WebCapsuleErrorCode.NO_RUNNABLE_VERSION.name, session.registryGeneration.toString())
      else -> Unit
    }
  }
  private fun emitError(code: String, message: String) { errorListener?.invoke(code, message) }
  private fun json(value: String): String = org.json.JSONObject.quote(value)

  override fun onDetachedFromWindow() {
    clearSession()
    generation.incrementAndGet()
    super.onDetachedFromWindow()
  }

  override fun destroy() {
    clearSession()
    generation.incrementAndGet()
    executor.shutdownNow()
    super.destroy()
  }

  companion object { private const val BRIDGE_NAME = "WebCapsuleBridge" }
}
