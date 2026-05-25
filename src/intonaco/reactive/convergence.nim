## Convergence concepts (intonaco#54 / consistency RFC §"Concurrent async
## sources and convergence"). Classifies a value type's merge algebra so
## concurrent writes can be combined order-independently instead of serialized.
##
## HONESTY: a Nim `concept` recognizes that a type *has* a `merge` (structural,
## real); it CANNOT prove `merge` is associative/commutative/idempotent — those
## are semantic laws (a theorem prover's job). So:
##   - the CONCEPTS recognize shape (merge, and a unit for the monoid);
##   - the LAW witness-checks (`holds*`) verify the laws against values in the
##     compile-time VM — EXHAUSTIVE (hence a real proof) for finite types,
##     sampled (catches violations, not a proof) for infinite ones.
## We never claim the concept "verifies" a law.
##
## The propagation-identity token + serialize-vs-merge scheduler integration is
## the scheduler half, deferred to #60 (needs a concurrent-async-source consumer).

type
  CommutativeMonoid* = concept x, y
    ## Has an associative+commutative `merge` AND an identity `unit` (the
    ## structural distinction from `Joinable`). Laws are witness-checked, not
    ## structurally proven. E.g. a counter (int, `+`, 0).
    merge(x, y) is type(x)
    unit(type(x)) is type(x)

  Joinable* = concept x, y
    ## A join-semilattice: an associative+commutative+IDEMPOTENT `merge` (join).
    ## Idempotence (the duplicate-robust law) is witness-checked. No unit
    ## required. E.g. set-union, max.
    merge(x, y) is type(x)

proc allValues*[T: Ordinal](): seq[T] =
  ## Every value of a finite ordinal type — pass as `samples` to make a law
  ## witness-check EXHAUSTIVE (hence a real proof, not a sample).
  for v in low(T) .. high(T): result.add v

proc holdsCommutative*[T](op: proc(a, b: T): T, samples: openArray[T]): bool =
  ## `op(a,b) == op(b,a)` over `samples`. Exhaustive (proof) when `samples` is
  ## every value (see `allValues`); a violation-catcher otherwise.
  for a in samples:
    for b in samples:
      if op(a, b) != op(b, a): return false
  true

proc holdsAssociative*[T](op: proc(a, b: T): T, samples: openArray[T]): bool =
  ## `op(op(a,b),c) == op(a,op(b,c))` over `samples`.
  for a in samples:
    for b in samples:
      for c in samples:
        if op(op(a, b), c) != op(a, op(b, c)): return false
  true

proc holdsIdempotent*[T](op: proc(a, b: T): T, samples: openArray[T]): bool =
  ## `op(a,a) == a` over `samples` — the law that separates a `Joinable`
  ## (join-semilattice) from a mere `CommutativeMonoid`.
  for a in samples:
    if op(a, a) != a: return false
  true

proc converge*[T: CommutativeMonoid](writes: openArray[T]): T =
  ## Combine concurrent writes by folding `merge` from `unit`. Order-independent
  ## by the commutative-monoid laws (empty → the identity). This is what lets
  ## concurrent async sources merge instead of serialize.
  mixin merge, unit          # consumer-provided; resolve at instantiation
  result = unit(T)
  for w in writes: result = merge(result, w)
