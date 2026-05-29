## TDD: convergence concepts (intonaco#54). Order-independent / duplicate-robust
## merging of concurrent writes, classified by the value type's merge algebra.

import std/[unittest, sets, sugar]
import intonaco/reactive/primitives/convergence

# A counter: a CommutativeMonoid (assoc+comm, identity 0) — NOT idempotent.
proc merge(a, b: int): int = a + b
proc unit(t: typedesc[int]): int = 0

# Set-union: a CommutativeMonoid that is ALSO idempotent (a bounded join-
# semilattice / Joinable) — identity is the empty set.
proc merge(a, b: HashSet[int]): HashSet[int] = a + b
proc unit(t: typedesc[HashSet[int]]): HashSet[int] = initHashSet[int]()

# A merge-only type (no unit) and a type with neither, for the concept gate.
type OnlyMerge = distinct int
proc merge(a, b: OnlyMerge): OnlyMerge = OnlyMerge(a.int + b.int)
type NoOps = object

suite "converge — order-independent merge over a CommutativeMonoid":
  test "1. converge is order-independent":
    check converge(@[1, 2, 3]) == converge(@[3, 2, 1])

suite "converge — duplicate-robust over an idempotent (Joinable) merge":
  test "2. a duplicate write does not change the converged value":
    let a = [1, 2].toHashSet
    let b = [2, 3].toHashSet
    check converge(@[a, b, b]) == converge(@[a, b])   # union is idempotent

suite "the idempotence distinction (why no-serialization needs care)":
  test "3. a non-idempotent monoid double-counts a duplicate; a join does not":
    check converge(@[5, 5]) == 10                     # counter: 0+5+5, NOT 5
    let s = [1, 2].toHashSet
    check converge(@[s, s]) == s                      # join: idempotent

suite "law witness-checks (exhaustive on finite types = a real proof)":
  test "4. holdsCommutative: exhaustive over bool-or proves it; catches subtraction":
    check holdsCommutative((a, b: bool) => (a or b), allValues[bool]())  # proof
    check not holdsCommutative((a, b: int) => (a - b), @[3, 5, 7])        # caught
  test "5. holdsIdempotent separates a join from a counter":
    check not holdsIdempotent((a, b: int) => (a + b), @[1, 2, 3])         # counter: no
    check holdsIdempotent((a, b: HashSet[int]) => (a + b),
                          @[[1, 2].toHashSet, [3].toHashSet])             # union: yes

suite "concept recognition (structural shape)":
  test "6. merge+unit -> CommutativeMonoid; merge-only -> Joinable only; neither -> nothing":
    check (int is CommutativeMonoid)
    check (int is Joinable)
    check (OnlyMerge is Joinable)
    check not (OnlyMerge is CommutativeMonoid)   # has merge, no unit
    check not (NoOps is Joinable)                # no merge
    check not (NoOps is CommutativeMonoid)
