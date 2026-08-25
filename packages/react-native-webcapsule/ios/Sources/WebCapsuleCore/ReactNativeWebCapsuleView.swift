#if canImport(React) && canImport(UIKit) && canImport(WebKit)
import Foundation
import React
import UIKit
import WebKit

@objc(WebCapsuleNativeView)
final class WebCapsuleNativeView: UIView {
    @objc var capsuleId: NSString?
    @objc var bundledAssetPath: NSString?
    @objc var publicKeys: NSDictionary?
    @objc var runtimeVersion: NSString?
    @objc var onLoad: RCTDirectEventBlock?
    @objc var onError: RCTDirectEventBlock?
    @objc var onRollback: RCTDirectEventBlock?

    private var lifecycle: IOSWebCapsuleLifecycleController?
    private var secureView: SecureWebCapsuleWebView?
    private var viewGeneration: UInt64 = 0
    private var disposed = false
    private var wasMounted = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
    }

    @objc override func didSetProps(_ changedProps: [String]) {
        super.didSetProps(changedProps)
        guard !disposed else { return }
        applyProps()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        secureView?.webView.frame = bounds
    }

    @objc func invalidate() {
        guard !disposed else { return }
        disposed = true
        viewGeneration &+= 1
        lifecycle?.invalidate()
        lifecycle = nil
        detachWebView()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            wasMounted = true
        } else if wasMounted {
            invalidate()
        }
    }

    private func applyProps() {
        guard let capsuleId = capsuleId as String?,
              let bundledAssetPath = bundledAssetPath as String?,
              let runtimeVersion = runtimeVersion as String?,
              let publicKeys else {
            replaceRuntime()
            emitError(WebCapsuleError(code: .invalidArgument, message: "Missing required WebCapsuleView props"))
            return
        }
        var keys: [String: String] = [:]
        for (key, value) in publicKeys {
            guard let key = key as? String, let value = value as? String else {
                replaceRuntime()
                emitError(WebCapsuleError(code: .invalidArgument, message: "publicKeys must be a string record"))
                return
            }
            keys[key] = value
        }
        let config = WebCapsuleConfig(
            capsuleId: capsuleId,
            bundledAssetPath: bundledAssetPath,
            publicKeys: keys,
            runtimeVersion: runtimeVersion
        )
        do { try WebCapsuleConfigValidator.validate(config) }
        catch { replaceRuntime(); emitError(normalize(error)); return }

        if lifecycle == nil {
            guard let resources = Bundle.main.resourceURL else {
                emitError(WebCapsuleError(code: .bundledCapsuleUnavailable, message: "Application bundle resources are unavailable"))
                return
            }
            do {
                let support = try IOSRuntimeStorageRoot.applicationSupportBase()
                lifecycle = IOSWebCapsuleLifecycleController { requested in
                    try IOSRuntimePreparer.prepare(
                        config: requested,
                        bundleResourceRootURL: resources,
                        applicationSupportURL: support
                    )
                }
            } catch { emitError(normalize(error)); return }
        }
        let token = viewGeneration &+ 1
        let changed = lifecycle?.apply(config: config, onReady: { [weak self] prepared in
            DispatchQueue.main.async {
                guard let self, self.viewGeneration == token else { return }
                self.attach(prepared, token: token)
            }
        }, onError: { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.viewGeneration == token else { return }
                self.emitError(error)
            }
        }) ?? false
        if changed {
            viewGeneration = token
            detachWebView()
        }
    }

    private func attach(_ prepared: IOSPreparedRuntimeSession, token: UInt64) {
        guard !disposed, token == viewGeneration else {
            prepared.session.releaseTrial()
            return
        }
        detachWebView()
        SecureWebCapsuleWebViewFactory.make(
            frame: bounds,
            storageRootURL: prepared.storageRootURL,
            session: prepared.session
        ) { [weak self] result in
            guard let self, !self.disposed, token == self.viewGeneration else {
                if case let .success(made) = result { made.handler.invalidate(); made.webView.stopLoading() }
                return
            }
            switch result {
            case let .failure(error):
                self.lifecycle?.invalidate()
                self.lifecycle = nil
                self.emitError(error)
            case let .success(made):
                made.delegate.didLoadEntry = { [weak self] in
                    self?.onLoad?(["capsuleId": prepared.session.capsuleId, "version": prepared.session.version])
                }
                made.delegate.didFailEntry = { [weak self] error in
                    guard let self else { return }
                    self.lifecycle?.invalidate()
                    self.lifecycle = nil
                    self.detachWebView()
                    self.emitError(error)
                }
                self.secureView = made
                self.addSubview(made.webView)
                made.webView.frame = self.bounds
                guard let navigation = made.webView.load(URLRequest(url: made.handler.entryURL)) else {
                    self.lifecycle?.invalidate()
                    self.lifecycle = nil
                    self.detachWebView()
                    self.emitError(WebCapsuleError(
                        code: .entryLoadFailed,
                        message: "Pinned entry could not start loading"
                    ))
                    return
                }
                made.delegate.trackEntryNavigation(navigation)
            }
        }
    }

    private func replaceRuntime() {
        viewGeneration &+= 1
        lifecycle?.invalidate()
        lifecycle = nil
        detachWebView()
    }

    private func detachWebView() {
        secureView?.webView.stopLoading()
        secureView?.webView.navigationDelegate = nil
        secureView?.webView.uiDelegate = nil
        secureView?.handler.invalidate()
        secureView?.webView.removeFromSuperview()
        secureView = nil
    }

    private func emitError(_ error: WebCapsuleError) {
        guard !disposed else { return }
        onError?(["code": error.code.rawValue, "message": error.message])
    }

    private func normalize(_ error: Error) -> WebCapsuleError {
        error as? WebCapsuleError
            ?? WebCapsuleError(code: .storageIOFailed, message: "iOS WebCapsuleView failed")
    }

    deinit { invalidate() }
}

@objc(WebCapsuleViewManager)
final class WebCapsuleViewManager: RCTViewManager {
    @objc override class func moduleName() -> String! { IOSWebCapsuleContract.componentName }
    @objc override class func requiresMainQueueSetup() -> Bool { true }
    @objc override func view() -> UIView! { WebCapsuleNativeView() }

    @objc class func propConfig_capsuleId() -> [String] { ["NSString"] }
    @objc class func propConfig_bundledAssetPath() -> [String] { ["NSString"] }
    @objc class func propConfig_publicKeys() -> [String] { ["NSDictionary"] }
    @objc class func propConfig_runtimeVersion() -> [String] { ["NSString"] }
    @objc class func propConfig_onLoad() -> [String] { ["RCTDirectEventBlock"] }
    @objc class func propConfig_onError() -> [String] { ["RCTDirectEventBlock"] }
    @objc class func propConfig_onRollback() -> [String] { ["RCTDirectEventBlock"] }
}

@_silgen_name("RCTRegisterModule")
private func registerReactModule(_ moduleClass: AnyClass)

/// CocoaPods preserves this C entry point and invokes it as a Mach-O initializer.
/// This is the Swift-only equivalent of React Native's `RCT_EXTERN_MODULE` shim.
@_cdecl("WebCapsuleRegisterReactNativeModule")
public func WebCapsuleRegisterReactNativeModule() {
    registerReactModule(WebCapsuleViewManager.self)
}

#if compiler(>=6.2)
@used @section("__DATA,__mod_init_func")
#else
@_used @_section("__DATA,__mod_init_func")
#endif
private var webCapsuleReactNativeInitializer: @convention(c) () -> Void =
    WebCapsuleRegisterReactNativeModule
#endif
