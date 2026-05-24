## Can the classifier DETECT, at compile time, an importc proc that takes a
## callback but lacks effectsOf? If getImpl exposes pragmas + params, yes —
## then we can ERROR ("annotate effectsOf or wrap in dynamic:") at the point
## a reactive body calls such a binding. Forcing at the boundary, not globally.
import std/macros

proc cWithEf(cb: proc(): int): int {.importc: "c1", effectsOf: cb.}
proc cNoEf(cb: proc(): int): int   {.importc: "c2".}
proc cNoCb(x: cint): cint          {.importc: "c3".}

macro inspect(p: typed): untyped =
  let impl = p.getImpl
  let prag = impl.pragma
  var isImportc, hasEffectsOf, hasCallback = false
  for pr in prag:
    let nm = (if pr.kind in {nnkExprColonExpr, nnkCall}: pr[0] else: pr)
    if nm.eqIdent("importc"): isImportc = true
    if nm.eqIdent("effectsOf"): hasEffectsOf = true
  let params = impl.params
  for i in 1 ..< params.len:
    if params[i][^2].kind == nnkProcTy: hasCallback = true
  echo "  ", p.repr, ": importc=", isImportc,
       " callback=", hasCallback, " effectsOf=", hasEffectsOf,
       "  -> ", (if isImportc and hasCallback and not hasEffectsOf:
                  "MUST ANNOTATE (error in strict)" else: "ok")
  result = newStmtList()

inspect(cWithEf)
inspect(cNoEf)
inspect(cNoCb)
