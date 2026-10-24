// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "ximo-156/moonlint"

version = "0.2.0"

readme = "README.md"

repository = "https://github.com/ximo-156/wot-lynx-ui-moonbit"

license = "Apache-2.0"

keywords = [ "linter", "cli", "conventions", "static-analysis" ]

preferred_target = "native"

description = "A config-driven convention linter for source trees, ported from wot-lynx-ui's review-lint."

import {
  "moonbitlang/x@0.5.6",
}
