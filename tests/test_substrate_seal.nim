## M-ε.1 seal probe — verifies that `import intonaco/reactive` cannot
## reach substrate-internal symbols.
##
## Public surface stays accessible. Runtime-floor primitives, internal
## constructors, and substrate-internal types are walled off by Nim's
## module visibility — the `*` marker IS the compiler-enforced seal.
##
## Updating this list means walking the substrate's surface discipline:
## a regression here is a leak that warrants attention before merge.

{.experimental: "callOperator".}

import std/unittest
import intonaco/reactive

suite "M-ε.1: substrate seal":

  test "public surface IS reachable":
    check compiles(block:
      signals:
        x = 0
      computed y, [x]:
        x * 2
      effect [x]:
        discard x
      discard x.peek())

  test "runtime floor procs are NOT reachable":
    check not compiles(block: discard createEffect(proc() = discard))
    check not compiles(block: discard createComputed(proc(): int = 0))
    check not compiles(block: discard runAfterPropagation(proc() = discard))
    check not compiles(block: discard runAfterPropagationDetached(proc() = discard))

  test "delta-floor procs are NOT reachable":
    let c = collectionC[int](@[])
    check not compiles(block: onDelta(c, proc(d: Delta[int]) = discard))
    check not compiles(block: discard mapped(c, proc(x: int): int = x))
    check not compiles(block: discard filtered(c, proc(x: int): bool = true))

  test "observer machinery is NOT reachable":
    check not compiles(block: discard Subscribable)
    check not compiles(block: discard Computation)
    check not compiles(block: subscribe(nil, nil))
    check not compiles(block: notify(nil))

  test "C-suffix constructors are still reachable (M-β decision preserved)":
    # signalC and collectionC stay *-exported by design — they're the
    # named-substrate-author entry point. The C-suffix is the discipline.
    check compiles(block: discard signalC(0))
    check compiles(block: discard collectionC[int](@[]))
