{.experimental: "callOperator".}

## TDD: Dynamic[T] — the value-construction escape to the runtime floor
## (intonaco consistency direction). `dynamicComputed` / `dynamicEffect` build
## reactive nodes from `proc()` VALUES (no compile-time classification);
## `Dynamic[T]` is the height-uncomposable output that quarantines any reader
## to the dynamic tier (a `computed` reading it can never classify static).

import std/[unittest, macros, strutils, options]
import intonaco/reactive/signal
import intonaco/reactive/dynamic
import intonaco/reactive/classify
import intonaco/reactive/construct
import intonaco/reactive/height
import intonaco/verification

macro heightLit(sym: typed): int =
  ## The baked static height, or -1 if the binding carries no `{.height.}`
  ## pragma (i.e. it fell to the runtime floor).
  let r = heightOf(sym)
  newLit(if r.isSome: r.get else: -1)

macro classifyReason(body: typed): string =
  ## Reify the classifier's verdict for a body: "static" or the dynamic
  ## reason kind. Lets the quarantine be asserted through the public classifier.
  let c = classify(body)
  if c.tier == tStatic: newLit("static")
  else: newLit($c.reason.kind)

macro dynRender(body: typed): string =
  let action = archBAction(classify(body), false, false)
  newLit(render(toDiagnostic(action, "total", SourceSite())))

macro dynLeaks(body: typed): int =
  let action = archBAction(classify(body), false, false)
  newLit(validate(toDiagnostic(action, "total", SourceSite())).len)

suite "dynamicComputed — value-constructed derived value":
  test "1. produces a readable Dynamic[T] holding the computed value":
    let a = signal(3)
    let d = dynamicComputed(proc(): int = a() * 2)
    check d() == 6

suite "dynamicComputed — reactivity on the floor":
  test "2. re-runs on source change; observers of the Dynamic re-fire":
    let a = signal(3)
    let d = dynamicComputed(proc(): int = a() * 2)
    var seen: seq[int]
    createEffect(proc() = seen.add d())
    check seen == @[6]
    a.set(5)
    check d() == 10
    check seen == @[6, 10]

suite "dynamicEffect — value-constructed leaf effect":
  test "3. runs immediately, re-runs on dependency change, returns the handle":
    let a = signal(0)
    var observed: seq[int]
    let c = dynamicEffect(proc() = observed.add a())
    check observed == @[0]
    a.set(1)
    check observed == @[0, 1]
    check not c.disposed

let dd = dynamicComputed(proc(): int = 1)
proc readsViaHelper(): int = dd()   # reads a Dynamic transitively (through a proc)
signals:
  sa = 0

suite "quarantine: reading a Dynamic forces the dynamic tier":
  test "4. classify of a body reading a Dynamic -> tDynamic / drDynamicValue":
    check classifyReason(dd()) == "drDynamicValue"
  test "4b. a Dynamic read poisons an otherwise-static body":
    # `sa()` alone is static (baked height-0 source); composing it with `dd()`
    # must still fall to the dynamic tier — the Dynamic dominates.
    check classifyReason(sa() + dd()) == "drDynamicValue"
  test "7. a Dynamic read hidden behind a helper is caught transitively":
    # The accessor carries the reactive-read effect, so a body that reads a
    # Dynamic through a helper is flagged (the helper is the opacity boundary).
    check classifyReason(readsViaHelper()) == "drHiddenRead"

computed rfloor: dd()   # Dynamic read -> classified DYNAMIC -> runtime floor

suite "end-to-end: a computed reading a Dynamic falls to the floor":
  test "5a. unbaked (no static height) yet still reactive":
    check heightLit(rfloor) == -1   # no baked pragma — it's on the floor
    check rfloor() == 1             # value still flows through

suite "diagnostic: the Dynamic-read verdict":
  test "6. validate-clean, developer-vocabulary, names the subject + the value":
    check dynLeaks(dd()) == 0          # no internal vocabulary leak
    let msg = dynRender(dd())
    check "total" in msg               # subject prefix
    check "dd" in msg                  # names the Dynamic value read
    check "dynamic" in msg             # the developer-facing consequence/fix
