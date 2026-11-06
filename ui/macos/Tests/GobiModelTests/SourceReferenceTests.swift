import Testing
@testable import GobiModel

@Suite("Source references") struct SourceReferenceTests {
    @Test func compilerError() {
        let refs = SourceReference.find(in: "./main.go:12:5: undefined: x")
        #expect(refs == [SourceReference(path: "./main.go", line: 12, column: 5, offset: 0, length: 14)])
    }

    @Test func testFailureIndentedWithoutColumn() {
        let refs = SourceReference.find(in: "    add_test.go:31: got 3, want 4")
        #expect(refs.count == 1)
        #expect(refs[0].path == "add_test.go" && refs[0].line == 31 && refs[0].column == nil && refs[0].offset == 4)
    }

    @Test func pathWithFolders() {
        let refs = SourceReference.find(in: "internal/server/server.go:28:3: boom")
        #expect(refs.first?.path == "internal/server/server.go" && refs.first?.line == 28 && refs.first?.column == 3)
    }

    @Test func goroutineTraceInParentheses() {
        let refs = SourceReference.find(in: "main.main()\n")
        #expect(refs.isEmpty)
        #expect(SourceReference.find(in: "\t/work/app/main.go:9 +0x1d").first?.line == 9)
    }

    @Test func nothingToLink() {
        #expect(SourceReference.find(in: "ok  \tgobi/core\t0.4s").isEmpty)
        #expect(SourceReference.find(in: "see notes.txt:3").isEmpty)
        #expect(SourceReference.find(in: "main.go: no line").isEmpty)
        #expect(SourceReference.find(in: "").isEmpty)
    }
}
