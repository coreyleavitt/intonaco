## M-δ walker quarantine probe: reading a `DynamicCollection` inside a
## static `effect` body without declaring it as a dep must be a
## walker-error (mirrors `Dynamic[T]`'s existing quarantine for scalars).
## This file is `nim check`-ed under the strictcheck task; a successful
## compile here is a regression.

{.experimental: "callOperator".}

include intonaco/reactive_internal   # uses substrate-internal newDynamicReactive

signals:
  trigger = 0
let dyn = newDynamicReactive[int](@[1, 2, 3])

effect [trigger]:               # ← `dyn` not in deps; reading it must error
  let _ = trigger
  let _ = dyn.get()
