import Foundation
#if canImport(WebKit)
import WebKit

public enum IOSWebCapsuleContract {
    public static let componentName = "WebCapsuleView"
    public static let capsuleIDProp = "capsuleId"
    public static let bundledAssetPathProp = "bundledAssetPath"
    public static let publicKeysProp = "publicKeys"
    public static let runtimeVersionProp = "runtimeVersion"
    public static let loadEvent = "onLoad"
    public static let errorEvent = "onError"
    public static let rollbackEvent = "onRollback"
}

public enum WebCapsuleNetworkRulePolicy {
    public static let identifier = "dev.webcapsule.block-external-network.v1"
    public static let source = """
    [{"trigger":{"url-filter":"^http://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^https://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ws://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss://"},"action":{"type":"block"}}]
    """
}

public protocol WebCapsuleContentRuleCompiling {
    func compile(
        identifier: String,
        source: String,
        completion: @escaping (Result<WKContentRuleList, Error>) -> Void
    )
}

public final class WKWebCapsuleContentRuleCompiler: WebCapsuleContentRuleCompiling {
    public init() {}

    public func compile(
        identifier: String,
        source: String,
        completion: @escaping (Result<WKContentRuleList, Error>) -> Void
    ) {
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: source
        ) { list, error in
            if let list { completion(.success(list)) }
            else { completion(.failure(error ?? WebCapsuleError(code: .storageIOFailed, message: "Network rule compilation failed"))) }
        }
    }
}

public enum WebCapsuleNavigationPolicy {
    public static func allowsTopLevelNavigation(candidate: URL?, entryURL: URL) -> Bool {
        guard let candidate else { return false }
        var candidateParts = URLComponents(url: candidate, resolvingAgainstBaseURL: false)
        var entryParts = URLComponents(url: entryURL, resolvingAgainstBaseURL: false)
        guard candidateParts?.query == nil, entryParts?.query == nil else { return false }
        // Same-document fragments do not alter the resource identity.
        candidateParts?.fragment = nil
        entryParts?.fragment = nil
        return candidateParts?.url?.absoluteString == entryParts?.url?.absoluteString
    }

    public static func allowsPinnedSubframeNavigation(
        candidate: URL?,
        capsuleId: String,
        version: String
    ) -> Bool {
        guard let raw = candidate?.absoluteString else { return false }
        let prefix = PinnedResourceResolver.urlString(
            capsuleId: capsuleId,
            version: version,
            path: ""
        )
        return raw.hasPrefix(prefix) && !raw.contains("#")
    }
}

public struct SecureWebCapsuleWebView {
    public let webView: WKWebView
    public let handler: WebCapsuleURLSchemeHandler
    public let delegate: WebCapsuleWebViewDelegate
}

public enum SecureWebCapsuleWebViewFactory {
    public static func make(
        frame: CGRect,
        storageRootURL: URL,
        session: SessionDescriptor,
        compiler: WebCapsuleContentRuleCompiling = WKWebCapsuleContentRuleCompiler(),
        completion: @escaping (Result<SecureWebCapsuleWebView, WebCapsuleError>) -> Void
    ) {
        compiler.compile(
            identifier: WebCapsuleNetworkRulePolicy.identifier,
            source: WebCapsuleNetworkRulePolicy.source
        ) { result in
            DispatchQueue.main.async {
                do {
                    let rule = try result.get()
                    let made = try WebCapsuleWebViewConfiguration.make(
                        storageRootURL: storageRootURL,
                        session: session
                    )
                    let configuration = made.configuration
                    configuration.websiteDataStore = .nonPersistent()
                    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
                    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
                    configuration.allowsAirPlayForMediaPlayback = false
                    configuration.mediaTypesRequiringUserActionForPlayback = .all
                    configuration.userContentController.add(rule)
                    let delegate = WebCapsuleWebViewDelegate(
                        entryURL: made.handler.entryURL,
                        capsuleId: session.capsuleId,
                        version: session.version
                    )
                    let webView = WKWebView(frame: frame, configuration: configuration)
                    webView.navigationDelegate = delegate
                    webView.uiDelegate = delegate
                    webView.allowsBackForwardNavigationGestures = false
                    webView.allowsLinkPreview = false
                    completion(.success(SecureWebCapsuleWebView(
                        webView: webView,
                        handler: made.handler,
                        delegate: delegate
                    )))
                } catch let error as WebCapsuleError {
                    completion(.failure(error))
                } catch {
                    completion(.failure(WebCapsuleError(
                        code: .storageIOFailed,
                        message: "Secure WebView configuration failed"
                    )))
                }
            }
        }
    }
}

public final class WebCapsuleWebViewDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    public let entryURL: URL
    public let capsuleId: String
    public let version: String
    public var didLoadEntry: (() -> Void)?
    public var didFailEntry: ((WebCapsuleError) -> Void)?

    private var entryNavigation: WKNavigation?
    private var loadEmitted = false
    private var failureEmitted = false

    public init(entryURL: URL, capsuleId: String, version: String) {
        self.entryURL = entryURL
        self.capsuleId = capsuleId
        self.version = version
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame != nil,
              !navigationAction.shouldPerformDownload else {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            decisionHandler(WebCapsuleNavigationPolicy.allowsTopLevelNavigation(
                candidate: navigationAction.request.url,
                entryURL: entryURL
            ) ? .allow : .cancel)
        } else {
            decisionHandler(WebCapsuleNavigationPolicy.allowsPinnedSubframeNavigation(
                candidate: navigationAction.request.url,
                capsuleId: capsuleId,
                version: version
            ) ? .allow : .cancel)
        }
    }

    @available(iOS 15.0, *)
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard navigationResponse.canShowMIMEType else {
            decisionHandler(.cancel)
            return
        }
        let allowed: Bool
        if navigationResponse.isForMainFrame {
            allowed = WebCapsuleNavigationPolicy.allowsTopLevelNavigation(
                candidate: navigationResponse.response.url,
                entryURL: entryURL
            )
        } else {
            allowed = WebCapsuleNavigationPolicy.allowsPinnedSubframeNavigation(
                candidate: navigationResponse.response.url,
                capsuleId: capsuleId,
                version: version
            )
        }
        decisionHandler(allowed ? .allow : .cancel)
    }

    public func trackEntryNavigation(_ navigation: WKNavigation) {
        entryNavigation = navigation
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === entryNavigation,
              !loadEmitted,
              WebCapsuleNavigationPolicy.allowsTopLevelNavigation(candidate: webView.url, entryURL: entryURL) else { return }
        loadEmitted = true
        didLoadEntry?()
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        if navigation === entryNavigation { failEntry() }
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        if navigation === entryNavigation || entryNavigation == nil { failEntry() }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failEntry() }

    public func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? { nil }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) { completionHandler() }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) { completionHandler(false) }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) { completionHandler(nil) }

    @available(iOS 15.0, *)
    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) { decisionHandler(.deny) }

    private func failEntry() {
        guard !loadEmitted, !failureEmitted else { return }
        failureEmitted = true
        didFailEntry?(WebCapsuleError(code: .entryLoadFailed, message: "Pinned entry failed to load"))
    }
}
#endif
