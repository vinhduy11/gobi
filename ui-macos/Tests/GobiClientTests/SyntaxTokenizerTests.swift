import Testing
@testable import GobiClient

/// Tokenizes one line and returns "kind:text" pairs, which read better in failures than offsets.
private func lex(_ source: String, _ language: SyntaxLanguage = .go, state: LexState = .normal) -> (tokens: [String], end: LexState) {
    let units = Array(source.utf16)
    let result = tokenizeLine(units, state: state, language: language)
    return (result.tokens.map { token in
        let slice = units[Int(token.start) ..< Int(token.start + token.length)]
        return "\(token.kind):\(String(decoding: slice, as: UTF16.self))"
    }, result.end)
}

@Suite("Go tokenizer")
struct GoTokenizerTests {
    @Test func keywordsAndBuiltins() {
        #expect(lex("func main() { return }").tokens == ["keyword:func", "keyword:return"])
        #expect(lex("var n int = len(s)").tokens == ["keyword:var", "builtin:int", "builtin:len"])
        #expect(lex("ok := x == nil || true").tokens == ["builtin:nil", "builtin:true"])
    }

    @Test func wordsContainingKeywordsAreNotKeywords() {
        #expect(lex("iffy format funcs returned integer").tokens.isEmpty)
        #expect(lex("tiếng := 1").tokens == ["number:1"])
    }

    @Test func stringsRunesAndEscapes() {
        #expect(lex(#"x := "a\"b" + 'c'"#).tokens == [#"string:"a\"b""#, "character:'c'"])
        #expect(lex(#"'\''"#).tokens == [#"character:'\''"#])
        #expect(lex(#"u := "http://example.com""#).tokens == [#"string:"http://example.com""#])
    }

    @Test func anUnterminatedStringEndsAtTheEndOfTheLine() {
        let result = lex(#"s := "abc"#)
        #expect(result.tokens == [#"string:"abc"#] && result.end == .normal)
    }

    @Test func lineComments() {
        #expect(lex("// whole line").tokens == ["comment:// whole line"])
        #expect(lex("x++ // trailing").tokens == ["comment:// trailing"])
    }

    @Test func blockCommentsAcrossLines() {
        let first = lex("/* a */ b /* c")
        #expect(first.tokens == ["comment:/* a */", "comment:/* c"] && first.end == .blockComment)
        let second = lex(" still */ return", state: .blockComment)
        #expect(second.tokens == ["comment: still */", "keyword:return"] && second.end == .normal)
        let middle = lex("only comment", state: .blockComment)
        #expect(middle.tokens == ["comment:only comment"] && middle.end == .blockComment)
    }

    @Test func rawStringsAcrossLines() {
        let first = lex("s := `abc")
        #expect(first.tokens == ["string:`abc"] && first.end == .rawString)
        let second = lex("def` + x", state: .rawString)
        #expect(second.tokens == ["string:def`"] && second.end == .normal)
        #expect(lex("`one` + `two`").tokens == ["string:`one`", "string:`two`"])
    }

    @Test func numbers() {
        let source = "0x1F 3.14 1e-9 0b101 12_000 .5 2i 1.5e+3"
        #expect(lex(source).tokens == ["number:0x1F", "number:3.14", "number:1e-9", "number:0b101", "number:12_000", "number:.5", "number:2i", "number:1.5e+3"])
        #expect(lex("x1 := a.b").tokens.isEmpty)
    }

    @Test func emptyAndWhitespaceLinesKeepTheState() {
        #expect(lex("").end == .normal)
        #expect(lex("   \t", state: .rawString).end == .rawString)
        #expect(lex("", state: .blockComment).end == .blockComment)
    }

    @Test func offsetsAreRelativeToTheLineAndCountUTF16Units() {
        let units = Array("😀 := \"é\"".utf16)   // the emoji is two UTF-16 units
        let found = tokenizeLine(units, state: .normal, language: .go).tokens
        #expect(found.count == 1 && found[0].start == 6 && found[0].length == 3)
    }
}

@Suite("JSON and Markdown tokenizers")
struct DataLanguageTokenizerTests {
    @Test func jsonKeysValuesAndLiterals() {
        let source = #"{"name": "x", "n": -1.5e3, "ok": true, "z": null}"#
        #expect(lex(source, .json).tokens == [
            #"key:"name""#, #"string:"x""#, #"key:"n""#, "number:-1.5e3", #"key:"ok""#, "builtin:true", #"key:"z""#, "builtin:null",
        ])
    }

    @Test func jsonKeyWithSpaceBeforeColon() {
        #expect(lex(#""a" : 1"#, .json).tokens == [#"key:"a""#, "number:1"])
    }

    @Test func markdownHeadingsMarkersAndInlineCode() {
        #expect(lex("## Title", .markdown).tokens == ["heading:## Title"])
        #expect(lex("#hashtag", .markdown).tokens.isEmpty)
        #expect(lex("- item with `code` here", .markdown).tokens == ["marker:-", "code:`code`"])
        #expect(lex("12. numbered", .markdown).tokens == ["marker:12."])
    }

    @Test func markdownFencedCodeBlocks() {
        let open = lex("```go", .markdown)
        #expect(open.tokens == ["comment:```go"] && open.end == .fencedCode)
        let inside = lex("# not a heading", .markdown, state: .fencedCode)
        #expect(inside.tokens == ["code:# not a heading"] && inside.end == .fencedCode)
        let close = lex("```", .markdown, state: .fencedCode)
        #expect(close.tokens == ["comment:```"] && close.end == .normal)
    }
}
