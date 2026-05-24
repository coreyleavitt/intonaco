{.experimental: "callOperator".}
## Positive compile probe (intonaco#53): the same dynamic pattern via the
## `dynamic:` escape hatch must compile even under -d:intonacoStrict.
import intonaco/reactive/signal
import intonaco/reactive/construct

let sigs = @[signal(0, label = "s0"), signal(1, label = "s1")]
signals:
  i = 0
dynamic ok: sigs[i()]()   # escape hatch -> no strict error
