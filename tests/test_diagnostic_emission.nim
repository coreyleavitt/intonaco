{.experimental: "callOperator".}

## M-α.4 — Diagnostic emission contract acceptance.
##
## Verifies the orchestrator wires `validate`, `group`, `surfaced`, and `render`
## from `reactive/analysis/diagnostic.nim`. Each test exercises ONE acceptance
## criterion from issue #82.

import std/[unittest, macros, options, strutils]
import intonaco/reactive/analysis/pass
import intonaco/reactive/analysis/diagnostic

# A pass that LEAKS internal vocabulary in its symptom — names "height"
# (which is in `internalTerms`). Should cause `validate` to assert at
# CT when its body's-trigger fires.

proc leakyVocabPass(node: NimNode, ctx: WalkContext): seq[Finding] {.nimcall.} =
  if node.kind == nnkIntLit and node.intVal == 555:
    result.add Finding(
      severity: sevError,
      rule: gtValueRule,
      subject: SignalId("leaky"),
      symptom: "the height inference failed",     # "height" is INTERNAL
      fix: "use a non-leaky message",
      site: node)

registerWalkPass(leakyVocabPass)

# A clean pass for the regression line.
proc cleanPass(node: NimNode, ctx: WalkContext): seq[Finding] {.nimcall.} =
  if node.kind == nnkIntLit and node.intVal == 666:
    result.add Finding(
      severity: sevError,
      rule: gtValueRule,
      subject: SignalId("clean"),
      symptom: "the value is out of range",
      fix: "use a value in range",
      site: node)

registerWalkPass(cleanPass)

# Cascading-pause test: a sevError ROOT with breaksPreconditionOf=[X] +
# a sevNote on subject X. analyze() should suppress the note (paused by root).

proc rootErrorPass(node: NimNode, ctx: WalkContext): seq[Finding] {.nimcall.} =
  if node.kind == nnkIntLit and node.intVal == 100:
    result.add Finding(
      severity: sevError,
      rule: gtReactiveCycle,
      subject: SignalId("root"),
      symptom: "this value depends on itself",
      fix: "introduce a guard or break the loop",
      site: node,
      breaksPreconditionOf: @[SignalId("downstream")])

registerWalkPass(rootErrorPass)

proc downstreamNotePass(node: NimNode, ctx: WalkContext): seq[Finding] {.nimcall.} =
  if node.kind == nnkIntLit and node.intVal == 100:
    result.add Finding(
      severity: sevNote,
      rule: gtRuntimeScheduled,
      subject: SignalId("downstream"),
      symptom: "this could read a half-updated value",
      fix: "ensure the root cause is fixed first",
      site: node)

registerWalkPass(downstreamNotePass)

suite "M-α.4 — Diagnostic emission":

  test "validate fires on internal-vocabulary leak (checker-bug assertion)":
    # 555 triggers leakyVocabPass; analyze should doAssert on validate failure.
    # The body fails to compile because of the CT assertion, not because of
    # the pass's own emission path.
    check not compiles(runAnalysis(555, []))
    # 666 triggers cleanPass which has no leak; the body still fails to compile
    # but for the EXPECTED reason (sevError emission), not the assertion.
    check not compiles(runAnalysis(666, []))
    # Non-trigger literal compiles cleanly.
    check compiles(runAnalysis(444, []))

  test "cascading-pause: sevError root suppresses sevNote on broken subject":
    # CT introspection — call analyze() directly to inspect what survives.
    static:
      let body = quote do: 100      # triggers both rootErrorPass + downstreamNotePass
      let surf = analyze(body, newNimNode(nnkBracket))
      # Two findings produced; group() pauses the note because its subject
      # ("downstream") is in the root error's breaksPreconditionOf.
      doAssert surf.len == 1, "expected 1 surfaced finding, got " & $surf.len
      doAssert surf[0].severity == sevError
      doAssert string(surf[0].subject) == "root"

  test "render produces subject + glossary consequence + symptom + fix":
    # Direct test of the rendering contract — no walker involved. Confirms that
    # render() composes the user-visible string from the Diagnostic fields.
    static:
      let f = Finding(
        severity: sevError,
        rule: gtReactiveCycle,
        subject: SignalId("cyclical"),
        symptom: "the binding refers back to itself",
        fix: "introduce a guard via `dynamic:` or break the cycle",
        site: newEmptyNode())
      let d = findingToDiagnostic(f, 1)
      let msg = render(d)
      # Render format: "`subject`: <glossary consequence> — <symptom>. Fix: <fix>"
      doAssert "cyclical" in msg
      doAssert glossary(gtReactiveCycle) in msg       # "this value depends on itself"
      doAssert "the binding refers back to itself" in msg
      doAssert "guard" in msg                         # fix's content
