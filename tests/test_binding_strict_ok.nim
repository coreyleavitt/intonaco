## Strict probe (promoted from the spike): all sources baked via `signals:` → should compile clean
## under `-d:intonacoStrict`. Proves the gate accepts the static fragment.

{.experimental: "callOperator".}

import intonaco/reactive/binding

signals:
  count = 0
  title = ""

computed doubled, [count]:
  count * 2

computed label, [count, doubled, title]:
  title & ": " & $count & " (" & $doubled & ")"

# Smoke: heights baked at compile time, readable now.
static:
  doAssert bakedHeight(count) == 0
  doAssert bakedHeight(doubled) == 1
  doAssert bakedHeight(label) == 2

# Use everything at module scope so it isn't dead-code eliminated.
discard doubled
discard label
