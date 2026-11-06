// The app's version, in Semantic Versioning (semver.org): MAJOR.MINOR.PATCH with an optional `-prerelease` such as `alpha.1`.
// Strings in and out; the build scripts and the About panel use it.

public struct AppVersion: Equatable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// The part after `-`, for example `alpha.1`; nil for a release.
    public let prerelease: String?

    public var isPrerelease: Bool { prerelease != nil }
    public var text: String { "\(major).\(minor).\(patch)" + (prerelease.map { "-" + $0 } ?? "") }

    public static func parse(_ text: String) -> AppVersion? {
        var core = Substring(text)
        var prerelease: String?
        if let dash = text.firstIndex(of: "-") {
            core = text[text.startIndex ..< dash]
            let rest = String(text[text.index(after: dash)...])
            guard isValid(prerelease: rest) else { return nil }
            prerelease = rest
        }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { return nil }
        var values: [Int] = []
        for part in numbers {
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }), part == "0" || part.first != "0", let value = Int(part) else { return nil }
            values.append(value)
        }
        return AppVersion(major: values[0], minor: values[1], patch: values[2], prerelease: prerelease)
    }

    private static func isValid(prerelease: String) -> Bool {
        guard !prerelease.isEmpty else { return false }
        return prerelease.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || $0 == "-" }
        }
    }

    /// Semantic Versioning precedence: the numbers first; a prerelease is lower than its release; prerelease parts compare one by one,
    /// numbers as numbers (alpha.2 < alpha.10) and before words.
    public static func < (left: AppVersion, right: AppVersion) -> Bool {
        if left.major != right.major { return left.major < right.major }
        if left.minor != right.minor { return left.minor < right.minor }
        if left.patch != right.patch { return left.patch < right.patch }
        switch (left.prerelease, right.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case (let a?, let b?): return comparePrerelease(a, b) < 0
        }
    }

    private static func comparePrerelease(_ a: String, _ b: String) -> Int {
        let left = a.split(separator: "."), right = b.split(separator: ".")
        for (x, y) in zip(left, right) {
            let numbers = (Int(x), Int(y))
            switch numbers {
            case let (p?, q?): if p != q { return p < q ? -1 : 1 }
            case (_?, nil): return -1
            case (nil, _?): return 1
            case (nil, nil): if x != y { return x < y ? -1 : 1 }
            }
        }
        return left.count == right.count ? 0 : (left.count < right.count ? -1 : 1)
    }

    /// The line for the About panel and bug reports: `0.1.0-alpha.1 (build 123, abc1234)`; parts that are empty are left out.
    public static func display(version: String, build: String, commit: String) -> String {
        var details: [String] = []
        if !build.isEmpty { details.append("build \(build)") }
        if !commit.isEmpty { details.append(commit) }
        return details.isEmpty ? version : "\(version) (\(details.joined(separator: ", ")))"
    }
}
