{.experimental: "callOperator".}
## Negative compile probe (intonaco#53): a DYNAMIC `computed` must be a HARD
## ERROR under -d:intonacoStrict, but compile (with a warning) without it.
## Verified by shell, not the runtime suite (a strict error can't live in a
## file the `nimble test` loop expects to run). See test_construct.nim notes.
import intonaco/reactive/signal
import intonaco/reactive/construct

let sigs = @[signal(0, label = "s0"), signal(1, label = "s1")]
signals:
  i = 0
computed bad: sigs[i()]()   # runtime-keyed -> DYNAMIC
