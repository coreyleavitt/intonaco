## intonaco's substrate-author surface.
##
## For consumers building new substrate templates / DSL macros / walker
## passes on top of intonaco. Not for typical user code — `intonaco/reactive`
## is the canonical user-facing aggregator (see M-β surface discipline).
##
## Use cases:
## - sinopia building trace bindings on top of the platform
## - Future research-direction implementations (refinement, substructural,
##   transactions, guarded productivity) adding modality-specific macros
## - Substrate-internal modules (this list, intonaco/task/, etc.)
##
## What's here: primitives + analysis layer. Plus the consumer surface
## via `intonaco/reactive` for ergonomic composition.

# Re-export the consumer surface — substrate authors typically also want
# user-facing macros available (e.g. they might emit `computed`/`effect`
# calls via bindSym).
import ./reactive
export reactive

# Substrate primitives — the runtime constructors substrate authors need
# direct access to.
import ./reactive/primitives/subscribable
import ./reactive/primitives/computation
import ./reactive/primitives/runtime
import ./reactive/primitives/deltafloor
import ./reactive/primitives/restoration
import ./reactive/primitives/convergence
export subscribable, computation, runtime, deltafloor, restoration, convergence

# Analysis layer — for substrate templates that emit `noUndeclaredSignals`
# walks, manipulate dep ASTs, or emit Diagnostics.
import ./reactive/analysis/walker
import ./reactive/analysis/ast
import ./reactive/analysis/diagnostic
export walker, ast, diagnostic
