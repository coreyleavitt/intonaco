## Strict probe (promoted from the spike): an unbaked source (plain `signalC()`, no `signals:` pragma)
## used as a `computed` dep. Under `-d:intonacoStrict`, MUST be a hard
## compile error — proves the gate forbids silent dynamic fallback.

{.experimental: "callOperator".}

import intonaco/reactive

let raw = signalC(5)            # no {.height.} pragma — not in static fragment

computed doubled, [raw]:        # ← under strict, this line must error
  raw * 2

discard doubled
