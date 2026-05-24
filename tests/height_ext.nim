## Helper module for test_height.nim slice 6: an exported binding carrying a
## baked `{.height.}` pragma, to prove the carrier rides `.nim` serialization
## and `heightOf` resolves it from an importing module.
import intonaco/reactive/height

let extNode* {.height: 2.} = 0
