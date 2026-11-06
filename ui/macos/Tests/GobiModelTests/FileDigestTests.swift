import Testing
@testable import GobiModel

struct FileDigestTests {
    @Test func theDigestIsFNV1a64() {
        #expect(FileDigest.of("") == 0xcbf29ce484222325)
        #expect(FileDigest.of("a") == 0xaf63dc4c8601ec8c)
        #expect(FileDigest.of("a") != FileDigest.of("b"))
    }

    @Test func theFileIdentityIsPartOfTheSignature() {
        let first = FileSignature(modified: 1, size: 1, identity: 7), second = FileSignature(modified: 1, size: 1, identity: 8)
        #expect(first != second)
        #expect(DiskCheck.state(known: first, current: second) == .changed)
        // 0 means unknown (an old record): it matches any identity.
        #expect(first == FileSignature(modified: 1, size: 1))
    }

    @Test func equalMetadataIsComparedByContentWhenAskedFor() {
        let known = FileSignature(modified: 1, size: 3, identity: 7, digest: FileDigest.of("abc"))
        let current = FileSignature(modified: 1, size: 3, identity: 7)
        #expect(DiskCheck.state(known: known, current: current, digest: { FileDigest.of("abd") }) == .changed)
        #expect(DiskCheck.state(known: known, current: current, digest: { FileDigest.of("abc") }) == .same)
        // The quick path never hashes.
        #expect(DiskCheck.state(known: known, current: current) == .same)
        // Nothing to compare with: trust the metadata.
        #expect(DiskCheck.state(known: current, current: current, digest: { FileDigest.of("abd") }) == .same)
        #expect(DiskCheck.state(known: known, current: current, digest: { nil }) == .same)
    }

    @Test func differentMetadataDoesNotHash() {
        let known = FileSignature(modified: 1, size: 3, digest: 1), other = FileSignature(modified: 2, size: 3)
        #expect(DiskCheck.state(known: known, current: other, digest: { Issue.record("hashed"); return 1 }) == .changed)
    }
}
