## M-ε.1 tracer — a hello-world consumer.
##
## Exercises the public substrate surface via `import intonaco/reactive`:
## a source, a derived computed, an effect that re-fires on writes.
## Proves the consumer wrapper preserves canonical type identity and
## the static-tier macros work end-to-end through it.

{.experimental: "callOperator".}

import std/unittest
import intonaco/reactive

suite "M-ε.1: consumer smoke":

  test "signals + computed + effect compose end-to-end":
    var observed: seq[int] = @[]
    discard createRoot:
      signals:
        count = 0
      computed doubled, [count]:
        count * 2
      effect [doubled]:
        observed.add doubled
      count := 1
      count := 5
    check observed == @[0, 2, 10]
