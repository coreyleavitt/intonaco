{.experimental: "callOperator".}
## Negative compile probe: a `computed` reading a `Dynamic[T]` must be a HARD
## ERROR under -d:intonacoStrict — a value built on the runtime floor can never
## be a statically-scheduled dependency. Verified by `nimble strictcheck`, not
## the runtime suite (a strict error can't live in a file `nimble test` runs).
import intonaco/reactive/dynamic
import intonaco/reactive/construct

let d = dynamicComputed(proc(): int = 1)
computed bad: d()   # Dynamic read -> DYNAMIC -> strict error
