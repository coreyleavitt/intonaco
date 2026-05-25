## The shared diagnostic contract (intonaco#55 / consistency RFC §"Developer
## experience"). Every compile-time checker across the five research directions
## emits `Diagnostic` values through THIS module so they compose by construction.
##
## DX is a SUBSTRATE concern; only *rendering to a surface* (terminal panel,
## web overlay, sinopia trace) is a frontend's job. The substrate guarantees:
##
##   - Diagnoses are tiered by DEVELOPER CONSEQUENCE (`Severity`), not by proof
##     internals: error = your program is wrong; note = I added a runtime check,
##     here's the cost; silent = you did nothing wrong.
##   - Developers see consequences (via the `GlossaryTerm` vocabulary), never
##     internal vocabulary (height / SCC / tier / worklist). `validate` rejects
##     a diagnostic that leaks internal terms outside the expert channel.
##   - A structural (error) root pauses the downstream checks it invalidates,
##     rather than emitting a cascade of derived noise (`group`).

import std/[options, strutils, macros]

type
  Severity* = enum
    sevSilent   ## you did nothing wrong (an expert/verbose channel item)
    sevNote     ## I added a runtime check / fell to runtime — here's the cost
    sevError    ## your program is wrong

  GlossaryTerm* = enum
    ## The consequence vocabulary — the UNION across all five directions'
    ## checkers. Each term maps (via `glossary`) to a developer-facing sentence;
    ## the exhaustive `glossary` case makes an un-glossaried term a compile error.
    gtReactiveCycle        ## consistency / guarded: a value depends on itself
    gtRuntimeScheduled     ## consistency: scheduled at runtime; could read a half-updated value
    gtValueRule            ## refinement: a value left its allowed range
    gtUsedMoreThanAllowed  ## substructural: a resource was used too many times
    gtUnproductiveLoop     ## guarded: a self-referential value never advances
    gtAllOrNothing         ## transactions: part of an all-or-nothing update didn't complete
    gtSafeMerge            ## convergence: concurrent updates may not merge safely

  SignalId* = distinct string
  DiagnosticId* = distinct int

  SourceSite* = object
    file*: string
    line*, col*: int

  Diagnostic* = object
    id*: DiagnosticId
    severity*: Severity
    rule*: GlossaryTerm
    subject*: SignalId                 ## the signal this diagnostic is ABOUT
    symptom*, fix*: string
    site*: SourceSite
    breaksPreconditionOf*: seq[SignalId]
    pausedBy*: Option[DiagnosticId]

proc `==`*(a, b: SignalId): bool {.borrow.}
proc `==`*(a, b: DiagnosticId): bool {.borrow.}

const internalTerms = ["height", "scc", "tier", "worklist", "fixpoint",
                       "monoid", "semilattice", "subscribable", "computation"]
  ## Proof-internal vocabulary — the union of the directions' internals. A
  ## diagnostic that leaks any of these to the developer surface is a checker
  ## bug; `validate` catches it.

iterator words(s: string): string =
  ## Alphanumeric runs, lowercased. Word-boundary tokenization so `weight` is
  ## not mistaken for `height` and `SCC`/`scc` both match.
  var cur = ""
  for ch in s:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9'}: cur.add ch.toLowerAscii
    elif cur.len > 0: yield cur; cur = ""
  if cur.len > 0: yield cur

proc validate*(d: Diagnostic, expert = false): seq[string] =
  ## The internal terms `d.symptom`/`d.fix` leak (empty = valid). The expert
  ## channel bypasses the check for tooling that genuinely wants proof internals.
  if expert: return @[]
  for field in [d.symptom, d.fix]:
    for w in field.words:
      if w in internalTerms and w notin result: result.add w

proc glossary*(t: GlossaryTerm): string =
  ## The developer-facing consequence sentence for each term — no internal
  ## vocabulary. The exhaustive case (no `else`) makes adding a `GlossaryTerm`
  ## without a consequence sentence a compile error.
  case t
  of gtReactiveCycle:       "this value depends on itself"
  of gtRuntimeScheduled:    "this could read a half-updated value"
  of gtValueRule:           "a value left its allowed range"
  of gtUsedMoreThanAllowed: "a resource was used more times than allowed"
  of gtUnproductiveLoop:    "a self-referential value never advances"
  of gtAllOrNothing:        "part of an all-or-nothing update didn't complete"
  of gtSafeMerge:           "concurrent updates may not merge safely"

proc group*(diags: seq[Diagnostic]): seq[Diagnostic] =
  ## Root-cause grouping: an `sevError` root pauses any OTHER diagnostic whose
  ## subject it breaks (`pausedBy` <- the root), so a structural error doesn't
  ## emit a cascade of derived noise. One level from error roots; transitive
  ## multi-level pausing is #58 (no checker produces a chain to test yet).
  result = diags
  for root in diags:
    if root.severity != sevError: continue
    for i in 0 ..< result.len:
      if result[i].id != root.id and result[i].subject in root.breaksPreconditionOf:
        result[i].pausedBy = some(root.id)

proc surfaced*(diags: seq[Diagnostic]): seq[Diagnostic] =
  ## The diagnostics to actually show — those not paused by a root cause.
  for d in diags:
    if d.pausedBy.isNone: result.add d

proc render*(d: Diagnostic): string =
  ## The substrate-baseline message: the subject (if named), the consequence,
  ## the symptom, and the fix. Richer renderings (a terminal panel, a web
  ## overlay, a sinopia trace) are a frontend's job — they consume the
  ## `Diagnostic`, not this string.
  let subj = string(d.subject)
  if subj.len > 0: result = "`" & subj & "`: "
  result &= glossary(d.rule)
  if d.symptom.len > 0: result &= " — " & d.symptom
  if d.fix.len > 0: result &= ". Fix: " & d.fix

proc siteOf*(n: NimNode): SourceSite {.compileTime.} =
  ## Build a `SourceSite` from a node's line info — the convenience a compile-
  ## time checker uses to locate the diagnostic at the offending source.
  let li = n.lineInfoObj
  SourceSite(file: li.filename, line: li.line, col: li.column)
