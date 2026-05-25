{.experimental: "callOperator".}
## Positive compile probe: reading a `Dynamic[T]` via the `dynamic:` escape must
## compile even under -d:intonacoStrict — the escape is the sanctioned floor.
import intonaco/reactive/dynamic
import intonaco/reactive/construct

let d = dynamicComputed(proc(): int = 1)
dynamic ok: d()   # explicit escape -> no strict error
