## `Dynamic[T]` — the ◇-modality type for scalars.
##
## Lives in `primitives/` (not `dsl/`) because the dynamic floor produces
## `Dynamic[T]` values directly (e.g. `foldedDynamic` from M-δ). The
## `dynamic name: body` macro and `dynamicComputed` factory layer in
## `dsl/dynamic.nim` build on this primitive.
##
## See `docs/rfc-modal-tiers.md` for the modal framing — `Dynamic[T]`
## is `◇T` in the Davies-Pfenning sense, deliberately *not* a subtype
## of `Signal[T]` (`□T`). The subsumption rejection is what lets the
## C-shape walker distinguish dynamic-tier reads at sem time; a
## `Signal[T]` reference is guaranteed to point at a baked-height
## □-typed value, and a `Dynamic[T]` reference is guaranteed to point
## at a ◇-typed value with no height composition.


type
  Dynamic*[T] = ref object of Subscribable
    val*: T
      ## Exported so the substrate floor (`primitives/deltafloor`)
      ## can update it directly. Consumers do NOT write `.val`; the
      ## C-shape walker rejects raw writes via the `ReactiveRead` tag
      ## absence on field assignment. Reads should go through `.get()`
      ## or the call-operator (see `dsl/dynamic.nim`).

proc newDynamic[T](initial: T): Dynamic[T] =
  ## Substrate-internal constructor. Allocates a `Dynamic[T]` with
  ## `val = initial` and height 0; substrate floor procs (e.g.
  ## `foldedDynamic`) typically overwrite the height to reflect runtime
  ## composition from the source.
  Dynamic[T](val: initial)
