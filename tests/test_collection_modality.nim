## M-δ — modality-polymorphic collection algebra.
##
## `derive` / `keep` / `fold` dispatch on input modality. A static input
## (`CollectionSignal[T]` or a baked-height derived view) routes through
## the static floor and bakes a compile-time height; a dynamic input
## (`DynamicCollection[T]`) routes through the dynamic floor and produces
## a `DynamicCollection[U]` output (or `Dynamic[M]` for fold). The
## modality propagates through the type system; chained operations
## preserve dynamic-ness without an explicit modality cast.
##
## See `docs/rfc-modal-tiers.md` for the modal framing, `docs/seams.md`
## for the structural seam this composes with.

{.experimental: "callOperator".}

import std/unittest
import intonaco/reactive/primitives/scope
import intonaco/reactive/primitives/collection
import intonaco/reactive/primitives/signal
import intonaco/reactive/dsl/derive
import intonaco/reactive/dsl/dynamic   # Dynamic[T] for the fold test
import intonaco/reactive/primitives/convergence   # CommutativeGroup laws for int

# int as a commutative group under addition (sum) — required by `fold`.
proc merge(a, b: int): int = a + b
proc unit(t: typedesc[int]): int = 0
proc invert(a: int): int = -a

suite "M-δ — modality dispatch":

  test "derive over a DynamicCollection returns a DynamicCollection":
    discard createRoot:
      let dyn = newDynamicReactive[int](@[1, 2, 3])
      derive doubled, dyn, proc(x: int): int = x * 2
      check doubled is DynamicCollection[int]

  test "delta propagates through the dynamic derived view":
    discard createRoot:
      let dyn = newDynamicReactive[int](@[1, 2, 3])
      derive doubled, dyn, proc(x: int): int = x * 2
      check doubled.get() == @[2, 4, 6]
      pushDelta(dyn, Delta[int](kind: dkInsert, insertIdx: 3, insertVal: 4))
      check doubled.get() == @[2, 4, 6, 8]

  test "keep over a DynamicCollection returns a DynamicCollection":
    discard createRoot:
      let dyn = newDynamicReactive[int](@[1, 2, 3, 4])
      keep evens, dyn, proc(x: int): bool = x mod 2 == 0
      check evens is DynamicCollection[int]
      check evens.get() == @[2, 4]
      pushDelta(dyn, Delta[int](kind: dkInsert, insertIdx: 4, insertVal: 6))
      check evens.get() == @[2, 4, 6]

  test "fold over a DynamicCollection returns Dynamic[M]":
    discard createRoot:
      let dyn = newDynamicReactive[int](@[1, 2, 3])
      fold total, dyn, proc(x: int): int = x
      check total is Dynamic[int]
      check total.val == 6
      pushDelta(dyn, Delta[int](kind: dkInsert, insertIdx: 3, insertVal: 4))
      check total.val == 10

  test "dynamic-ness propagates through chained derive + keep":
    # An end-to-end chain: a dynamic source through derive then keep
    # produces a dynamic result. The macros dispatch on input modality
    # at every link without any explicit promotion at the boundary.
    discard createRoot:
      let dyn = newDynamicReactive[int](@[1, 2, 3, 4, 5])
      derive doubled, dyn, proc(x: int): int = x * 2
      keep big, doubled, proc(x: int): bool = x >= 6
      check doubled is DynamicCollection[int]
      check big is DynamicCollection[int]
      check big.get() == @[6, 8, 10]
      pushDelta(dyn, Delta[int](kind: dkInsert, insertIdx: 5, insertVal: 7))
      check big.get() == @[6, 8, 10, 14]
