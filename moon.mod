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

version = "0.3.0"

readme = "README.md"

repository = "https://github.com/ximo-156/wot-lynx-ui-moonbit"

license = "Apache-2.0"

keywords = [
  "moonbit",
  "static-analysis",
  "cli",
  "change-impact",
  "test-planning",
  "developer-tools",
]

preferred_target = "native"

description = "MoonImpact: change-impact and selective regression-test planning for MoonBit modules and Vue/TypeScript projects, written in MoonBit. Also ships the moonlint convention linter."

import {
  "moonbitlang/x@0.5.6",
}
