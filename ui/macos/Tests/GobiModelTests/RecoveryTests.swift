import Testing
@testable import GobiModel

struct RecoveryTests {
    private let sig = FileSignature(modified: 1_762_400_000.123456, size: 42)

    @Test func aRecordSurvivesEncodingWithItsText() {
        let record = RecoveryRecord(path: "/p/a.go", signature: sig, text: "package main\n\n// héllo\nline=3\n")
        #expect(RecoveryRecord.decode(record.encoded()) == record)
    }

    @Test func emptyTextAndMissingSignatureRoundTrip() {
        let record = RecoveryRecord(path: "/p/a.go", signature: nil, text: "")
        #expect(RecoveryRecord.decode(record.encoded()) == record)
    }

    @Test func garbageDoesNotDecode() {
        #expect(RecoveryRecord.decode("") == nil)
        #expect(RecoveryRecord.decode("not a record\n") == nil)
    }

    @Test func whatToDoWithARecoveredBuffer() {
        #expect(Recovery.action(saved: sig, disk: sig) == .restore)
        #expect(Recovery.action(saved: sig, disk: FileSignature(modified: 5, size: 42)) == .restoreChanged)
        #expect(Recovery.action(saved: sig, disk: nil) == .drop)
        #expect(Recovery.action(saved: nil, disk: sig) == .restoreChanged)
        #expect(Recovery.action(saved: nil, disk: nil) == .drop)
    }

    @Test func identityAndDigestSurviveEncoding() {
        let full = FileSignature(modified: 1_762_400_000.5, size: 42, identity: 99, digest: 0xdeadbeef)
        let back = RecoveryRecord.decode(RecoveryRecord(path: "/p/a.go", signature: full, text: "x").encoded())
        #expect(back?.signature?.identity == 99)
        #expect(back?.signature?.digest == 0xdeadbeef)
        let noDigest = FileSignature(modified: 1, size: 2, identity: 3)
        #expect(RecoveryRecord.decode(RecoveryRecord(path: "/p/a.go", signature: noDigest, text: "x").encoded())?.signature?.digest == nil)
    }

    @Test func anOldRecordWithoutDigestStillDecodes() {
        let record = RecoveryRecord.decode("gobi-recovery 1\nsig=100.5,42\npath=/p/a.go\nhello")
        #expect(record?.signature == FileSignature(modified: 100.5, size: 42))
        #expect(record?.signature?.digest == nil)
        #expect(record?.text == "hello")
    }

    @Test func equalMetadataWithAnotherContentIsAChangedFile() {
        let saved = FileSignature(modified: 5, size: 42, identity: 99, digest: 0xdeadbeef)
        let disk = FileSignature(modified: 5, size: 42, identity: 99)
        #expect(Recovery.action(saved: saved, disk: disk, diskDigest: { 0xdeadbeef }) == .restore)
        #expect(Recovery.action(saved: saved, disk: disk, diskDigest: { 0x1234 }) == .restoreChanged)
        #expect(Recovery.action(saved: saved, disk: nil, diskDigest: { 0 }) == .drop)
    }

    @Test func secretLookingFilesAreSensitive() {
        for path in ["/p/.env", "/p/.env.local", "/p/sub/server.pem", "/p/a.key", "/p/id_rsa", "/p/id_rsa.pub", "/p/credentials", "/p/credentials.json", "/p/store.p12", "/p/ID_RSA"] {
            #expect(Recovery.isSensitive(path), "\(path)")
        }
        for path in ["/p/main.go", "/p/environment.go", "/p/keyboard.go", "/p/env/x.go", "/p/credit.go", "/p/.environment"] {
            #expect(!Recovery.isSensitive(path), "\(path)")
        }
    }

    @Test func recordsAreKeptOnlyWhileFreshAndTheirFileExists() {
        #expect(Recovery.shouldPrune(ageDays: 31, fileExists: true))
        #expect(Recovery.shouldPrune(ageDays: 1, fileExists: false))
        #expect(!Recovery.shouldPrune(ageDays: 29, fileExists: true))
    }

    @Test func theStoreKeyIsStableAndDistinct() {
        #expect(Recovery.key("/p/a.go") == Recovery.key("/p/a.go"))
        #expect(Recovery.key("/p/a.go") != Recovery.key("/p/b.go"))
        #expect(Recovery.key("").count == 16)
    }
}
