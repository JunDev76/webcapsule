import Foundation

enum CapsulePathValidator {
    static let maximumFileCount = 10_000

    static func validate(_ value: String) throws {
        let normalized = value.precomposedStringWithCanonicalMapping
        let invalid = value.isEmpty
            || value.hasPrefix("/")
            || value.hasSuffix("/")
            || value.contains("\\")
            || value.unicodeScalars.contains { $0.value <= 0x1F || $0.value == 0x7F }
            || containsEncodedSeparator(value.utf8)
            || !normalized.utf8.elementsEqual(value.utf8)
            || value.split(separator: "/", omittingEmptySubsequences: false).contains {
                $0.isEmpty || $0 == "." || $0 == ".."
            }
        guard !invalid else {
            throw WebCapsuleError(code: .invalidPath, message: "Unsafe capsule path")
        }
    }

    static func validateSet(_ paths: [String]) throws {
        guard paths.count <= maximumFileCount else {
            throw WebCapsuleError(code: .limitExceeded, message: "File count limit exceeded")
        }
        var normalizedPaths: [Data: String] = [:]
        var exactPaths = Set<Data>()
        var foldedPaths: [Data: String] = [:]

        for path in paths {
            let normalized = path.precomposedStringWithCanonicalMapping
            let normalizedBytes = Data(normalized.utf8)
            if let existing = normalizedPaths[normalizedBytes], !existing.utf8.elementsEqual(path.utf8) {
                throw WebCapsuleError(code: .unicodeCollision, message: "Unicode-normalized path collision")
            }
            normalizedPaths[normalizedBytes] = path

            try validate(path)
            guard exactPaths.insert(Data(path.utf8)).inserted else {
                throw WebCapsuleError(code: .duplicatePath, message: "Duplicate capsule path")
            }

            let folded = Data(path.utf8.map { byte in
                (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
            })
            if let existing = foldedPaths[folded], !existing.utf8.elementsEqual(path.utf8) {
                throw WebCapsuleError(code: .caseCollision, message: "ASCII case-insensitive path collision")
            }
            foldedPaths[folded] = path
        }
    }

    static func validateAscendingUTF8Order(_ paths: [String]) throws {
        guard paths.count > 1 else { return }
        for index in 1..<paths.count {
            let previous = Array(paths[index - 1].utf8)
            let current = Array(paths[index].utf8)
            guard previous.lexicographicallyPrecedes(current) else {
                throw WebCapsuleError(code: .invalidOrder, message: "Manifest files must be in ascending UTF-8 byte order")
            }
        }
    }

    private static func containsEncodedSeparator(_ bytes: String.UTF8View) -> Bool {
        let values = Array(bytes)
        guard values.count >= 3 else { return false }
        for index in 0...(values.count - 3) where values[index] == 0x25 {
            let first = values[index + 1] | 0x20
            let second = values[index + 2] | 0x20
            if (first == 0x32 && second == 0x66) || (first == 0x35 && second == 0x63) {
                return true
            }
        }
        return false
    }
}
