// Gobi editor spike.
//
//   GobiApp [FILE] [--selftest]
//
// Opens FILE (or asks for one), connects to gobid (starting it when needed) and shows diagnostics.
// --selftest waits for diagnostics, simulates Vietnamese composition, prints the checks and exits.

import AppKit

setvbuf(stdout, nil, _IOLBF, 0)   // progress lines must appear even if a step hangs

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
