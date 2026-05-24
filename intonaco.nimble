# Package metadata for intonaco — the compile-time-first reactive
# systems substrate. Sibling to fresco (terminal frontend) and the
# planned sinopia (trace frontend). See ../fresco/docs/rfc-intonaco-
# fresco-split.md for the architectural framing.

version       = "0.1.0"
author        = "Corey Leavitt"
description   = "Compile-time-first reactive substrate for Nim — signals/scopes/supervision/journal/caps over a chronos contextvar substrate."
license       = "Apache-2.0"
srcDir        = "src"

requires "nim >= 2.0.0"

# Async runtime: our chronos fork with the contextVar primitive that
# currentScope / currentSpeculative / parallelCollector ride on. NOT
# listed as a nimble `requires` — nimble v0.22.2's vnext SAT solver
# can't resolve chained URL requires. milpa (see ../milpa) fetches it
# from milpa.kdl into _deps/ and emits nim.cfg with the --path: lines.
# Run `milpa fetch` after cloning, then `nimble test`.

# Standalone substrate tests. The substrate is validated on its own —
# not only through fresco — per "intonaco leads; fresco is a canary,
# not a driver." New test files land here as they're written.
task test, "run intonaco's standalone tests":
  let tests = @[
    "tests/test_diamond_glitch.nim",
    "tests/test_depth_and_backfeedback.nim",
    "tests/test_effect_feedback.nim",
  ]
  for t in tests:
    exec "nim r --hints:off --warnings:off --path:src " & t
