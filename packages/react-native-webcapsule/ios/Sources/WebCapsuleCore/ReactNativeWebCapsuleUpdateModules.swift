#if canImport(React) && canImport(UIKit)
import Darwin
import Foundation
import React
import UIKit

private enum ReactNativeWebCapsuleOptions {
    static func config(
        _ options: NSDictionary,
        additionalFields: Set<String> = []
    ) throws -> WebCapsuleConfig {
        let expected = Set(["capsuleId", "bundledAssetPath", "publicKeys", "runtimeVersion"])
            .union(additionalFields)
        guard Set(options.allKeys.compactMap { $0 as? String }) == expected,
              options.allKeys.count == expected.count else {
            throw WebCapsuleError(code: .invalidArgument, message: "WebCapsule option fields differ")
        }
        func string(_ key: String) throws -> String {
            guard let value = options[key] as? String else {
                throw WebCapsuleError(code: .invalidArgument, message: "\(key) must be a string")
            }
            return value
        }
        guard let rawKeys = options["publicKeys"] as? NSDictionary else {
            throw WebCapsuleError(code: .invalidArgument, message: "publicKeys must be an object")
        }
        var publicKeys: [String: String] = [:]
        for (key, value) in rawKeys {
            guard let key = key as? String, let value = value as? String else {
                throw WebCapsuleError(code: .invalidArgument, message: "publicKeys entries must be strings")
            }
            publicKeys[key] = value
        }
        let config = WebCapsuleConfig(
            capsuleId: try string("capsuleId"),
            bundledAssetPath: try string("bundledAssetPath"),
            publicKeys: publicKeys,
            runtimeVersion: try string("runtimeVersion")
        )
        do {
            try WebCapsuleConfigValidator.validate(config)
        } catch let error as WebCapsuleError {
            throw WebCapsuleError(code: .invalidArgument, message: error.message)
        } catch {
            throw WebCapsuleError(code: .invalidArgument, message: "WebCapsule config is invalid")
        }
        return config
    }

    static func environment(config: WebCapsuleConfig) throws -> (archive: URL, storage: URL) {
        guard let resources = Bundle.main.resourceURL else {
            throw WebCapsuleError(
                code: .bundledCapsuleUnavailable,
                message: "Application bundle resources are unavailable"
            )
        }
        let archive = try IOSBundleAssetResolver.resolve(
            path: config.bundledAssetPath,
            resourceRootURL: resources
        )
        let support = try IOSRuntimeStorageRoot.applicationSupportBase()
        let storage = try IOSRuntimeStorageRoot.prepare(applicationSupportURL: support)
        return (archive, storage)
    }

    static func trustedCacheBase() throws -> URL {
        let caches: URL
        do {
            caches = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw WebCapsuleError(code: .storageIOFailed, message: "Caches directory is unavailable")
        }
        return caches
    }

    static func reject(
        _ error: Error,
        fallbackCode: WebCapsuleErrorCode,
        fallbackMessage: String,
        using reject: RCTPromiseRejectBlock
    ) {
        let normalized = error as? WebCapsuleError
            ?? WebCapsuleError(code: fallbackCode, message: fallbackMessage)
        reject(normalized.code.rawValue, normalized.message, normalized as NSError)
    }
}

private func reactMethod(
    _ objcName: StaticString,
    moduleClass: AnyClass
) -> RCTModuleMethod {
    let info = UnsafeMutablePointer<RCTMethodInfo>.allocate(capacity: 1)
    info.initialize(to: RCTMethodInfo(
        jsName: strdup(""),
        objcName: strdup(objcName.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }),
        isSync: false
    ))
    // RCTModuleMethod retains the method descriptor for the process lifetime.
    return RCTModuleMethod(exportedMethod: info, moduleClass: moduleClass)
}

@objc(WebCapsuleUpdate)
final class WebCapsuleUpdateModuleIOS: NSObject, RCTBridgeModule {
    private let queue = DispatchQueue(label: "dev.webcapsule.update")

    @objc static func moduleName() -> String! { "WebCapsuleUpdate" }
    @objc static func requiresMainQueueSetup() -> Bool { false }

    @objc func methodsToExport() -> [RCTBridgeMethod]! {
        [reactMethod(
            "installWebCapsuleUpdate:(NSDictionary *)options resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject",
            moduleClass: Self.self
        )]
    }

    @objc func installWebCapsuleUpdate(
        _ options: NSDictionary,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        queue.async {
            do {
                let config = try ReactNativeWebCapsuleOptions.config(
                    options,
                    additionalFields: ["indexUrl", "channel"]
                )
                guard let indexURLString = options["indexUrl"] as? String,
                      let channel = options["channel"] as? String else {
                    throw WebCapsuleError(code: .invalidArgument, message: "Update options must be strings")
                }
                let indexURL = try UpdateIndexVerifier.strictHTTPS(indexURLString)
                try UpdateIndexVerifier.validateChannel(channel)
                let environment = try ReactNativeWebCapsuleOptions.environment(config: config)
                let coordinator = IOSUpdateCoordinator(
                    storageRootURL: environment.storage,
                    trustedCacheBaseURL: try ReactNativeWebCapsuleOptions.trustedCacheBase()
                )
                let result = try coordinator.install(IOSUpdateRequest(
                    config: config,
                    bundledArchiveURL: environment.archive,
                    indexURL: indexURL,
                    channel: channel
                ))
                switch result {
                case let .installed(previous, current, highest, generation):
                    resolve([
                        "status": "installed",
                        "previousVersion": previous,
                        "currentVersion": current,
                        "highestSeenVersion": highest,
                        "generation": String(generation),
                    ])
                case let .upToDate(current, highest, generation):
                    resolve([
                        "status": "up-to-date",
                        "currentVersion": current,
                        "highestSeenVersion": highest,
                        "generation": String(generation),
                    ])
                }
            } catch {
                ReactNativeWebCapsuleOptions.reject(
                    error,
                    fallbackCode: .installFailed,
                    fallbackMessage: "Update installation failed",
                    using: reject
                )
            }
        }
    }
}

@objc(WebCapsuleState)
final class WebCapsuleStateModuleIOS: NSObject, RCTBridgeModule {
    private let queue = DispatchQueue(label: "dev.webcapsule.state")

    @objc static func moduleName() -> String! { "WebCapsuleState" }
    @objc static func requiresMainQueueSetup() -> Bool { false }

    @objc func methodsToExport() -> [RCTBridgeMethod]! {
        [reactMethod(
            "getWebCapsuleRuntimeState:(NSDictionary *)options resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject",
            moduleClass: Self.self
        )]
    }

    @objc func getWebCapsuleRuntimeState(
        _ options: NSDictionary,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        queue.async {
            do {
                let config = try ReactNativeWebCapsuleOptions.config(options)
                let environment = try ReactNativeWebCapsuleOptions.environment(config: config)
                let runtime = try IOSRuntimeBootstrap(storageRootURL: environment.storage)
                let registry = try runtime.ensureState(
                    bundledArchiveURL: environment.archive,
                    request: CapsuleVerificationRequest(
                        expectedCapsuleId: config.capsuleId,
                        runtimeVersion: config.runtimeVersion,
                        publicKeys: config.publicKeys
                    )
                )
                let pending: Any = registry.pending.map { value -> Any in
                    ["version": value.version, "attempts": String(value.attempts)]
                } ?? NSNull()
                let previousVersion: Any = registry.previous.map { $0.version as Any } ?? NSNull()
                resolve([
                    "capsuleId": registry.capsuleId,
                    "activeVersion": registry.active.version,
                    "activeHealthy": registry.active.healthy,
                    "previousVersion": previousVersion,
                    "pending": pending,
                    "highestSeenVersion": registry.highestSeenVersion,
                    "blockedVersions": registry.blockedVersions,
                    "generation": String(registry.generation),
                ])
            } catch {
                ReactNativeWebCapsuleOptions.reject(
                    error,
                    fallbackCode: .storageIOFailed,
                    fallbackMessage: "Runtime state cannot be read",
                    using: reject
                )
            }
        }
    }
}
#endif
