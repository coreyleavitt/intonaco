## Walker pass registry — M-α.2.
##
## The C-shape analysis surface as an extensible platform: research-direction
## modules register their own walker passes via `registerWalkPass`. At every
## binding macro's expansion the substrate orchestrator (`runAnalysis`) walks
## the typed body and invokes every registered pass at every node.
##
## A pass returns zero or more `Finding`s per node. Findings are collected
## across the walk; `sevError` severity becomes a compile error, `sevNote`
## becomes a warning, `sevSilent` is the expert/verbose-only channel.
##
## Registration is module-scoped at compile time; pass-author modules execute
## `registerWalkPass(myPass)` at top level. By the time any binding
## macro fires `runAnalysis`, the pass-author module has been imported and
## registration has happened.
##
## Descend control: by default the walker skips into `nnkLambda`/`nnkProcDef`/
## `nnkFuncDef`/`nnkDo` bodies, matching the decide/act seam invariant from
## M10. Per-pass override is a YAGNI for now; if a future direction needs to
## descend into closures (e.g. guarded productivity #46), the hook gets added
## then.

import std/[macros, options]
import ./diagnostic

type
  Finding* = object
    ## A check result from a pass — the structured draft of a `Diagnostic`.
    ## The pass owns the SEMANTIC content (subject, symptom, fix, the
    ## consequence rule, the cascading-pause breaks-precondition list); the
    ## orchestrator (`analyze`) fills in the bookkeeping (id, source-site
    ## translation, validate + group + surfaced filtering).
    severity*: Severity
    rule*: GlossaryTerm                ## the consequence vocabulary
    subject*: SignalId                 ## empty string if no specific subject
    symptom*: string                   ## what's wrong — NO internal vocab
    fix*: string                       ## actionable; NO internal vocab
    site*: NimNode                     ## for Nim's `error()`/`warning()` location
    breaksPreconditionOf*: seq[SignalId]   ## subjects this finding breaks (group())

  WalkContext* = object
    ## Information about the binding being walked. Most passes ignore this;
    ## refinement / substructural / future-direction passes use `deps`.
    deps*: seq[NimNode]   ## declared dep syms (post-Subscribable unwrap)
    body*: NimNode        ## the full body being analyzed

  PassCheck* = proc(node: NimNode, ctx: WalkContext): seq[Finding] {.nimcall.}

  RegisteredPass* = object
    ## A registered pass plus its symbol name (captured at registration time
    ## by the `registerWalkPass` macro). The name is for introspection /
    ## tooling — see `registeredPasses()`.
    name*: string
    check*: PassCheck

var registry {.compileTime.}: seq[RegisteredPass]

macro registerWalkPass*(p: typed): untyped =
  ## Register a pass at compile time. Captures the proc symbol's name so
  ## tooling can enumerate the registry via `registeredPasses()`.
  ##
  ## Call directly from a module's top level — no surrounding `static:`
  ## block is needed; the macro handles compile-time registration internally.
  let nameLit = newLit(p.repr)
  result = quote do:
    static:
      registry.add RegisteredPass(name: `nameLit`, check: `p`)

proc registeredPasses*(): seq[string] {.compileTime.} =
  ## Enumerate the names of every walker pass registered in this compilation.
  ## For tooling / debugging — IDEs and devtools can surface "what discipline
  ## is enforced" without instrumenting individual pass modules.
  for entry in registry:
    result.add entry.name

proc walkAst*(node: NimNode, ctx: WalkContext,
              findings: var seq[Finding]) {.compileTime.} =
  ## Recursive walk: apply every registered pass at this node; descend into
  ## children unless the node is a lambda/proc body.
  for entry in registry:
    findings.add entry.check(node, ctx)
  if node.kind notin {nnkLambda, nnkProcDef, nnkFuncDef, nnkDo}:
    for c in node:
      walkAst(c, ctx, findings)

proc findingToDiagnostic*(f: Finding, id: int): Diagnostic {.compileTime.} =
  ## Translate a `Finding` into a full `Diagnostic` for contract enforcement
  ## (`validate` + `group` + `render`). Source-site is built from the NimNode
  ## via `siteOf`.
  Diagnostic(
    id: DiagnosticId(id),
    severity: f.severity,
    rule: f.rule,
    subject: f.subject,
    symptom: f.symptom,
    fix: f.fix,
    site: siteOf(f.site),
    breaksPreconditionOf: f.breaksPreconditionOf,
    pausedBy: none(DiagnosticId)
  )

proc analyze*(body: NimNode, deps: NimNode): seq[Finding] {.compileTime.} =
  ## Walk `body` with every registered pass; translate each finding into a
  ## `Diagnostic`; assert no internal-vocabulary leakage via `validate`; apply
  ## `group` for cascading-pause; return ONLY the surfaced findings (those not
  ## paused by a sevError root).
  ##
  ## Stateless and pure at compile time — callable from `static:` blocks for
  ## introspection.
  var depSyms: seq[NimNode]
  for d in deps:
    var sym = d
    while sym.kind in {nnkCall, nnkHiddenCallConv, nnkHiddenStdConv, nnkConv} and
          sym.len >= 2:
      sym = sym[^1]
    depSyms.add sym
  let ctx = WalkContext(deps: depSyms, body: body)
  var findings: seq[Finding]
  walkAst(body, ctx, findings)
  var diagnostics: seq[Diagnostic]
  for i, f in findings:
    let d = findingToDiagnostic(f, i + 1)
    let leaks = validate(d)
    doAssert leaks.len == 0,
      "walker pass leaked internal vocabulary " & $leaks &
      " in symptom/fix; subject=" & string(f.subject) & " symptom=" & f.symptom
    diagnostics.add d
  let surfacedDiags = surfaced(group(diagnostics))
  var keptIds: seq[int]
  for d in surfacedDiags:
    keptIds.add int(d.id)
  for i, f in findings:
    if (i + 1) in keptIds:
      result.add f

macro runAnalysis*(body: typed, deps: typed): untyped =
  ## Walk `body` with every registered pass via `analyze`; render each
  ## surviving finding through `Diagnostic.render`; emit via Nim's compile-
  ## time `error`/`warning`. Return `body` on success.
  let surf = analyze(body, deps)
  for f in surf:
    let d = findingToDiagnostic(f, 0)
    let msg = render(d)
    case f.severity
    of sevError: error(msg, f.site)
    of sevNote: warning(msg, f.site)
    of sevSilent: discard
  result = body
