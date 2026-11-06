import Testing
@testable import GobiModel

/// The bytes below are the ones core/internal/generate asserts (codec_test.go): both sides must agree on them.
@Suite("Generate wire messages")
struct GenerateWireTests {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined() }

    private var sample: GenerateRequest {
        var r = GenerateRequest()
        r.version = 3
        r.item = "string"
        r.selected = ["a"]
        r.askedName = "x"
        r.goVersion = "1.23"
        r.target = "file"
        r.answers = [GenerateAnswer(key: "strategies", values: ["Fast", "Safe"]), GenerateAnswer(key: "strategy", values: ["Pricing"])]
        r.path = "/p/a.go"
        r.package = "demo"
        r.source = "package demo\n"
        r.line = 2
        r.column = 5
        r.kind = "struct"
        r.name = "T"
        r.fields = [GenerateField(name: "a", type: "string", underlying: "string")]
        r.methods = [GenerateMethod(name: "M", params: [GenerateField(name: "x", type: "int")], results: ["error"])]
        r.params = [GenerateField(name: "p", type: "int")]
        r.results = ["error"]
        r.receiver = "R"
        return r
    }

    @Test func aRequestEncodesToTheBytesCoreAsserts() {
        let golden = "0a072f702f612e676f120464656d6f180220052a067374727563743201543a130a01611206737472696e671a06737472696e67420d7061636b6167652064656d6f0a48035206737472696e675a01616201786a140a014d12080a01781203696e741a056572726f7272080a01701203696e747a056572726f72820101528a0104312e32339201180a0a737472617465676965731204466173741204536166659201130a087374726174656779120750726963696e679a010466696c65"
        #expect(hex(sample.encode()) == golden)
    }

    @Test func aListIsReadFromCoreBytes() throws {
        let bytes: [UInt8] = [0x08, 0x09, 0x12, 0x1b, 0x0a, 0x06, 0x73, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x12, 0x0f, 0x53, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x28, 0x29, 0x20, 0x6d, 0x65, 0x74, 0x68, 0x6f, 0x64, 0x28, 0x01]
        let list = try GenerateList.parse(try WireField.parse(bytes))
        #expect(list.version == 9)
        #expect(list.items == [GenerateItem(id: "string", title: "String() method", needsFields: true)])
    }

    @Test func aPatternItemKeepsItsGroupAndParameters() throws {
        let bytes: [UInt8] = [0x08, 0x01, 0x12, 0x3f,
            0x0a, 0x08, 0x73, 0x74, 0x72, 0x61, 0x74, 0x65, 0x67, 0x79, 0x12, 0x08, 0x53, 0x74, 0x72, 0x61, 0x74, 0x65, 0x67, 0x79,
            0x32, 0x0a, 0x62, 0x65, 0x68, 0x61, 0x76, 0x69, 0x6f, 0x72, 0x61, 0x6c,
            0x3a, 0x0f, 0x0a, 0x01, 0x6b, 0x12, 0x01, 0x4c, 0x1a, 0x01, 0x44, 0x22, 0x04, 0x74, 0x79, 0x70, 0x65,
            0x3a, 0x0c, 0x0a, 0x01, 0x6d, 0x22, 0x05, 0x6e, 0x61, 0x6d, 0x65, 0x73, 0x28, 0x01]
        let item = try #require(try GenerateList.parse(try WireField.parse(bytes)).items.first)
        #expect(item.id == "strategy" && item.group == "behavioral")
        #expect(item.params == [GenerateParam(key: "k", label: "L", defaults: ["D"], kind: "type", multi: false),
                                GenerateParam(key: "m", label: "", defaults: [], kind: "names", multi: true)])
    }

    @Test func aResultCarriesTextImportsEditsFilesAndTheVersion() throws {
        let bytes: [UInt8] = [0x08, 0x02, 0x12, 0x01, 0x78, 0x1a, 0x03, 0x66, 0x6d, 0x74,
            0x22, 0x0b, 0x08, 0x01, 0x10, 0x02, 0x18, 0x03, 0x20, 0x04, 0x2a, 0x01, 0x74,
            0x2a, 0x06, 0x0a, 0x01, 0x61, 0x12, 0x01, 0x62]
        let result = try GenerateResult.parse(try WireField.parse(bytes))
        #expect(result.version == 2 && result.text == "x" && result.imports == ["fmt"])
        #expect(result.edits == [TextEdit(start: LSPPosition(line: 1, character: 2), end: LSPPosition(line: 3, character: 4), newText: "t")])
        #expect(result.files == [GenerateFile(path: "a", content: "b")])
    }
}
