import Testing
@testable import GobiModel

@Suite("Signature help")
struct SignatureHelpTests {
    private func answer(label: String = "helper(a int, b string) string", params: [Any], active: Any? = 0, signatureActive: Any? = nil, activeSignature: Int? = nil, extra: [[String: Any]] = []) -> [String: Any] {
        var first: [String: Any] = ["label": label, "parameters": params.map { ["label": $0] }]
        if let signatureActive { first["activeParameter"] = signatureActive }
        var result: [String: Any] = ["signatures": [first] + extra]
        if let active { result["activeParameter"] = active }
        if let activeSignature { result["activeSignature"] = activeSignature }
        return result
    }

    @Test func parameterLabelsGivenAsTextAreFoundInsideTheParentheses() {
        let signature = SignatureHelp.parse(answer(params: ["a int", "b string"], active: 1))
        #expect(signature?.label == "helper(a int, b string) string")
        #expect(signature?.parts.before == "helper(a int, ")
        #expect(signature?.parts.active == "b string")
        #expect(signature?.parts.after == ") string")
    }

    @Test func parameterLabelsGivenAsOffsetsAreUsedAsTheyAre() {
        let signature = SignatureHelp.parse(answer(params: [[7, 12], [14, 22]], active: 0))
        #expect(signature?.parts.active == "a int")
    }

    @Test func aRepeatedParameterTextIsMatchedInOrder() {
        let signature = SignatureHelp.parse(answer(label: "f(x int, x int)", params: ["x int", "x int"], active: 1))
        #expect(signature?.parts.before == "f(x int, ")
    }

    @Test func aParameterNamedLikeTheFunctionDoesNotMatchTheName() {
        let signature = SignatureHelp.parse(answer(label: "f(f int)", params: ["f int"], active: 0))
        #expect(signature?.parts.before == "f(")
    }

    @Test func theSignaturesOwnActiveParameterWinsOverTheTopLevelOne() {
        let signature = SignatureHelp.parse(answer(params: ["a int", "b string"], active: 0, signatureActive: 1))
        #expect(signature?.parts.active == "b string")
    }

    @Test func theActiveSignatureIsChosen() {
        let second: [String: Any] = ["label": "g(c bool)", "parameters": [["label": "c bool"]]]
        let signature = SignatureHelp.parse(answer(params: ["a int"], active: 0, activeSignature: 1, extra: [second]))
        #expect(signature?.label == "g(c bool)")
        #expect(signature?.parts.active == "c bool")
    }

    @Test func anActiveParameterPastTheEndHighlightsNothing() {
        let signature = SignatureHelp.parse(answer(params: ["a int"], active: 3))
        #expect(signature?.label == "helper(a int, b string) string")
        #expect(signature?.activeRange == nil)
        #expect(signature?.parts.active == "")
        #expect(signature?.parts.before == "helper(a int, b string) string")
    }

    @Test func noSignaturesOrNullGivesNothing() {
        #expect(SignatureHelp.parse(nil) == nil)
        #expect(SignatureHelp.parse(["signatures": [] as [Any]]) == nil)
        #expect(SignatureHelp.parse("x") == nil)
    }

    @Test func offsetsCountUTF16UnitsSoANonAsciiNameStaysAligned() {
        let signature = SignatureHelp.parse(answer(label: "é(a int)", params: ["a int"], active: 0))
        #expect(signature?.parts.before == "é(")
        #expect(signature?.parts.active == "a int")
    }
}
