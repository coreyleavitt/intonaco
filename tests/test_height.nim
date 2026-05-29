## TDD: compile-time height carrier (intonaco#51 / consistency direction 1).
## Compile-time primitives, tested via macros that reify a verdict into a
## runtime value the unittest checks (the test_purity pattern).

import std/[unittest, macros, options]
import intonaco/reactive/primitives/height
import height_ext   # exports `extNode` with a baked {.height: 2.}

# --- harness ----------------------------------------------------------------
macro heightLit(sym: typed): int =
  ## reify heightOf(sym) into a runtime int: the height, or -1 for none.
  let r = heightOf(sym)
  newLit(if r.isSome: r.get else: -1)

macro composeLit(deps: varargs[typed]): int =
  ## reify composeHeight(deps) into a runtime int: the height, or -1 for none.
  var ds: seq[NimNode]
  for d in deps: ds.add d
  let r = composeHeight(ds)
  newLit(if r.isSome: r.get else: -1)

macro bakeNode(name: untyped, deps: varargs[typed]): untyped =
  ## test harness: emit `let name {.height: composeHeight(deps).} = 0`.
  ## Composes the height from already-baked dep symbols and bakes it onto the
  ## new binding via withHeight — the compose+bake+read round-trip in one unit.
  var ds: seq[NimNode]
  for d in deps: ds.add d
  let h = composeHeight(ds)
  doAssert h.isSome, "bakeNode given an unresolvable dep"
  nnkLetSection.newTree(nnkIdentDefs.newTree(
    withHeight(name, h.get), newEmptyNode(), newLit(0)))

# --- fixtures ----------------------------------------------------------------
let baked {.height: 2.} = 0
let plain = 0
let dep0 {.height: 0.} = 0
let dep1 {.height: 1.} = 0

suite "heightOf (read a baked {.height:N.} via getImpl+eqIdent)":
  test "1. reads a baked pragma -> Some(N)":         check heightLit(baked) == 2
  test "1b. unannotated symbol -> none":             check heightLit(plain) == -1

suite "composeHeight (1 + max over dep heights)":
  test "2. deps {0,1} -> Some(2)":                   check composeLit(dep0, dep1) == 2
  test "2b. empty deps -> Some(0)":                  check composeLit() == 0
  test "3. any unresolvable dep -> none (no false 0)": check composeLit(dep0, plain) == -1

bakeNode(n4, dep0)

suite "withHeight (bake a height onto a binding; inverse of heightOf)":
  test "4. emitted binding round-trips through heightOf": check heightLit(n4) == 1

bakeNode(diaB, dep0)    # reads dep0{0} -> 1
bakeNode(diaD, diaB)    # reads diaB{1}, baked by the prior expansion -> 2

suite "compositional resolution (per-site, declaration-before-use)":
  test "5. diamond a{0} -> b{1} -> d{2} composes across bake steps":
    check heightLit(diaB) == 1
    check heightLit(diaD) == 2

suite "cross-module (the pragma rides .nim serialization)":
  test "6. heightOf resolves an imported baked binding": check heightLit(extNode) == 2
