{.experimental: "callOperator".}

## M-α.1 acceptance: `intonaco/reactive` (consumer surface) and
## `intonaco/substrate` (substrate-author surface) compose cleanly and expose
## the right APIs for their respective audiences.

import std/unittest
import intonaco/substrate          # includes intonaco/reactive transitively

suite "intonaco/reactive — consumer surface (via substrate re-export)":

  test "consumer surface composes signals + computed + effect end-to-end":
    signals:
      count = 0
    computed doubled, [count]:
      count * 2
    var seen = -1
    discard createRoot:
      effect [doubled]:
        seen = doubled
    check seen == 0
    count := 5
    check seen == 10

  test "consumer surface exposes signals: + collections: + dynamic":
    signals:
      flag = false
    collections:
      items = newSeq[int]()
    dynamic ratio:
      if flag(): 1.0 else: 0.5    # explicit call op in dynamic — auto-tracked
    check ratio() == 0.5
    items.push(1)
    check items.len == 1

suite "intonaco/substrate — substrate-author surface":

  test "substrate surface exposes computedC + effectC primitives":
    let s = signalC(10)
    var observed: int
    discard createRoot:
      let sig = computedC([Subscribable(s)], proc(): int = s.get() * 3)
      effectC([Subscribable(sig)], proc() = observed = sig.get())
    check observed == 30
    s.set(7)
    check observed == 21

  test "substrate surface exposes the AST utilities + the walker entry point":
    check declared(rewriteDepRefs)
    check declared(runAnalysis)
    check declared(registerWalkPass)
    check declared(depSymUnwrap)
    check declared(containsDepSym)
