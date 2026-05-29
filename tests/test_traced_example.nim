{.experimental: "callOperator".}

## Optional follow-on test: the kit-built `traced` example template
## (`examples/extensions/traced_macro.nim`) demonstrates that the M-α.3 kit
## composes new substrate templates with custom runtime primitives. The
## TRACE_COUNTER side effect verifies the macro routes through `tracedC`
## (not `computedC`) and that the binding is wired up correctly.

import std/unittest
import intonaco/reactive
import ../examples/extensions/traced_macro

suite "kit-built substrate template — traced example":

  test "traced macro produces a working reactive binding":
    TRACE_COUNTER = 0
    signals:
      x = 0
    traced y, [x]:
      x * 2
    check y() == 0       # initial value computed by traced body
    check TRACE_COUNTER == 1
    x := 5
    check y() == 10      # re-fire propagates correctly
    check TRACE_COUNTER == 2
    x := 7
    check y() == 14
    check TRACE_COUNTER == 3

  test "traced macro inherits walker discipline (undeclared read fails)":
    # Confirms the kit's orchestrator wires runAnalysis automatically; the
    # traced macro can't bypass the discipline that computed enforces.
    let stray = signal(0)
    check not compiles(block:
      signals:
        a = 0
      traced bad, [a]:
        a + stray.get())     # stray not in deps → walker errors
