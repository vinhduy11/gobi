#!/usr/bin/env python3
"""Generates the large files the editor checks need, into the directory given as the only argument.

    python3 scripts/make-fixtures.py OUT_DIR

Creates:
  biggo/        a valid 100,012-line Go program (go.mod + main.go); `go run .` prints `total: 37345`
  biggo_err/    the same with one error on the last line (gopls reports `undefined: undefinedAtTheEnd`)
  longline/     single-line JSON files of about 100k, 250k, 500k and 1M characters (`line-100k.json` ...), a 1 MB one
                (`one-megabyte.json`), and a Go file whose lines are about 3800 characters long
Nothing here touches the repository.
"""
import json
import os
import sys

out = sys.argv[1] if len(sys.argv) > 1 else sys.exit(__doc__)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(text)


lines = ["package main", "", 'import "fmt"', ""]
for index in range(25000):
    lines += [f"// f{index} returns x plus {index}.", f"func f{index}(x int) int {{", f"\treturn x + {index}", "}"]
lines += ["", "func main() {", "\ttotal := 0",
          "\tfor _, step := range []func(int) int{f0, f1, f12345, f24999} {", "\t\ttotal = step(total)", "\t}",
          '\tfmt.Println("total:", total)', "}", ""]
program = "\n".join(lines)
module = "module example.com/biggo\n\ngo 1.26\n"
write(f"{out}/biggo/main.go", program)
write(f"{out}/biggo/go.mod", module)
write(f"{out}/biggo_err/main.go", program + "var broken = undefinedAtTheEnd\n")
write(f"{out}/biggo_err/go.mod", module)

write(f"{out}/longline/one-megabyte.json", json.dumps({"items": [{"id": number, "name": f"item-{number}"} for number in range(40000)]}))
for label, characters in (("100k", 100_000), ("250k", 250_000), ("500k", 500_000), ("1m", 1_000_000)):
    items, text = 0, ""
    while len(text) < characters:
        items += 500
        text = json.dumps({"items": [{"id": number, "name": f"item-{number}"} for number in range(items)]})
    write(f"{out}/longline/line-{label}.json", text)
write(f"{out}/longline/long-lines.go", "package main\n\n" + "".join(
    f'var line{number} = "{"abcdefghij" * 380}"\n' for number in range(200)) + "\nfunc main() {}\n")
write(f"{out}/longline/go.mod", "module example.com/longline\n\ngo 1.26\n")
print("wrote fixtures under", out)
