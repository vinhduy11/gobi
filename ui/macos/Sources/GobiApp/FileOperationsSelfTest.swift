import AppKit
import GobiModel

extension AppDelegate {
    /// Part of `--selftest-codehelp`: Cut, Copy, Paste, Delete, Rename and Move on real files of a project folder made for the test.
    /// Nothing reaches the real Trash (a scratch folder stands in) and the pasteboard is put back.
    func runFileOperationChecks(_ controller: ProjectWindowController, root: URL, scratch: URL, check: (String, Bool) -> Void, addCleanup: (@escaping () -> Void) -> Void) {
        let manager = FileManager.default
        func exists(_ name: String) -> Bool { manager.fileExists(atPath: root.appendingPathComponent(name).path) }
        func text(_ name: String) -> String? { try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
        let board = NSPasteboard.general
        let savedItems = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
        let savedTrash = ProjectWindowController.trashItem
        try? manager.removeItem(at: scratch)
        try? manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        ProjectWindowController.trashItem = { url in try manager.moveItem(at: url, to: scratch.appendingPathComponent(url.lastPathComponent)) }
        controller.saveAnswerHook = { _ in .discard }
        addCleanup {
            ProjectWindowController.trashItem = savedTrash
            FileClipboard.urls = []
            board.clearContents()
            for types in savedItems {
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                board.writeObjects([item])
            }
            try? manager.removeItem(at: scratch)
            UserDefaults.standard.removeObject(forKey: controller.breakpointsKey)
            RecoveryStore.clear(root: root)
        }

        // Copy and paste, with a name that is taken, and a folder with something inside.
        let cart = root.appendingPathComponent("cart.go"), internalFolder = root.appendingPathComponent("internal")
        try? "data".write(to: internalFolder.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        controller.copyToClipboard([cart], cut: false)
        check("Copy puts the file on the general pasteboard", (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.map(\.path) == [cart.path])
        controller.paste(into: root)
        controller.paste(into: root)
        check("Paste into the same folder gives `cart copy.go`, then `cart copy 2.go`", exists("cart copy.go") && exists("cart copy 2.go") && exists("cart.go"))
        controller.copyToClipboard([internalFolder], cut: false)
        controller.paste(into: root)
        check("a folder copies with what is inside it", text("internal copy/x.txt") == "data")
        check("a folder is not pasted into itself", controller.paste(into: internalFolder).isEmpty && !exists("internal/internal copy"))
        controller.copyToClipboard([root.appendingPathComponent("notes.md")], cut: true)
        let pasted = controller.paste(into: internalFolder)
        check("Cut and Paste moves the file and empties the clipboard", pasted.count == 1 && exists("internal/notes.md") && !exists("notes.md") && FileClipboard.urls.isEmpty && !controller.canPaste)
        board.clearContents()
        board.writeObjects([root.appendingPathComponent("cart copy.go") as NSURL])
        check("files copied by another app can be pasted", controller.canPaste && controller.paste(into: internalFolder).first?.lastPathComponent == "cart copy.go")

        // Rename of an open file with unsaved edits and a breakpoint.
        controller.openFile(cart)
        let pane = controller.openPane(for: cart.path)
        pane?.restoreUnsaved("package gobi_empty_project\n// edited\n", changedOnDisk: false, quiet: true)
        pane?.textView.setSelectedRange(NSRange(location: 5, length: 0))
        controller.toggleBreakpoint(path: cart.path, line: 2)
        let renamed = controller.renameItem(cart, to: "basket.go")
        let basket = root.appendingPathComponent("basket.go")
        check("Rename renames on disk", renamed == basket && exists("basket.go") && !exists("cart.go"))
        check("the tab follows, keeping its text, caret and edit mark", controller.tabs.paths.contains(basket.path) && !controller.tabs.paths.contains(cart.path) && controller.openPane(for: basket.path)?.textView.string == "package gobi_empty_project\n// edited\n" && controller.openPane(for: basket.path)?.textView.selectedRange().location == 5 && controller.isDirty(basket))
        check("the file on disk is untouched by the rename (the edit is still unsaved)", text("basket.go") == "package gobi_empty_project\n")
        check("breakpoints move to the new name", controller.breakpoints.lines(in: basket.path) == [2] && controller.breakpoints.lines(in: cart.path).isEmpty)
        check("the old file's kept buffer is gone", RecoveryStore.load(root: root, path: cart.path) == nil)
        check("a name that exists, an empty name and a name with / are refused", controller.renameItem(basket, to: "cart_test.go") == nil && controller.renameItem(basket, to: "cart copy.go") == nil && controller.renameItem(basket, to: "") == nil && controller.renameItem(basket, to: "a/b") == nil && exists("basket.go"))
        check("a rename outside the project is refused", controller.renameItem(URL(fileURLWithPath: "/private/tmp/gobi-not-in-project"), to: "x") == nil)

        // Move, and rename of a folder with an open file below it.
        let moved = controller.moveItems([basket], to: internalFolder)
        let inInternal = internalFolder.appendingPathComponent("basket.go")
        check("Move puts the file in the folder and the tab follows with its breakpoint", moved == [inInternal] && controller.tabs.paths.contains(inInternal.path) && controller.breakpoints.lines(in: inInternal.path) == [2] && controller.isDirty(inInternal))
        check("a folder is not moved into its own subfolder", controller.moveItems([internalFolder], to: internalFolder.appendingPathComponent("sub")).isEmpty)
        let folderRenamed = controller.renameItem(internalFolder, to: "pkg")
        let moreInPkg = root.appendingPathComponent("pkg/basket.go")
        check("renaming a folder moves the tabs below it and leaves the others", folderRenamed != nil && Set(controller.tabs.paths) == [moreInPkg.path, root.appendingPathComponent("cart_test.go").path, root.appendingPathComponent("pkg/notes.md").path] && controller.openPane(for: moreInPkg.path)?.textView.string.hasSuffix("// edited\n") == true && controller.breakpoints.lines(in: moreInPkg.path) == [2])

        // Delete: the confirmation says what is lost; Cancel keeps everything; the open tab closes.
        check("Cancel deletes nothing", controller.deleteItems([root.appendingPathComponent("pkg")], confirmed: false).isEmpty && exists("pkg"))
        check("the confirmation mentions the unsaved change", FileOperations.deleteDetail(names: ["pkg"], unsaved: controller.tabs.dirtyPaths.count, openTabs: controller.tabs.paths.count).hasSuffix("1 has unsaved changes."))
        let trashed = controller.deleteItems([root.appendingPathComponent("pkg"), root.appendingPathComponent("cart copy 2.go")], confirmed: true)
        check("Delete moves to the trash function, never removing for good", trashed.count == 2 && !exists("pkg") && !exists("cart copy 2.go") && manager.fileExists(atPath: scratch.appendingPathComponent("pkg/basket.go").path))
        check("its open tab is closed", controller.tabs.paths == [root.appendingPathComponent("cart_test.go").path])
        check("the explorer no longer lists them", !controller.explorerNames.contains("pkg") && !controller.explorerNames.contains("cart copy 2.go"))
        check("an item outside the project is not deleted", controller.deleteItems([scratch], confirmed: true).isEmpty && manager.fileExists(atPath: scratch.path))
    }
}
