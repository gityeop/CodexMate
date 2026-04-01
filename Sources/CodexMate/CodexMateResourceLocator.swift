import Foundation

private final class CodexMateBundleFinder {}

enum CodexMateResourceLocator {
    private static let resourceBundleName = "CodexMate_CodexMate.bundle"

    static let bundle: Bundle? = {
        let candidates = candidateURLs()

        for url in candidates {
            if let bundle = Bundle(url: url) {
                DebugTraceLogger.log("resource bundle resolved path=\(bundle.bundleURL.path)")
                return bundle
            }
        }

        let searchedPaths = candidates.map(\.path).joined(separator: ", ")
        DebugTraceLogger.log("resource bundle missing searched=[\(searchedPaths)]")
        return nil
    }()

    private static func candidateURLs() -> [URL] {
        let mainBundle = Bundle.main
        let markerBundle = Bundle(for: CodexMateBundleFinder.self)

        return unique([
            mainBundle.resourceURL?.appendingPathComponent(resourceBundleName, isDirectory: true),
            mainBundle.bundleURL.appendingPathComponent(resourceBundleName, isDirectory: true),
            mainBundle.bundleURL.deletingLastPathComponent().appendingPathComponent(resourceBundleName, isDirectory: true),
            markerBundle.resourceURL?.appendingPathComponent(resourceBundleName, isDirectory: true),
            markerBundle.bundleURL.appendingPathComponent(resourceBundleName, isDirectory: true),
            markerBundle.bundleURL.deletingLastPathComponent().appendingPathComponent(resourceBundleName, isDirectory: true),
        ])
    }

    private static func unique(_ urls: [URL?]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []

        for url in urls.compactMap({ $0?.standardizedFileURL }) {
            let path = url.path
            if seen.insert(path).inserted {
                result.append(url)
            }
        }

        return result
    }
}
