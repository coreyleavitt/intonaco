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
## `static: registerWalkPass(myPass)` at top level. By the time any binding
## macro fires `runAnalysis`, the pass-author module has been imported and
## registration has happened.
##
## Descend control: by default the walker skips into `nnkLambda`/`nnkProcDef`/
## `nnkFuncDef`/`nnkDo` bodies, matching the decide/act seam invariant from
## M10. Per-pass override is a YAGNI for now; if a future direction needs to
## descend into closures (e.g. guarded productivity #46), the hook gets added
## then.

import std/[macros]
import ./diagnostic

type
  Finding* = object
    ## A single check result from a pass. Lightweight compared to the full
    ## `Diagnostic` from `diagnostic.nim` — passes don't have to assemble
    ## subject/glossary/breaksPreconditionOf at construction time. M-α.4
    ## wires the Finding → Diagnostic translation.
    severity*: Severity
    message*: string
    site*: NimNode
    rule*: GlossaryTerm

  WalkContext* = object
    ## Information about the binding being walked. Most passes ignore this;
    ## refinement / substructural / future-direction passes use `deps`.
    deps*: seq[NimNode]   ## declared dep syms (post-Subscribable unwrap)
    body*: NimNode        ## the full body being analyzed

  PassCheck* = proc(node: NimNode, ctx: WalkContext): seq[Finding] {.nimcall.}

var registry {.compileTime.}: seq[PassCheck]

proc registerWalkPass*(p: PassCheck) {.compileTime.} =
  ## Register a pass. Called from a pass-author module's `static:` block.
  ## Idempotency is the caller's responsibility (today: register once per
  ## module-import; future: a `registeredPasses()` introspection helper).
  registry.add p

proc walkAst*(node: NimNode, ctx: WalkContext,
              findings: var seq[Finding]) {.compileTime.} =
  ## Recursive walk: apply every registered pass at this node; descend into
  ## children unless the node is a lambda/proc body.
  for p in registry:
    findings.add p(node, ctx)
  if node.kind notin {nnkLambda, nnkProcDef, nnkFuncDef, nnkDo}:
    for c in node:
      walkAst(c, ctx, findings)

macro runAnalysis*(body: typed, deps: typed): untyped =
  ## Walk `body` with every registered pass. Collect findings. Emit errors /
  ## warnings via Nim's compile-time `error`/`warning`. Return `body` on
  ## success (passthrough).
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
  for f in findings:
    case f.severity
    of sevError: error(f.message, f.site)
    of sevNote: warning(f.message, f.site)
    of sevSilent: discard
  result = body
