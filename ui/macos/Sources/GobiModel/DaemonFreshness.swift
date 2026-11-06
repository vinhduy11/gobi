// Whether a running gobid is older than the gobid binary the app carries. The daemon outlives the app that started it, so after an
// update the new app would otherwise keep talking to the old daemon (and miss its fixes).

public enum DaemonFreshness {
    /// `startedAt` is the daemon's start time and `binaryModified` the time the gobid file was written, both in unix seconds.
    /// A start time of 0 means the daemon did not say, and it is left alone.
    public static func isStale(startedAt: Int, binaryModified: Int) -> Bool {
        startedAt > 0 && binaryModified > startedAt
    }
}
