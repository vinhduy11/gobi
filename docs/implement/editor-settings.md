# Editor settings: plan

Mocks: `SettingsEditor` (the pane) and `EditorOptions` (the value lists and what each option does to the editor).

Stored values live in `EditorSettings` (pure, `GobiModel`): defaults from the mock, a validated set of allowed values per
option, and a `UserDefaults` store in the app. Every open editor listens for a change and applies it at once, with no reopen.

| Step | Option | How it is applied | Risk |
|---|---|---|---|
| 1 | Model and store | `EditorSettings` with allowed values, clamping, defaults; tests | none |
| 2 | Line numbers | show or hide the gutter view | low |
| 3 | Ruler at column | hairline drawn by the text view at `column x character width` (needs the font's advance) | low |
| 4 | Tab width and Indent using | tab stops in the paragraph style; Tab key inserts a tab or N spaces; Go files always keep tabs | medium: paragraph style over the whole storage |
| 5 | Font and size, Line height | font on the text view and the storage; paragraph line-height multiple; gutter and ruler follow the new metrics | medium: layout of very large files, gutter alignment |
| 6 | Invisible characters | faint tab, trailing space and line-end marks drawn over the visible fragments only | medium: must stay cheap on big files |
| 7 | Wrap long lines | container width tracks the view instead of the fixed wide container; off by default | high: layout cost of huge files, scroll-by-fraction mapping |
| 8 | Auto save | Off, After a delay (1 s after the last edit), or When the window loses focus; uses the same save path as Save (trim, final newline, format on save) | low |

Each step ships with: the controls enabled in Settings > Editor, a test on the model, and a line in `--selftest-codehelp`
or a new selftest that changes the value and checks the effect. Large-file behaviour is checked with the existing benchmark
fixtures before step 5, 6 and 7 are called done (keystroke time and open time must not move).

Order is by risk: 1, 2, 3, 8 first, then 4, 5, 6, and 7 last.

## Status
Steps 1 to 8 are built. Wrap (step 7) switches between the fixed wide container and a container that follows the window; it
was only checked on small files, so before relying on it for very large files run `gobi-bench` with wrap on. The bench's
keystroke figure (about 110 ms for 100k lines in debug-free release builds on the current macOS) was the same before this work,
so it is not caused by these settings; it is tracked separately against the 16 ms budget.
