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
let quiet = CommandLine.arguments.contains { $0.hasPrefix("--selftest") } && !CommandLine.arguments.contains("--visible")
application.setActivationPolicy(quiet ? .accessory : .regular)
application.run()
