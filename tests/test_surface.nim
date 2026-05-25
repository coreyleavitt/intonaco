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

suite "API surface":
  test "the runtime floor procs are off the blessed surface":
    check not compiles(createEffect(proc() = discard))
    check not compiles(createComputed(proc(): int = 1))
  test "the blessed escape (Dynamic[T]) IS reachable":
    let d = dynamicComputed(proc(): int = 1)
    check d() == 1
