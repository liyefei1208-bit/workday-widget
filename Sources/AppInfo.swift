import Foundation

/// Authorship and version metadata, read from the bundle where possible so
/// `Info.plist` stays the single source of truth.
enum AppInfo {
    static let author = "yefei.li"
    static let displayName = "工作日"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
            ?? "© 2026 \(author)"
    }

    /// Short credit used as the on-widget watermark.
    static let watermark = "yefei.li"
}
