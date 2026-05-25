{.experimental: "callOperator".}

## Fragment-size classifier spike (consistency RFC, Phase 3 mechanism).
##
## Measures the ANALYZER's reach + soundness, not a future app's fragment:
## for each dependency-read pattern in the real taxonomy, can a compile-time
## height be resolved (STATIC) or must it fall to the runtime tier (DYNAMIC)?
##
## The crux the corpus forced into the open: real bindings read signals
## DIRECTLY but wrap them in formatter calls (`"x: " & $sig()`). Soundness
## then hinges on whether the classifier descends into those calls to confirm
## they don't read a signal internally. So we measure two fragments:
##   - no-descent: bail on any call into a routine with a walkable body
##   - descent:    walk callee bodies; a call is safe iff its body has no
##                 signal read that isn't passed in as an argument
##
## A node is STATIC iff every signal read resolves to a directly-named signal
## symbol (height knowable) and no read is hidden behind an opaque call /
## alias / runtime index. Otherwise DYNAMIC (runtime height — always correct).

import std/[macros, strutils]
import intonaco/reactive/signal
import intonaco/reactive/runtime

# --- detection primitives (reimplemented; tracked.nim's are unexported) ----

proc isSignalTy(node: NimNode): bool =
  ## Signal-typed regardless of node KIND — `a` (Sym), `sigs[1]`
  ## (BracketExpr), `pick()` (Call) can all be Signal[T]. The earlier
  ## nnkSym-only guard was a SOUNDNESS HOLE: a Signal-typed indexed read
  ## slipped past detection and got misclassified STATIC.
  if node == nil or node.kind in {nnkEmpty, nnkNilLit}: return false
  let typ = node.getTypeInst
  typ != nil and typ.kind == nnkBracketExpr and typ.len >= 1 and
    typ[0].repr == "Signal"

proc isSignalRead(call: NimNode): bool =
  call.kind in {nnkCall, nnkCommand} and call.len >= 2 and isSignalTy(call[1])

proc directlyNamedSignal(recv: NimNode): bool =
  ## A read is height-resolvable iff its receiver is a directly-named
  ## Signal symbol (not an indexed expr, not an alias whose binding isn't
  ## a `signal(...)`/`createComputed(...)` factory call).
  if recv.kind != nnkSym: return false        # sigs[i]() — runtime-keyed
  let impl = recv.getImpl
  if impl.kind == nnkNilLit: return true       # param/import — treat as named
  let val = impl[^1]
  if val.kind notin {nnkCall, nnkCommand}: return false
  if val.len < 1 or val[0].kind != nnkSym: return false
  val[0].repr in ["signal", "createComputed"]  # alias if it's anything else

proc isOpaqueCall(call: NimNode, descend: bool,
                  reason: var string): bool =
  ## A non-signal-read call. Returns true (→ node is DYNAMIC) when the
  ## callee could hide a signal read we can't account for.
  if call.kind notin {nnkCall, nnkCommand}: return false
  let callee = call[0]
  if callee.kind != nnkSym: return false
  let impl = callee.getImpl
  if impl.kind == nnkNilLit:
    return false                               # magic/builtin (+, etc.) — pure
  if impl.kind notin {nnkProcDef, nnkFuncDef, nnkConverterDef}:
    return false
  # A routine with a walkable body. Without descent we must assume it
  # could read a signal internally → DYNAMIC.
  if not descend:
    reason = "opaque call `" & callee.repr & "` (no descent)"
    return true
  # With descent: walk the body; a signal read whose receiver is NOT one
  # of the proc's own parameters is a hidden global read → DYNAMIC.
  let params = impl[3]
  var paramNames: seq[string]
  for i in 1 ..< params.len:
    let idents = params[i]
    for j in 0 ..< idents.len - 2:
      paramNames.add idents[j].repr
  var hidden = false
  proc scan(n: NimNode) =
    if isSignalRead(n):
      let r = n[1]
      if r.kind != nnkSym or r.repr notin paramNames:
        hidden = true   # reads a signal not handed in as a parameter
    for c in n: scan(c)
  scan(impl)   # whole routine, not impl[^1] — body index isn't guaranteed
  if hidden:
    reason = "call `" & callee.repr & "` reads a signal internally"
    return true
  false

proc classify(body: NimNode, descend: bool): (bool, string) =
  ## (isStatic, reason). Walks the body; first disqualifier wins.
  var dynamic = false
  var reason = ""
  proc walk(n: NimNode) =
    if dynamic: return
    if isSignalRead(n):
      if not directlyNamedSignal(n[1]):
        dynamic = true
        reason = "read via " &
          (if n[1].kind != nnkSym: "runtime index/expr" else: "alias")
        return
      # resolvable direct read; recurse into its args (values)
      for c in n: walk(c)
      return
    if isOpaqueCall(n, descend, reason):
      dynamic = true
      return
    for c in n: walk(n = c)
  walk(body)
  (not dynamic, reason)

# Emit a one-line classification report at compile time, and return a bool
# (isStatic) the test can assert.
macro classifyND(body: typed): bool =
  ## no-descent classification
  let (isStatic, reason) = classify(body, descend = false)
  echo "  [no-descent] ", (if isStatic: "STATIC " else: "DYNAMIC"),
       "  ", body.repr.splitLines()[0][0..min(38, body.repr.splitLines()[0].high)],
       (if reason.len > 0: "   <- " & reason else: "")
  newLit(isStatic)

macro classifyD(body: typed): bool =
  ## with-descent classification
  let (isStatic, reason) = classify(body, descend = true)
  echo "  [  descent ] ", (if isStatic: "STATIC " else: "DYNAMIC"),
       "  ", body.repr.splitLines()[0][0..min(38, body.repr.splitLines()[0].high)],
       (if reason.len > 0: "   <- " & reason else: "")
  newLit(isStatic)

# --- helpers for the taxonomy --------------------------------------------

proc fmtBar(v: int): string = "[" & $v & "]"          # pure formatter (no read)
let g = signal(7, label = "g")
proc readsGlobal(): int = g() * 2                      # HIDDEN read of g

import std/unittest

suite "fragment classifier — pattern taxonomy (descent off vs on)":

  let a = signal(1, label = "a")
  let b = signal(2, label = "b")
  let cond = signal(true, label = "cond")
  let sigs = @[signal(0, label="s0"), signal(0, label="s1")]
  let alias = a

  test "1. direct single read":
    check classifyND(a()) == true
    check classifyD(a()) == true

  test "2. multi direct + operator":
    check classifyND(a() + b()) == true
    check classifyD(a() + b()) == true

  test "3. formatter-wrapped direct read (the corpus's dominant pattern)":
    check classifyD("x: " & $a()) == true        # descent confirms $,& are pure
    discard classifyND("x: " & $a())             # observe: does it bail?

  test "4. pure custom formatter on a read value":
    check classifyD(fmtBar(a())) == true
    discard classifyND(fmtBar(a()))

  test "5. conditional read (both branches direct)":
    check classifyD(if cond(): a() else: b()) == true
    check classifyND(if cond(): a() else: b()) == true

  test "6. helper proc with a HIDDEN signal read":
    check classifyD(readsGlobal()) == false      # descent finds the hidden read
    check classifyND(readsGlobal()) == false     # no-descent bails too (sound)

  test "7. alias read":
    discard classifyD(alias())
    discard classifyND(alias())

  test "8. runtime-keyed read (dynamic topology)":
    check classifyD(sigs[1]()) == false
    check classifyND(sigs[1]()) == false
