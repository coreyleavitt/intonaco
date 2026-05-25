{.experimental: "callOperator".}

## Guard: the runtime floor (`createEffect` / `createComputed`) must NOT be
## reachable from the blessed reactive surface. The only public escape to the
## floor is `Dynamic[T]` (value construction) and the `dynamic:` macro. The
## procs live in `reactive/runtime` and are reached only by a deliberate
## `import intonaco/reactive/runtime` — so a consumer can't silently bypass
## the compile-time classifier.

import std/unittest
import intonaco/reactive/signal
import intonaco/reactive/dynamic
import intonaco/reactive/construct
import intonaco/reactive/collection
import intonaco/reactive/derive
import intonaco/reactive/scan

suite "API surface":
  test "the runtime floor procs are off the blessed surface":
    check not compiles(createEffect(proc() = discard))
    check not compiles(createComputed(proc(): int = 1))
  test "the blessed escape (Dynamic[T]) IS reachable":
    let d = dynamicComputed(proc(): int = 1)
    check d() == 1

suite "collection delta-floor surface":
  test "the value/mutation surface IS reachable from `collection`":
    let c = collection[int](@[1, 2])
    check compiles(c.push(3))
    check compiles(c.get())
  test "the delta-floor edge-former `onDelta` is OFF the blessed surface":
    let c = collection[int]()
    check not compiles(c.onDelta(proc(d: Delta[int]) = discard))

  test "the classified transform macros ARE reachable from `derive`":
    collections:
      src = @[1, 2, 3]
    derive doubled, src, proc(x: int): int = x * 2
    keep evens, src, proc(x: int): bool = x mod 2 == 0
    check doubled.get() == @[2, 4, 6]
    check evens.get() == @[2]

  test "the value-constructed floor procs are OFF the blessed surface":
    # `declared` tests symbol reachability directly — independent of any
    # generic constraint (e.g. `folded`'s `CommutativeGroup`), so a `compiles`
    # false-positive can't mask a still-exported floor proc.
    check not declared(mapped)
    check not declared(filtered)
    check not declared(folded)

  test "the `scan` macro IS reachable; its floor (deltas/foldDeltas) is OFF":
    collections:
      src = @[10, 20]
    scan total, src, 0, proc(acc: int, d: Delta[int]): int =
      if d.kind == dkInsert: acc + d.insertVal else: acc
    src.push(5)
    check total.get() == 5
    check not declared(deltas)
    check not declared(foldDeltas)
    check not declared(DeltaStream)
