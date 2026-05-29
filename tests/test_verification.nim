## TDD: the shared diagnostic contract (intonaco#55).

import std/[unittest, options, strutils, sequtils]
import intonaco/reactive/analysis/diagnostic

proc diag(rule: GlossaryTerm, subject = "", symptom = "", fix = "",
          sev = sevError, id = 0, breaks: seq[string] = @[]): Diagnostic =
  Diagnostic(id: DiagnosticId(id), severity: sev, rule: rule,
             subject: SignalId(subject), symptom: symptom, fix: fix,
             breaksPreconditionOf: breaks.mapIt(SignalId(it)))

suite "render — developer-facing consequence message":
  test "1. render carries the glossary consequence + symptom + fix":
    let d = diag(gtReactiveCycle, symptom = "`total` references itself",
                 fix = "break the dependency or add a guard")
    let r = render(d)
    check "depends on itself" in r          # the glossary consequence sentence
    check "break the dependency" in r        # the fix

suite "validate — internal vocabulary stays off the developer surface":
  test "2. a clean diagnostic is valid":
    let d = diag(gtValueRule, symptom = "`progress` went above 1.0",
                 fix = "clamp the write")
    check validate(d).len == 0
  test "3. leaking an internal term (height/SCC) is rejected, naming it":
    let d = diag(gtRuntimeScheduled, symptom = "the height of `total` is 3",
                 fix = "shrink the SCC")
    let v = validate(d)
    check "height" in v
    check "scc" in v
  test "4. the expert channel bypasses the check":
    let d = diag(gtRuntimeScheduled, symptom = "the height of `total` is 3")
    check validate(d, expert = true).len == 0
  test "5. word-boundary: `weight` is not mistaken for `height`":
    let d = diag(gtValueRule, symptom = "the weight exceeded the tier-1 cap",
                 fix = "lower the weight")
    # `weight` must NOT match `height`; `tier-1` SHOULD match `tier`.
    let v = validate(d)
    check "height" notin v
    check "tier" in v

suite "group — a root cause pauses the downstream cascade":
  test "6. an error root pauses checks on the signals it breaks":
    let root = diag(gtReactiveCycle, subject = "x", sev = sevError, id = 1,
                    breaks = @["y"])
    let onY = diag(gtValueRule, subject = "y", sev = sevNote, id = 2)
    let shown = surfaced(group(@[root, onY]))
    check shown.len == 1                    # only the root surfaces
    check shown[0].id == DiagnosticId(1)
  test "7. a diagnostic not downstream of any error stays surfaced":
    let root = diag(gtReactiveCycle, subject = "x", sev = sevError, id = 1,
                    breaks = @["y"])
    let onZ = diag(gtValueRule, subject = "z", sev = sevNote, id = 2)
    check surfaced(group(@[root, onZ])).len == 2

suite "contract conformance — the consistency checker (#53) fits the contract":
  test "8. a checker reason that leaks `height` is caught; consequence phrasing passes":
    # classify currently produces "dependency has no static height" — INTERNAL.
    # The contract catches it, forcing a consequence rephrasing when #53 adopts it.
    let leaky = diag(gtRuntimeScheduled, subject = "total", sev = sevNote,
                     symptom = "dependency has no static height",
                     fix = "restructure the read")
    check "height" in validate(leaky)
    let clean = diag(gtRuntimeScheduled, subject = "total", sev = sevNote,
        symptom = "this depends on a value that isn't scheduled at compile time",
        fix = "restructure the read, or wrap it in `dynamic:`")
    check validate(clean).len == 0
    check "half-updated" in render(clean)
