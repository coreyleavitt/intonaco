{.experimental: "callOperator".}

## M-α.3 — substrate-template authoring kit acceptance.
##
## Each test builds a new substrate-template macro using the kit (replicating
## what sinopia, future research-direction modules, etc. would do) and verifies
## the resulting macro behaves end-to-end like the canonical computed/effect.

import std/[unittest, macros]
include intonaco/reactive_internal

# A new substrate template family built entirely from the kit — proves the
# 7-line definition pattern.

macro myComputedInner(name: untyped, deps: typed, body: untyped,
                      origDeps: untyped): untyped =
  compileBindingInner(name, deps, body, origDeps,
                      bindSym"computedC", ekComputedShape, "myComputed")

macro myComputed*(name, deps, body): untyped =
  wrapDepsForInner(bindSym"myComputedInner", name, deps, body)

# A custom effect-shape macro built entirely from the kit.

macro myEffectInner(deps: typed, body: untyped, origDeps: untyped): untyped =
  compileBindingInner(newEmptyNode(), deps, body, origDeps,
                      bindSym"effectC", ekEffectShape, "myEffect")

macro myEffect*(deps, body): untyped =
  wrapDepsForInnerNoName(bindSym"myEffectInner", deps, body)

suite "M-α.3 — substrate-template authoring kit":

  test "compileBindingInner builds a working computed-shape macro end-to-end":
    signals:
      x = 5
    myComputed y, [x]:
      x * 2
    check y() == 10
    x := 7
    check y() == 14

  test "kit bakes {.height.} pragma at compile time":
    signals:
      base = 0
    myComputed derived, [base]:
      base + 1
    # base has baked height 0 → derived has baked height 1
    check bakedHeight(derived) == 1

  test "kit's walker integration rejects undeclared signal reads":
    # An undeclared Signal[_] sym in body must be a compile error — the kit
    # invokes runAnalysis transparently, so the three core passes fire.
    let stray = signalC(0)
    check not compiles(block:
      signals:
        z = 1
      myComputed badBinding, [z]:
        z + stray.get())       # stray is Signal[int], not in deps → ERROR

  test "kit can build an effect-shape macro (no name, no let)":
    signals:
      trigger = 0
    var fires = 0
    discard createRoot:
      myEffect [trigger]:
        inc fires
        discard trigger          # use the dep so its read is observed
    check fires == 1
    trigger := 1
    check fires == 2
    trigger := 2
    check fires == 3
