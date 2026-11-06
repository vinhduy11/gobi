# Menu shortcuts: conflicts with the Menus mock

The menu bar follows `docs/artifact/2026-11-05-ui-mockup/Menus.dc.html`. Where the mock gives an item a key that an existing Gobi
feature already owns, the existing feature keeps the key (people have it in their fingers, and the self-tests and Settings >
Keymap lists use it) and the newer item shows no shortcut. `MenuSpecTests` holds the resolved list; every shortcut in the
spec is unique except the ones in `MenuSpec.sharedShortcuts` (⌘0 and ⇧⌘V, which the mock itself gives twice, and F5).

| Key | Mock gives it to | Gobi already used it for | Chosen |
|---|---|---|---|
| F5 | (Run ▸ Debug has ⌘D) | Start Debugging, and Continue while paused | Run ▸ Debug and Run ▸ Resume Program share F5 as before: Debug is disabled while a session runs, Resume while none is paused. The mock's ⌘D and ⌥⌘R are not used. |
| ⇧F5 | Stop has ⌘F2 | Stop debugging | Run ▸ Stop keeps ⇧F5. It stops the debug session, or the run when there is no session. |
| F10 | Update Application (⌘F10); Step Over has F8 | Step Over | Run ▸ Step Over keeps F10. The mock's F8 stays with Go ▸ Next Problem (F8, not built). |
| F11 | Step Into has F7 | Step Into | Run ▸ Step Into keeps F11. |
| ⇧F11 | Step Out has ⇧F8 | Step Out | Run ▸ Step Out keeps ⇧F11. Go ▸ Previous Problem keeps ⇧F8. |
| ⌘\ | Toggle Line Breakpoint has ⌘F8 | Toggle Breakpoint (the terminal uses ⌘\ to split only while a terminal has focus) | Run ▸ Toggle Line Breakpoint keeps ⌘\. |
| ⇧⌘K | Git ▸ Push… | File ▸ Clone Repository… | Clone keeps ⇧⌘K; Push… has no shortcut. |
| ⌘E | View ▸ Recent Files | Edit ▸ Find ▸ Use Selection for Find | Use Selection for Find keeps ⌘E; Recent Files has no shortcut (Recent Locations keeps ⇧⌘E, not built). |
| ⌘T | (Git ▸ Update Project… has ⌥⌘T) | Go to Symbol in Workspace | No clash: ⌘T stays with Go; Update Project… takes ⌥⌘T from the mock. |
| ⌘K | Git ▸ Commit… | The terminal's Clear (only while a terminal has focus; the terminal answers the key before the menu does) | Commit… takes ⌘K from the mock; inside a terminal ⌘K still clears. |
| ⌘I | Run ▸ Profile | Profile | Same key, same item. |
| ⇧⌘V | Edit ▸ Paste from History… and View ▸ Markdown Preview | — | The mock gives it twice; both items are not built, so no clash today. When one is built, the other loses the key. |
| ⌘0 | Toggle Sidebar and View ▸ Actual Size | Toggle Sidebar | As before: Actual Size is not built. |
| ⌃⌃ | Run ▸ Run Anything… | — | A double Control tap is not a key equivalent; the item is not built and shows none. |
| ⌥⌘⇣ / ⌥⌘⇡ | Window ▸ Next / Previous Project Tab | — | Shown as in the mock; not built. |
| ⌘` and ⇧⌘` | Window ▸ Next / Previous Project Window | macOS cycles an app's windows with ⌘` | Gobi's items take the keys and cycle through the open project windows only (the Welcome window is skipped). |

Items that take a mock shortcut without a clash: Build Project ⌘F9, Build Module ⇧⌘F9, Copy Path ⇧⌘C, Paste as Plain Text
⌥⇧⌘V, New Branch… ⌥⌘N, Attach to Process… ⌥⇧F5, Evaluate Expression… ⌥F8, View Breakpoints… ⇧⌘F8.

Settings > Keymap still lists every command: `KeymapItems` is built from the menu spec, so each live item or item with a shortcut
appears. Items were renamed with the Debug menu merged into Run (Start Debugging is now Run ▸ Debug, Continue is Run ▸ Resume
Program, Toggle Breakpoint is Run ▸ Toggle Line Breakpoint, and Edit ▸ Find ▸ Find in Files… is Edit ▸ Find in Files…).
Overrides are stored under the item's menu path, so `KeymapMigration` (GobiModel, run once at launch; the version is kept
in the `gobi.keymapVersion` preference) moves a shortcut stored under an old path to the new one. A shortcut already set under
the new name wins. A later rename adds entries to `KeymapMigration.renames` and raises `currentVersion`.
