{.experimental: "callOperator".}

## M-α.5 — the extension-protocol example pass fires correctly.
##
## Importing the example file registers `noIOCallPass`; the binding macros
## (`computed`/`effect`) in this compilation now include the I/O check in
## their walker analysis. The tests below verify:
##   (a) a binding with an `echo` call (IOEffect-tagged) fails to compile
##   (b) a pure binding still compiles and behaves correctly

import std/unittest
import intonaco/reactive
import ../examples/extensions/no_io_call   # registers noIOCallPass

suite "M-α.5 — NoIOCallPass example":

  test "binding body containing a stdout.write call fails to compile":
    signals:
      x = 0
    # `stdout.write` has WriteIOEffect → noIOCallPass fires
    check not compiles(block:
      computed bad, [x]:
        stdout.write("side effect")
        x)

  test "pure binding body compiles and behaves correctly":
    signals:
      v = 10
    computed doubled, [v]:
      v * 2          # pure — no I/O
    check doubled() == 20
    v := 7
    check doubled() == 14
