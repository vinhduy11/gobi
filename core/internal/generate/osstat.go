package generate

import "os"

// osStat is a variable so tests need not touch the disk.
var osStat = os.Stat
