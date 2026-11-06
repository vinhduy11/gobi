import Testing
@testable import GobiModel

@Suite("New file and folder") struct NewEntryTests {
    @Test func aNameMustBeNonEmptyAndNotAPath() {
        #expect(NewEntry.problem(with: "", existing: []) == .empty)
        #expect(NewEntry.problem(with: "   ", existing: []) == .empty)
        #expect(NewEntry.problem(with: "a/b.go", existing: []) == .hasSeparator)
        #expect(NewEntry.problem(with: "..", existing: []) == .reserved)
        #expect(NewEntry.problem(with: ".", existing: []) == .reserved)
        #expect(NewEntry.problem(with: "main.go", existing: ["main.go"]) == .exists)
        #expect(NewEntry.problem(with: "cart.go", existing: ["main.go"]) == nil)
    }

    @Test func goFileGetsItsExtension() {
        #expect(NewEntry.goFileName("cart") == "cart.go")
        #expect(NewEntry.goFileName("cart.go") == "cart.go")
        #expect(NewEntry.goFileName("  cart  ") == "cart.go")
    }

    @Test func goTestFileGetsTheTestSuffix() {
        #expect(NewEntry.goTestFileName("cart") == "cart_test.go")
        #expect(NewEntry.goTestFileName("cart.go") == "cart_test.go")
        #expect(NewEntry.goTestFileName("cart_test.go") == "cart_test.go")
        #expect(NewEntry.goTestFileName("cart_test") == "cart_test.go")
    }

    @Test func thePackageNameComesFromTheFolderWhenNoSiblingSaysOtherwise() {
        #expect(NewEntry.packageName(folder: "shop", sibling: nil) == "shop")
        #expect(NewEntry.packageName(folder: "My-Shop", sibling: nil) == "my_shop")
        #expect(NewEntry.packageName(folder: "9lives", sibling: nil) == "pkg9lives")
        #expect(NewEntry.packageName(folder: "", sibling: nil) == "main")
        #expect(NewEntry.packageName(folder: "shop", sibling: "cart") == "cart")
    }

    @Test func sourceTemplates() {
        #expect(NewEntry.goSource(package: "shop") == "package shop\n")
        #expect(NewEntry.goTestSource(package: "shop") == "package shop\n\nimport \"testing\"\n")
    }
}
