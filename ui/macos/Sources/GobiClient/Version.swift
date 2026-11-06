import Foundation

public enum GobiClientVersion {
    /// The version of the running app: `CFBundleShortVersionString` of Gobi.app (set by make-app.sh from the VERSION file), or
    /// `dev` for a build run from the build folder.
    public static let current: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    public static let build: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
    public static let commit: String = (Bundle.main.object(forInfoDictionaryKey: "GobiGitCommit") as? String) ?? ""
}
