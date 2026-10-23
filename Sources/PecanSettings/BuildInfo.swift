import Foundation

/// Identifies a Pecan build. The Makefile embeds these values in the executable's
/// `__TEXT,__info_plist` section; a plain `swift build` has none and is an unversioned dev build.
public struct BuildInfo: Codable, Sendable, Equatable, CustomStringConvertible {
    public enum Channel: String, Codable, Sendable {
        /// Local `make` builds, numbered by a per-user counter.
        case dev
        /// CI builds, numbered by the CI run number.
        case release
    }

    /// Semantic version from the `VERSION` file.
    public var version: String
    /// Monotonically increasing within a channel. 0 means unversioned.
    public var build: Int
    public var channel: Channel
    public var gitHash: String?

    public init(version: String, build: Int, channel: Channel, gitHash: String? = nil) {
        self.version = version
        self.build = build
        self.channel = channel
        self.gitHash = gitHash
    }

    init(infoDictionary: [String: Any]?) {
        let info = infoDictionary ?? [:]
        version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        build = (info["CFBundleVersion"] as? String).flatMap { Int($0) } ?? 0
        channel = (info["PecanChannel"] as? String).flatMap(Channel.init(rawValue:)) ?? .dev
        gitHash = info["PecanGitHash"] as? String
    }

    public static let current = BuildInfo(infoDictionary: Bundle.main.infoDictionary)

    public var isVersioned: Bool { build > 0 }

    /// Whether a client of this build should replace a server running `other`.
    ///
    /// Only versioned builds in the same channel are comparable, so dev builds never replace
    /// release servers (or vice versa) and unversioned builds never trigger a restart.
    public func supersedes(_ other: BuildInfo) -> Bool {
        guard isVersioned, other.isVersioned, channel == other.channel else { return false }
        switch channel {
        case .dev:
            return build > other.build
        case .release:
            switch version.compare(other.version, options: .numeric) {
            case .orderedDescending: return true
            case .orderedAscending: return false
            case .orderedSame: return build > other.build
            }
        }
    }

    public var description: String {
        guard isVersioned else { return "\(version) (unversioned \(channel.rawValue) build)" }
        let hash = gitHash.map { ", \($0)" } ?? ""
        return "\(version) (\(channel.rawValue) build \(build)\(hash))"
    }
}
