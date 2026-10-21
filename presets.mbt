///|
/// Built-in framework presets.
///
/// A preset is a named, ready-to-use rule set for a popular frontend
/// framework. Presets are defined as MoonBit data (not JSON strings) so the
/// patterns stay readable and cannot drift from what the engine compiles.
/// The same rule sets are also shipped as JSON files under `presets/` for
/// users who prefer to copy and customize them.
///
/// Presets are pure rule collections: they carry no global scope, so merging
/// several presets is a simple concatenation with de-duplication by rule id
/// (the first occurrence wins). Rule-level `include` / `exclude` scopes are
/// preserved as declared.
///
/// Every rule is line-oriented: it matches one source line at a time, after
/// comments have been blanked out. Rules that need an AST (unused variables,
/// hook dependencies, prop types) are intentionally absent — moonlint is a
/// convention linter, not a type checker.

///|
/// A built-in preset: a name, a one-line description, and its rules.
pub struct Preset {
  /// Stable preset name, e.g. `react`.
  name : String
  /// One-line description shown by `--list-presets`.
  description : String
  /// The preset's rules, in declaration order.
  rules : Array[Rule]
  /// The preset's file-level rules.
  file_rules : Array[FileRule]
}

///|
/// Shorthand constructor for a rule with no `unless` guard and no scope.
fn rule(
  id : String,
  severity : Severity,
  message : String,
  extensions : Array[String],
  match_ : MatchKind,
) -> Rule {
  Rule::{
    id,
    severity,
    message,
    extensions,
    match_,
    unless: None,
    scope: Scope::empty(),
  }
}

///|
/// Shorthand constructor for a rule with an `unless` guard.
fn guarded_rule(
  id : String,
  severity : Severity,
  message : String,
  extensions : Array[String],
  match_ : MatchKind,
  unless : MatchKind,
) -> Rule {
  Rule::{
    id,
    severity,
    message,
    extensions,
    match_,
    unless: Some(unless),
    scope: Scope::empty(),
  }
}

// ---------------------------------------------------------------------------
// common — framework-agnostic JavaScript/TypeScript hygiene
// ---------------------------------------------------------------------------

///|
fn common_rules() -> Array[Rule] {
  [
    rule(
      "common/no-console-log",
      Severity::warning(),
      "Avoid console.log in committed code",
      [".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".vue", ".svelte"],
      Contains("console.log"),
    ),
    rule(
      "common/no-debugger",
      Severity::error(),
      "No debugger statements",
      [".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".vue", ".svelte"],
      Regex("^[[:space:]]*debugger[[:space:]]*;?[[:space:]]*$"),
    ),
    rule(
      "common/no-alert",
      Severity::warning(),
      "Avoid alert(), confirm() and prompt() in production code",
      [".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".vue", ".svelte"],
      Regex("\\b(alert|confirm|prompt)\\("),
    ),
    rule(
      "common/no-eval",
      Severity::error(),
      "Avoid eval() and its implicit forms",
      [".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".vue", ".svelte"],
      Regex("\\beval\\("),
    ),
    rule(
      "common/no-var",
      Severity::warning(),
      "Use let or const instead of var",
      [".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".vue", ".svelte"],
      Regex("\\bvar[[:space:]]"),
    ),
  ]
}

// ---------------------------------------------------------------------------
// react — React and JSX conventions
// ---------------------------------------------------------------------------

///|
fn react_rules() -> Array[Rule] {
  let jsx = [".jsx", ".tsx"]
  [
    rule(
      "react/no-danger",
      Severity::error(),
      "Avoid dangerouslySetInnerHTML (XSS risk)",
      jsx,
      Contains("dangerouslySetInnerHTML"),
    ),
    rule(
      "react/no-find-dom-node",
      Severity::error(),
      "Avoid findDOMNode (breaks encapsulation)",
      jsx,
      Contains("findDOMNode"),
    ),
    rule(
      "react/no-string-refs",
      Severity::error(),
      "Avoid string refs; use callback refs or createRef",
      jsx,
      Regex("(^|[[:space:]])ref=\""),
    ),
    rule(
      "react/no-children-prop",
      Severity::error(),
      "Avoid passing children as a prop; use nesting instead",
      jsx,
      Contains("children="),
    ),
    rule(
      "react/no-array-index-key",
      Severity::warning(),
      "Avoid using the array index as a key",
      jsx,
      Regex("key=\\{(i|idx|[[:alpha:]_]*(?i:index)[[:alpha:]_]*)\\}"),
    ),
    rule(
      "react/no-deprecated",
      Severity::error(),
      "Avoid deprecated lifecycle methods (componentWillMount/ReceiveProps/Update)",
      jsx,
      Regex("componentWillMount|componentWillReceiveProps|componentWillUpdate"),
    ),
    rule(
      "react/no-is-mounted",
      Severity::error(),
      "Avoid isMounted (anti-pattern)",
      jsx,
      Regex("\\.isMounted\\("),
    ),
    rule(
      "react/prefer-es6-class",
      Severity::error(),
      "Avoid React.createClass; use ES6 classes or function components",
      jsx,
      Regex("React\\.createClass|createReactClass"),
    ),
    rule(
      "react/self-closing-comp",
      Severity::warning(),
      "Use self-closing tags for empty elements",
      jsx,
      Regex("></[[:alpha:]][[:alnum:]]*>"),
    ),
    guarded_rule(
      "react/jsx-no-target-blank",
      Severity::warning(),
      "target=\"_blank\" without rel=\"noopener\" is a security risk",
      jsx,
      Regex("target=\"_blank\""),
      Regex("noopener"),
    ),
    rule(
      "react/jsx-no-script-url",
      Severity::error(),
      "Avoid javascript: URLs in href",
      jsx,
      Regex("href=\"javascript:"),
    ),
    rule(
      "react/style-prop-object",
      Severity::error(),
      "The style prop must be an object, not a string",
      jsx,
      Regex("(^|[[:space:]])style=\""),
    ),
    rule(
      "react/jsx-props-no-spreading",
      Severity::warning(),
      "Avoid spreading props ({...props}); pass them explicitly",
      jsx,
      Regex("\\{\\.\\.\\."),
    ),
    rule(
      "react/jsx-curly-brace-presence",
      Severity::warning(),
      "Remove unnecessary curly braces around string literals",
      jsx,
      Regex("=\\{\"[^\"]*\"\\}"),
    ),
    rule(
      "react/jsx-boolean-value",
      Severity::warning(),
      "Use shorthand for boolean props (disabled instead of disabled={true})",
      jsx,
      Regex("=\\{true\\}"),
    ),
    rule(
      "react/no-unknown-property",
      Severity::error(),
      "Use className instead of class in JSX",
      jsx,
      Regex("(^|[[:space:]])class="),
    ),
    guarded_rule(
      "react/button-has-type",
      Severity::warning(),
      "Buttons must have an explicit type attribute",
      jsx,
      Regex("<button"),
      Regex("type="),
    ),
    guarded_rule(
      "react/iframe-missing-sandbox",
      Severity::warning(),
      "iframes must have a sandbox attribute",
      jsx,
      Regex("<iframe"),
      Regex("sandbox="),
    ),
    rule(
      "react/jsx-fragments",
      Severity::warning(),
      "Use <>...</> instead of <React.Fragment>",
      jsx,
      Regex("<React\\.Fragment"),
    ),
    rule(
      "react/jsx-no-bind",
      Severity::warning(),
      "Avoid .bind(this) in JSX; use class properties or arrow functions",
      jsx,
      Regex("\\.bind\\(this\\)"),
    ),
  ]
}

// ---------------------------------------------------------------------------
// vue — Vue 3 template and SFC conventions
// ---------------------------------------------------------------------------

///|
fn vue_rules() -> Array[Rule] {
  let vue_exts = [".vue", ".js", ".ts"]
  [
    rule(
      "vue/no-v-html",
      Severity::warning(),
      "Avoid v-html (XSS risk); use text interpolation or a sanitizer",
      vue_exts,
      Contains("v-html"),
    ),
    guarded_rule(
      "vue/require-v-for-key",
      Severity::error(),
      "v-for requires a :key binding",
      vue_exts,
      Regex("v-for"),
      Regex(":key|v-bind:key"),
    ),
    rule(
      "vue/no-use-v-if-with-v-for",
      Severity::error(),
      "Avoid using v-if and v-for on the same element",
      vue_exts,
      Regex("v-for[^>]*v-if|v-if[^>]*v-for"),
    ),
    guarded_rule(
      "vue/require-component-is",
      Severity::error(),
      "<component> requires an :is binding",
      vue_exts,
      Regex("<component"),
      Regex(":is=|v-bind:is="),
    ),
    rule(
      "vue/this-in-template",
      Severity::error(),
      "Avoid using this in templates; use setup bindings or computed",
      vue_exts,
      Regex("\\{\\{[^}]*this\\."),
    ),
    guarded_rule(
      "vue/require-scoped-style",
      Severity::warning(),
      "Component <style> blocks should be scoped",
      [".vue"],
      Regex("<style"),
      Regex("scoped"),
    ),
    rule(
      "vue/no-static-inline-styles",
      Severity::warning(),
      "Avoid static inline styles; use :style binding or classes",
      vue_exts,
      Regex("(^|[[:space:]])style=\""),
    ),
    rule(
      "vue/prefer-true-attribute-shorthand",
      Severity::warning(),
      "Use shorthand for true attributes (:disabled instead of :disabled=\"true\")",
      vue_exts,
      Regex(":[[:alpha:]-]+=\"true\""),
    ),
    rule(
      "vue/no-useless-mustaches",
      Severity::warning(),
      "Remove unnecessary mustaches around string literals",
      vue_exts,
      Regex("\\{\\{[[:space:]]*\"[^\"]*\"[[:space:]]*\\}\\}"),
    ),
    rule(
      "vue/no-v-text",
      Severity::warning(),
      "Use mustache interpolation instead of v-text",
      vue_exts,
      Contains("v-text"),
    ),
    guarded_rule(
      "vue/no-target-blank",
      Severity::warning(),
      "target=\"_blank\" without rel=\"noopener\" is a security risk",
      vue_exts,
      Regex("target=\"_blank\""),
      Regex("noopener"),
    ),
  ]
}

// ---------------------------------------------------------------------------
// angular — Angular component and template conventions
// ---------------------------------------------------------------------------

///|
fn angular_rules() -> Array[Rule] {
  let ts = [".ts"]
  [
    rule(
      "angular/no-input-rename",
      Severity::error(),
      "Avoid renaming @Input() with an alias",
      ts,
      Regex("@Input\\(['\"]"),
    ),
    rule(
      "angular/no-output-rename",
      Severity::error(),
      "Avoid renaming @Output() with an alias",
      ts,
      Regex("@Output\\(['\"]"),
    ),
    rule(
      "angular/no-output-native",
      Severity::error(),
      "Avoid @Output() names that collide with native DOM events",
      ts,
      Regex(
        "@Output\\(\\)[[:space:]]*(click|change|focus|blur|submit|input|keydown|keyup|keypress|mousedown|mouseup|mouseenter|mouseleave|dblclick|contextmenu|wheel|scroll|select|load|error|abort|resize)",
      ),
    ),
    rule(
      "angular/no-output-on-prefix",
      Severity::warning(),
      "Avoid the on prefix in @Output() names",
      ts,
      Regex("@Output\\(\\)[[:space:]]*on"),
    ),
    rule(
      "angular/no-input-prefix",
      Severity::warning(),
      "Avoid the on prefix in @Input() names",
      ts,
      Regex("@Input\\(\\)[[:space:]]*on"),
    ),
    rule(
      "angular/no-forward-ref",
      Severity::warning(),
      "Avoid forwardRef; restructure dependencies instead",
      ts,
      Contains("forwardRef"),
    ),
    rule(
      "angular/no-host-metadata-property",
      Severity::warning(),
      "Use @HostListener instead of the host metadata property",
      ts,
      Regex("^[[:space:]]*host:"),
    ),
    rule(
      "angular/no-attribute-decorator",
      Severity::error(),
      "Avoid @Attribute(); use @Inject() or a service instead",
      ts,
      Regex("@Attribute\\("),
    ),
    guarded_rule(
      "angular/relative-url-prefix",
      Severity::error(),
      "Relative templateUrl/styleUrls must start with ./",
      ts,
      Regex("templateUrl:|styleUrls?:"),
      Regex("(templateUrl|styleUrls?):[[:space:]]*\\[?[[:space:]]*['\"]\\./"),
    ),
  ]
}

// ---------------------------------------------------------------------------
// svelte — Svelte component conventions
// ---------------------------------------------------------------------------

///|
fn svelte_rules() -> Array[Rule] {
  let svelte = [".svelte"]
  [
    rule(
      "svelte/no-at-html-tags",
      Severity::warning(),
      "Avoid {@html} (XSS risk); use text interpolation or a sanitizer",
      svelte,
      Regex("\\{@html"),
    ),
    guarded_rule(
      "svelte/no-target-blank",
      Severity::warning(),
      "target=\"_blank\" without rel=\"noopener\" is a security risk",
      svelte,
      Regex("target=\"_blank\""),
      Regex("noopener"),
    ),
    guarded_rule(
      "svelte/require-each-key",
      Severity::error(),
      "{#each} blocks require a key expression",
      svelte,
      Regex("\\{#each"),
      Regex("\\([^)]+\\)\\}"),
    ),
    rule(
      "svelte/no-reactive-literals",
      Severity::warning(),
      "Avoid reactive statements that assign a literal",
      svelte,
      Regex(
        "\\$:[[:space:]]*[[:alpha:]_$][[:alnum:]_$]*[[:space:]]*=[[:space:]]*[\"'[:digit:]]",
      ),
    ),
    rule(
      "svelte/prefer-style-directive",
      Severity::warning(),
      "Use the style: directive instead of inline style with interpolation",
      svelte,
      Regex("style=\"[^\"]*\\{"),
    ),
    guarded_rule(
      "svelte/a11y-mouse-events-have-key-events",
      Severity::warning(),
      "on:mouseover/on:mouseout must be paired with keyboard events",
      svelte,
      Regex("on:mouseover|on:mouseout"),
      Regex("on:keydown|on:keyup|on:focus|on:blur"),
    ),
    guarded_rule(
      "svelte/a11y-missing-attribute",
      Severity::error(),
      "<img> requires an alt attribute",
      svelte,
      Regex("<img"),
      Regex("alt="),
    ),
    guarded_rule(
      "svelte/no-goto-without-base",
      Severity::warning(),
      "goto() with a relative URL requires a base option",
      svelte,
      Regex("goto\\("),
      Regex("goto\\(['\"]/"),
    ),
  ]
}

// ---------------------------------------------------------------------------
// next — Next.js conventions
// ---------------------------------------------------------------------------

///|
fn next_rules() -> Array[Rule] {
  let next_exts = [".jsx", ".tsx", ".js", ".ts"]
  [
    rule(
      "next/no-html-link-for-pages",
      Severity::warning(),
      "Use <Link> instead of <a> for internal pages",
      next_exts,
      Regex("<a[^>]*href=\"/"),
    ),
    rule(
      "next/no-img-element",
      Severity::warning(),
      "Use next/image instead of <img>",
      next_exts,
      Regex("<img"),
    ),
    rule(
      "next/no-head-element",
      Severity::warning(),
      "Use next/head instead of <head>",
      next_exts,
      Regex("<head"),
    ),
    rule(
      "next/no-css-tags",
      Severity::warning(),
      "Use CSS imports instead of <link rel=\"stylesheet\">",
      next_exts,
      Regex("<link[^>]*rel=\"stylesheet\""),
    ),
    guarded_rule(
      "next/no-sync-scripts",
      Severity::warning(),
      "Synchronous <script src> blocks rendering; add async or defer",
      next_exts,
      Regex("<script[^>]*src="),
      Regex("async|defer"),
    ),
    guarded_rule(
      "next/google-font-display",
      Severity::warning(),
      "Google Fonts links must include &display=swap",
      next_exts,
      Regex("fonts.googleapis.com"),
      Regex("display=swap"),
    ),
    rule(
      "next/no-unwanted-polyfillio",
      Severity::error(),
      "polyfill.io is a security risk; remove it",
      next_exts,
      Contains("polyfill.io"),
    ),
  ]
}

// ---------------------------------------------------------------------------
// solid — SolidJS conventions
// ---------------------------------------------------------------------------

///|
fn solid_rules() -> Array[Rule] {
  let solid_exts = [".jsx", ".tsx"]
  [
    rule(
      "solid/no-innerhtml",
      Severity::error(),
      "Avoid innerHTML (XSS risk); use textContent or JSX",
      solid_exts,
      Contains("innerHTML"),
    ),
    rule(
      "solid/no-dangerous-html",
      Severity::error(),
      "Avoid dangerouslySetInnerHTML in Solid; use innerHTML with sanitized content",
      solid_exts,
      Contains("dangerouslySetInnerHTML"),
    ),
    rule(
      "solid/prefer-for",
      Severity::warning(),
      "Use <For> instead of .map() for list rendering in Solid",
      solid_exts,
      Regex("\\.map\\("),
    ),
    rule(
      "solid/prefer-show",
      Severity::warning(),
      "Use <Show> instead of ternary for conditional rendering in Solid",
      solid_exts,
      Regex("\\?[[:space:]]*<"),
    ),
    rule(
      "solid/no-react-imports",
      Severity::error(),
      "Do not import from 'react' in a Solid project",
      solid_exts,
      Regex("from[[:space:]]+['\"]react['\"]"),
    ),
    rule(
      "solid/event-directives",
      Severity::warning(),
      "Use on:click instead of onClick in Solid JSX",
      solid_exts,
      Regex("onClick=|onChange=|onInput="),
    ),
  ]
}

// ---------------------------------------------------------------------------
// astro — Astro conventions
// ---------------------------------------------------------------------------

///|
fn astro_rules() -> Array[Rule] {
  let astro_exts = [".astro"]
  [
    rule(
      "astro/no-set-html-directive",
      Severity::error(),
      "Avoid set:html (XSS risk); use text interpolation",
      astro_exts,
      Contains("set:html"),
    ),
    rule(
      "astro/no-unused-define-vars",
      Severity::warning(),
      "Define vars in frontmatter, not in template",
      astro_exts,
      Regex("const[[:space:]]+[[:alpha:]_$][[:alnum:]_$]*[[:space:]]*="),
    ),
    rule(
      "astro/prefer-class-list",
      Severity::warning(),
      "Use class:list instead of template literals for conditional classes",
      astro_exts,
      Regex("class=[{]"),
    ),
    guarded_rule(
      "astro/no-target-blank",
      Severity::warning(),
      "target=\"_blank\" without rel=\"noopener\" is a security risk",
      astro_exts,
      Regex("target=\"_blank\""),
      Regex("noopener"),
    ),
    guarded_rule(
      "astro/valid-compile",
      Severity::error(),
      "Avoid raw <script> without type=\"module\" in Astro",
      astro_exts,
      Regex("<script"),
      Regex("type="),
    ),
  ]
}

// ---------------------------------------------------------------------------
// nuxt — Nuxt conventions (Vue-based)
// ---------------------------------------------------------------------------

///|
fn nuxt_rules() -> Array[Rule] {
  let nuxt_exts = [".vue", ".js", ".ts"]
  [
    rule(
      "nuxt/no-env-in-runtime",
      Severity::error(),
      "Avoid process.env in client-side code; use runtimeConfig",
      nuxt_exts,
      Regex("process\\.env\\."),
    ),
    rule(
      "nuxt/prefer-use-fetch",
      Severity::warning(),
      "Use useFetch or useAsyncData instead of raw fetch in Nuxt",
      nuxt_exts,
      Regex("\\bfetch\\("),
    ),
    rule(
      "nuxt/no-window-in-ssr",
      Severity::error(),
      "Avoid window/document in SSR code; use onMounted or process.client",
      nuxt_exts,
      Regex("\\b(window|document)\\."),
    ),
    rule(
      "nuxt/prefer-auto-imports",
      Severity::warning(),
      "Use Nuxt auto-imports instead of explicit imports from 'vue'",
      nuxt_exts,
      Regex(
        "import[[:space:]]*\\{[^}]*\\}[[:space:]]*from[[:space:]]+['\"]vue['\"]",
      ),
    ),
    rule(
      "nuxt/no-v-html",
      Severity::warning(),
      "Avoid v-html (XSS risk); use text interpolation or a sanitizer",
      nuxt_exts,
      Contains("v-html"),
    ),
  ]
}

// ---------------------------------------------------------------------------
// file — file-level checks (size, whitespace, naming, duplicates)
// ---------------------------------------------------------------------------

///|
fn file_rules_preset() -> Array[FileRule] {
  let all_exts = [
    ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".vue", ".svelte",
  ]
  [
    FileRule::{
      id: "file/max-lines",
      severity: Severity::warning(),
      message: "File exceeds 500 lines",
      extensions: all_exts,
      check: MaxLines(500),
      scope: Scope::empty(),
    },
    FileRule::{
      id: "file/max-line-length",
      severity: Severity::warning(),
      message: "Line exceeds 120 characters",
      extensions: all_exts,
      check: MaxLineLength(120),
      scope: Scope::empty(),
    },
    FileRule::{
      id: "file/no-trailing-whitespace",
      severity: Severity::warning(),
      message: "Trailing whitespace found",
      extensions: all_exts,
      check: NoTrailingWhitespace,
      scope: Scope::empty(),
    },
    FileRule::{
      id: "file/no-tabs",
      severity: Severity::warning(),
      message: "Tab character found; use spaces",
      extensions: all_exts,
      check: NoTabs,
      scope: Scope::empty(),
    },
    FileRule::{
      id: "file/final-newline",
      severity: Severity::warning(),
      message: "File must end with a newline",
      extensions: all_exts,
      check: FinalNewline,
      scope: Scope::empty(),
    },
    FileRule::{
      id: "file/no-duplicate-lines",
      severity: Severity::warning(),
      message: "Duplicate line found",
      extensions: all_exts,
      check: NoDuplicateLines,
      scope: Scope::empty(),
    },
  ]
}

// ---------------------------------------------------------------------------
// Preset registry
// ---------------------------------------------------------------------------

///|
/// All built-in presets, in a stable order.
fn all_presets() -> Array[Preset] {
  [
    {
      name: "common",
      description: "Framework-agnostic JS/TS hygiene (no-console, no-debugger, no-eval, ...)",
      rules: common_rules(),
      file_rules: [],
    },
    {
      name: "react",
      description: "React and JSX conventions (no-danger, jsx-key, self-closing, ...)",
      rules: react_rules(),
      file_rules: [],
    },
    {
      name: "vue",
      description: "Vue 3 template and SFC conventions (no-v-html, require-v-for-key, ...)",
      rules: vue_rules(),
      file_rules: [],
    },
    {
      name: "angular",
      description: "Angular component conventions (no-input-rename, no-output-native, ...)",
      rules: angular_rules(),
      file_rules: [],
    },
    {
      name: "svelte",
      description: "Svelte component conventions (no-at-html, require-each-key, a11y, ...)",
      rules: svelte_rules(),
      file_rules: [],
    },
    {
      name: "next",
      description: "Next.js conventions (no-img-element, no-head-element, ...)",
      rules: next_rules(),
      file_rules: [],
    },
    {
      name: "file",
      description: "File-level checks (max-lines, no-trailing-whitespace, no-tabs, ...)",
      rules: [],
      file_rules: file_rules_preset(),
    },
    {
      name: "solid",
      description: "SolidJS conventions (no-innerhtml, prefer-for, no-react-imports, ...)",
      rules: solid_rules(),
      file_rules: [],
    },
    {
      name: "astro",
      description: "Astro conventions (no-set-html-directive, prefer-class-list, ...)",
      rules: astro_rules(),
      file_rules: [],
    },
    {
      name: "nuxt",
      description: "Nuxt conventions (no-env-in-runtime, prefer-use-fetch, no-window-in-ssr, ...)",
      rules: nuxt_rules(),
      file_rules: [],
    },
  ]
}

///|
/// Lexicographic string comparison. MoonBit's built-in `String::compare` is
/// length-first, so preset names need an explicit character-by-character
/// comparison to sort alphabetically.
fn lex_compare(a : String, b : String) -> Int32 {
  let ac = a.to_array()
  let bc = b.to_array()
  let len = if ac.length() < bc.length() { ac.length() } else { bc.length() }
  for i in 0..<len {
    if ac[i] != bc[i] {
      return ac[i].to_int() - bc[i].to_int()
    }
  }
  ac.length() - bc.length()
}

///|
/// The names of all built-in presets, sorted alphabetically.
pub fn preset_names() -> Array[String] {
  let names = all_presets().map(p => p.name)
  // Selection sort with lexicographic comparison.
  for i in 0..<names.length() {
    let mut min_idx = i
    for j in (i + 1)..<names.length() {
      if lex_compare(names[j], names[min_idx]) < 0 {
        min_idx = j
      }
    }
    if min_idx != i {
      let tmp = names[i]
      names[i] = names[min_idx]
      names[min_idx] = tmp
    }
  }
  names
}

///|
/// Look up a preset by name. Returns `None` for an unknown name.
pub fn preset_by_name(name : String) -> Preset? {
  for preset in all_presets() {
    if preset.name == name {
      return Some(preset)
    }
  }
  None
}

///|
/// Merge several presets into one rule set. Rules are concatenated in preset
/// order; a rule whose id already appeared is dropped (first occurrence wins).
/// File rules are merged the same way. The merged config carries no global
/// scope.
pub fn merge_presets(names : Array[String]) -> Result[LintConfig, ConfigError] {
  let rules : Array[Rule] = []
  let file_rules : Array[FileRule] = []
  let seen : Set[String] = Set::new()
  for name in names {
    match preset_by_name(name) {
      None => return Err(ConfigError("unknown preset: \{name}"))
      Some(preset) => {
        for r in preset.rules {
          if !seen.contains(r.id) {
            seen.add(r.id)
            rules.push(r)
          }
        }
        for fr in preset.file_rules {
          if !seen.contains(fr.id) {
            seen.add(fr.id)
            file_rules.push(fr)
          }
        }
      }
    }
  }
  Ok({ rules, file_rules, scope: Scope::empty(), })
}

///|
/// Render the preset list for `--list-presets`: one `name — description`
/// line per preset, sorted by name.
pub fn render_preset_list() -> String {
  let names = preset_names()
  let lines : Array[String] = []
  for name in names {
    match preset_by_name(name) {
      Some(preset) => lines.push("\{preset.name} — \{preset.description}")
      None => ()
    }
  }
  lines.join("\n")
}
