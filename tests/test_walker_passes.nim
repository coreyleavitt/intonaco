{.experimental: "callOperator".}

## M-α.2 — walker pass registry acceptance tests.
##
## Each test exercises a behavior of the extension contract: a pass can
## register itself, fires at every node, returns findings that translate to
## compile-time errors / warnings, and the lambda-skip invariant from M10
## is preserved.

import std/[unittest, macros]
import intonaco/reactive/analysis/pass
import intonaco/reactive/analysis/diagnostic
import intonaco/reactive/analysis/passes_core   # registers the three core passes
import intonaco/reactive/primitives/signal

# A custom pass for testing: rejects any int literal whose value is 42.
proc no42Pass(node: NimNode, ctx: WalkContext): seq[Finding] {.nimcall.} =
  if node.kind == nnkIntLit and node.intVal == 42:
    result.add Finding(
      severity: sevError,
      message: "the literal 42 is forbidden by no42Pass",
      site: node,
      rule: gtValueRule)

static: registerWalkPass(no42Pass)

# A note-severity pass: 99 is suspicious but not fatal.
proc note99Pass(node: NimNode, ctx: WalkContext): seq[Finding] {.nimcall.} =
  if node.kind == nnkIntLit and node.intVal == 99:
    result.add Finding(
      severity: sevNote,
      message: "the literal 99 is suspicious (note from note99Pass)",
      site: node,
      rule: gtRuntimeScheduled)

static: registerWalkPass(note99Pass)

# A dep-aware pass: errors only if ctx.deps is empty AND body contains 77.
# Demonstrates that passes can use ctx.deps to vary their check.
proc dep77Pass(node: NimNode, ctx: WalkContext): seq[Finding] {.nimcall.} =
  if node.kind == nnkIntLit and node.intVal == 77 and ctx.deps.len == 0:
    result.add Finding(
      severity: sevError,
      message: "77 is forbidden when deps bracket is empty",
      site: node,
      rule: gtValueRule)

static: registerWalkPass(dep77Pass)

suite "M-α.2 — walker pass registry":

  test "a registered pass that errors causes the body's compilation to fail":
    # 42 is forbidden by no42Pass.
    check not compiles(runAnalysis(42, []))
    # 41 is fine — no42Pass doesn't fire.
    check compiles(runAnalysis(41, []))

  test "NoUndeclaredSignalReadPass fires on a Signal[_]-typed sym in body":
    let stray = signal(0)
    # `stray` is Signal[int] — not in deps bracket — pass errors at compile time
    check not compiles(runAnalysis(stray, []))
    # An int literal is fine — Signal-read pass doesn't fire on non-reactive types
    check compiles(runAnalysis(123, []))

  test "a sevNote pass emits a warning but compilation succeeds":
    # The note99Pass registers a sevNote on int literal 99 — not fatal.
    # Compilation succeeds; only the warning channel sees the emission.
    check compiles(runAnalysis(99, []))

  test "lambda bodies are not descended into (decide/act seam preserved)":
    # The walker skips into nnkLambda/nnkProcDef bodies — their reads run
    # in a separate reactive frame. A 42 inside a lambda body is invisible
    # to no42Pass; the binding compiles cleanly.
    check compiles(runAnalysis((proc(): int = 42)(), []))
    # Sanity: a 42 outside any lambda still triggers no42Pass.
    check not compiles(runAnalysis(42, []))

  test "passes receive ctx.deps (the declared dep sym list)":
    # 77 in body + empty deps bracket → dep77Pass fires.
    check not compiles(runAnalysis(77, []))
    # 77 in body + non-empty deps → dep77Pass suppresses by ctx.deps.len > 0.
    # The dep value isn't reactive-typed so NoUndeclaredSignalReadPass stays
    # silent; only dep77Pass cares about ctx.deps here.
    check compiles(runAnalysis(77, [42]))
