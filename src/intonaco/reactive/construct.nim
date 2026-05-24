## Architecture-B construction layer (intonaco#53 / consistency RFC direction 1).
##
## The forced-static-default node constructors. `computed`/`effect` classify
## their body at compile time (#52) and:
##   - STATIC  -> bake the height (#51) onto the binding; the scheduler uses
##               the baked height with zero runtime accumulation.
##   - DYNAMIC -> fall to the sound runtime worklist floor, with a
##               consequence-tier warning naming what defeated static
##               resolution (a hard error under `-d:intonacoStrict`).
## `dynamic:` is the explicit escape hatch — force the floor, no warning.
##
## These are binding-owning STATEMENT macros (`computed name: body`) because
## the height pragma must sit on the *binding* for a dependent's `classify` to
## resolve it via `heightOf` — a proc on the RHS can't reach its own `let`.
## They build on the `createComputed`/`createEffect` procs (the runtime layer);
## those procs remain the explicit unclassified/dynamic path.

import std/[macros, options]
import ./signal
import ./classify
import ./height

type
  ArchBActionKind* = enum abBakeStatic, abFloor, abError
  ArchBAction* = object
    ## The construction policy's verdict — the pure decision, separated from
    ## the macro's emission (bake / warn / error) so soundness is unit-testable.
    case kind*: ArchBActionKind
    of abBakeStatic:
      height*: int             ## STATIC: bake this height
    of abFloor:
      reason*: string          ## runtime floor
      warn*: bool              ## emit a consequence-tier warning
    of abError:
      errReason*: string       ## strict-mode hard error

proc archBAction*(c: Classification, escapeHatch, strict: bool): ArchBAction =
  ## STATIC -> bake. DYNAMIC -> floor+warn, or a hard error under strict. The
  ## escape hatch (`dynamic:`) forces a silent floor regardless of the verdict.
  if escapeHatch:
    return ArchBAction(kind: abFloor, reason: "explicit dynamic:", warn: false)
  case c.tier
  of tStatic:
    ArchBAction(kind: abBakeStatic, height: c.height)
  of tDynamic:
    if strict: ArchBAction(kind: abError, errReason: c.reason)
    else: ArchBAction(kind: abFloor, reason: c.reason, warn: true)

proc floorMsg(subject, reason: string): string {.compileTime.} =
  subject & " can't be scheduled at compile time, so it falls to the runtime " &
  "scheduler — " & reason & ". Restructure the read, or wrap it in `dynamic:`."

proc strictMsg(subject, reason: string): string {.compileTime.} =
  subject & " can't be scheduled at compile time (-d:intonacoStrict) — " &
  reason & ". Restructure the read, or wrap it in `dynamic:`."

proc emitComputed(name, body: NimNode, escapeHatch: bool): NimNode {.compileTime.} =
  ## Shared construction for `computed` / `dynamic`. Classifies, applies the
  ## Architecture-B policy, and emits the binding: STATIC bakes the height onto
  ## `name`; the floor leaves it unbaked (runtime accumulates) with an optional
  ## warning; strict turns a dynamic node into a hard error.
  let action = archBAction(classify(body), escapeHatch, defined(intonacoStrict))
  let T = body.getTypeInst
  let lam = newProc(newEmptyNode(), @[T], body, nnkLambda)
  case action.kind
  of abBakeStatic:
    # Pass the baked height as fixedHeight so the runtime scheduler uses it
    # (zero accumulation), AND bake the pragma so dependents compose via heightOf.
    let ctor = newCall(bindSym"createComputed", lam,
      nnkExprEqExpr.newTree(ident"fixedHeight", newLit(action.height)))
    nnkLetSection.newTree(nnkIdentDefs.newTree(
      withHeight(name, action.height), newEmptyNode(), ctor))
  of abFloor:
    let ctor = newCall(bindSym"createComputed", lam)
    if action.warn: warning(floorMsg("`" & name.repr & "`", action.reason), body)
    nnkLetSection.newTree(nnkIdentDefs.newTree(name, newEmptyNode(), ctor))
  of abError:
    error(strictMsg("`" & name.repr & "`", action.errReason), body)
    nil

macro computed*(name: untyped, body: typed): untyped =
  ## A derived signal whose height is resolved at compile time when possible.
  ## STATIC: bake `{.height: h.}` onto `name` so dependents compose through it
  ## via `heightOf`. DYNAMIC: runtime floor + a consequence-tier warning
  ## (a hard error under `-d:intonacoStrict`).
  emitComputed(name, body, escapeHatch = false)

macro dynamic*(name: untyped, body: typed): untyped =
  ## Explicit escape hatch: construct via the runtime floor regardless of
  ## classification — no warning, and never a strict error. For genuinely-
  ## dynamic patterns (runtime-keyed reads, intentional graph-as-data).
  emitComputed(name, body, escapeHatch = true)

proc emitEffect(body: NimNode, escapeHatch: bool): NimNode {.compileTime.} =
  ## A leaf side-effect. Same Architecture-B policy as `computed`, but there's
  ## no binding to bake a pragma onto (nothing reads an effect) — the resolved
  ## height only fixes the effect's own scheduling order relative to its deps.
  let action = archBAction(classify(body), escapeHatch, defined(intonacoStrict))
  let lam = newProc(newEmptyNode(), @[newEmptyNode()], body, nnkLambda)
  case action.kind
  of abBakeStatic:
    newCall(bindSym"createEffect", lam,
      nnkExprEqExpr.newTree(ident"fixedHeight", newLit(action.height)))
  of abFloor:
    if action.warn: warning(floorMsg("this effect", action.reason), body)
    newCall(bindSym"createEffect", lam)
  of abError:
    error(strictMsg("this effect", action.errReason), body)
    nil

macro effect*(body: typed): untyped =
  ## A reactive side-effect, classified at construction like `computed`.
  ## STATIC bakes the firing height; DYNAMIC falls to the runtime floor with a
  ## consequence-tier warning (a hard error under `-d:intonacoStrict`).
  emitEffect(body, escapeHatch = false)
