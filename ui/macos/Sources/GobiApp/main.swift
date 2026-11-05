// Gobi editor spike.
//
//   GobiApp [FILE] [--selftest [--visible]]
//
// Opens FILE (or asks for one), connects to gobid (starting it when needed) and shows diagnostics.
// --selftest waits for diagnostics, simulates Vietnamese composition, prints the checks and exits.

import AppKit

setvbuf(stdout, nil, _IOLBF, 0)   // progress lines must appear even if a step hangs

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// A self-test runs quietly: no Dock icon, no focus change, an invisible window. --visible opts back in.
let quiet = (CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--selftest-welcome") || CommandLine.arguments.contains("--selftest-newproject") || CommandLine.arguments.contains("--selftest-trust") || CommandLine.arguments.contains("--selftest-terminal") || CommandLine.arguments.contains("--selftest-codehelp")) && !CommandLine.arguments.contains("--visible")
application.setActivationPolicy(quiet ? .accessory : .regular)
application.run()
