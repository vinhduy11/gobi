// The Generate messages of the control channel (core/internal/generate/codec.go). Field numbers are in
// docs/architect/wire-protocol.md. The UI sends facts about the caret and shows what core answers; the code itself
// (templates, formatting, the import edit) is core's.

public struct GenerateField: Equatable {
    public var name: String
    public var type: String
    public var underlying: String

    public init(name: String, type: String, underlying: String = "") {
        self.name = name
        self.type = type
        self.underlying = underlying
    }
}

public struct GenerateMethod: Equatable {
    public var name: String
    public var params: [GenerateField]
    public var results: [String]

    public init(name: String, params: [GenerateField] = [], results: [String] = []) {
        self.name = name
        self.params = params
        self.results = results
    }
}

/// The answer to one pattern parameter; a blank answer is left out so core uses the default.
public struct GenerateAnswer: Equatable {
    public var key: String
    public var values: [String]

    public init(key: String, values: [String]) {
        self.key = key
        self.values = values
    }
}

/// The request of generate/list, generate/preview and generate/render.
public struct GenerateRequest: Equatable {
    public var path = ""
    public var package = ""
    public var line = 0
    public var column = 0
    public var kind = ""
    public var name = ""
    public var fields: [GenerateField] = []
    public var source = ""
    /// The version of the buffer the facts were read at; every answer echoes it.
    public var version: UInt64 = 0
    public var item = ""
    public var selected: [String] = []
    public var askedName = ""
    public var methods: [GenerateMethod] = []
    public var params: [GenerateField] = []
    public var results: [String] = []
    public var receiver = ""
    public var goVersion = ""
    public var answers: [GenerateAnswer] = []
    /// "current" (default) or "file".
    public var target = ""

    public init() {}

    private static func write(_ number: Int, _ field: GenerateField, into writer: inout WireWriter) {
        writer.message(number) { m in
            m.string(1, field.name)
            m.string(2, field.type)
            m.string(3, field.underlying)
        }
    }

    public func encode() -> [UInt8] {
        var w = WireWriter()
        w.string(1, path)
        w.string(2, package)
        w.uint(3, UInt64(line))
        w.uint(4, UInt64(column))
        w.string(5, kind)
        w.string(6, name)
        for field in fields { Self.write(7, field, into: &w) }
        w.string(8, source)
        w.uint(9, version)
        w.string(10, item)
        for name in selected { w.raw(11, Array(name.utf8)) }
        w.string(12, askedName)
        for method in methods {
            w.message(13) { m in
                m.string(1, method.name)
                for p in method.params { Self.write(2, p, into: &m) }
                for r in method.results { m.raw(3, Array(r.utf8)) }
            }
        }
        for p in params { Self.write(14, p, into: &w) }
        for r in results { w.raw(15, Array(r.utf8)) }
        w.string(16, receiver)
        w.string(17, goVersion)
        for answer in answers {
            w.message(18) { m in
                m.string(1, answer.key)
                for value in answer.values { m.raw(2, Array(value.utf8)) }
            }
        }
        w.string(19, target)
        return w.bytes
    }
}

/// What a pattern asks for in its dialog.
public struct GenerateParam: Equatable {
    public var key: String
    public var label: String
    public var defaults: [String]
    /// "type", "names", "signature", "fields" or "typeexpr".
    public var kind: String
    public var multi: Bool

    public init(key: String, label: String, defaults: [String], kind: String, multi: Bool) {
        self.key = key
        self.label = label
        self.defaults = defaults
        self.kind = kind
        self.multi = multi
    }
}

/// One entry of the Generate popup.
public struct GenerateItem: Equatable {
    public var id: String
    public var title: String
    public var detail: String
    public var needsName: Bool
    public var needsFields: Bool
    /// "creational", "structural" or "behavioral" for a design pattern, else empty.
    public var group: String
    public var params: [GenerateParam]

    public init(id: String, title: String, detail: String = "", needsName: Bool = false, needsFields: Bool = false, group: String = "", params: [GenerateParam] = []) {
        self.id = id
        self.title = title
        self.detail = detail
        self.needsName = needsName
        self.needsFields = needsFields
        self.group = group
        self.params = params
    }
}

public struct GenerateList: Equatable {
    public var version: UInt64
    public var items: [GenerateItem]

    public init(version: UInt64, items: [GenerateItem]) {
        self.version = version
        self.items = items
    }

    public static func parse(_ fields: [WireField]) throws -> GenerateList {
        var list = GenerateList(version: 0, items: [])
        for field in fields {
            switch field.number {
            case 1: list.version = field.uint
            case 2: list.items.append(try item(try WireField.parse(field.bytes)))
            default: break
            }
        }
        return list
    }

    private static func item(_ fields: [WireField]) throws -> GenerateItem {
        var item = GenerateItem(id: "", title: "")
        for field in fields {
            switch field.number {
            case 1: item.id = field.string
            case 2: item.title = field.string
            case 3: item.detail = field.string
            case 4: item.needsName = field.uint != 0
            case 5: item.needsFields = field.uint != 0
            case 6: item.group = field.string
            case 7: item.params.append(try param(try WireField.parse(field.bytes)))
            default: break
            }
        }
        return item
    }

    private static func param(_ fields: [WireField]) throws -> GenerateParam {
        var param = GenerateParam(key: "", label: "", defaults: [], kind: "", multi: false)
        for field in fields {
            switch field.number {
            case 1: param.key = field.string
            case 2: param.label = field.string
            case 3: param.defaults.append(field.string)
            case 4: param.kind = field.string
            case 5: param.multi = field.uint != 0
            default: break
            }
        }
        return param
    }
}

public struct GenerateFile: Equatable {
    public var path: String
    public var content: String

    public init(path: String, content: String) {
        self.path = path
        self.content = content
    }
}

/// The answer to generate/preview (text only) and generate/render (edits of the current buffer, files to create).
public struct GenerateResult: Equatable {
    public var version: UInt64 = 0
    public var text = ""
    public var imports: [String] = []
    public var edits: [TextEdit] = []
    public var files: [GenerateFile] = []

    public init() {}

    public static func parse(_ fields: [WireField]) throws -> GenerateResult {
        var result = GenerateResult()
        for field in fields {
            switch field.number {
            case 1: result.version = field.uint
            case 2: result.text = field.string
            case 3: result.imports.append(field.string)
            case 4: result.edits.append(try edit(try WireField.parse(field.bytes)))
            case 5:
                var file = GenerateFile(path: "", content: "")
                for part in try WireField.parse(field.bytes) {
                    if part.number == 1 { file.path = part.string } else if part.number == 2 { file.content = part.string }
                }
                result.files.append(file)
            default: break
            }
        }
        return result
    }

    private static func edit(_ fields: [WireField]) throws -> TextEdit {
        var n = [Int](repeating: 0, count: 5), text = ""
        for field in fields {
            if field.number == 5 { text = field.string } else if (1 ... 4).contains(field.number) { n[field.number - 1] = Int(field.uint) }
        }
        return TextEdit(start: LSPPosition(line: n[0], character: n[1]), end: LSPPosition(line: n[2], character: n[3]), newText: text)
    }
}
