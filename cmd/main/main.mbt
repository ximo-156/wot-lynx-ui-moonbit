///|
/// moonlint CLI. Operational failures exit 2; lint errors exit 1.
struct Options {
  mut directory : String
  mut config : String
  mut baseline : String?
  mut update_baseline : Bool
  mut summary : Bool
  mut errors_only : Bool
  exts : Array[String]
  mut help : Bool
  mut scan_mode : @lib.ScanMode
  globs : Array[String]
  mut mode_set : Bool
  mut directory_set : Bool
  mut format : Format
  mut report : String?
  presets : Array[String]
  mut list_presets : Bool
  mut config_set : Bool
  mut init : Bool
  mut fix : Bool
  mut dry_run : Bool
  mut fix_tab_width : Int32?
  mut incremental : Bool
  mut cache_file : String
  mut project_mode : ProjectMode?
  mut api_toolchain : String?
  mut api_backend : String?
  mut api_module_version : String?
  mut api_version_policy : String
  mut baseline_format : String
  mut baseline_format_set : Bool
  mut baseline_reason : String?
  mut baseline_owner : String?
  mut baseline_expires : String?
  mut baseline_today : String?
  mut audit_baseline : Bool
  mut migrate_baseline : Bool
}

///|
/// Stdout rendering format. `Text` is the human-readable default; `Json` and
/// `Github` are the machine-readable reports used in CI.
#derive(Debug, Eq)
enum Format {
  Text
  Json
  Github
  Sarif
}

///|
fn main {
  let opts = parse_args(@env.args()) catch {
    error => die(@lib.error_message(error))
  }
  if opts.help {
    print_help()
    return
  }
  if opts.project_mode is Some(_) {
    run_project_mode(opts) catch {
      error => die(@lib.error_message(error))
    }
    return
  }
  if opts.list_presets {
    println(@lib.render_preset_list())
    return
  }
  if opts.init {
    init_config() catch {
      error => die(@lib.error_message(error))
    }
    return
  }
  run(opts) catch {
    error => die(@lib.error_message(error))
  }
}

///|
/// Generate a starter moonlint.json config file.
fn init_config() -> Unit raise {
  let path = "moonlint.json"
  if @lib.source_path_kind(path) != 0 {
    println("moonlint: \{path} already exists")
    return
  }
  let config =
    #|{
    #|  "exclude": ["**/*_test.mbt", "**/*_wbtest.mbt"],
    #|  "rules": [],
    #|  "structural_rules": [
    #|    { "id": "moonbit/no-todo-comment", "severity": "warning", "message": "TODO/FIXME comment left in code", "extensions": [".mbt"], "check": { "moonbit_no_todo": true } },
    #|    { "id": "moonbit/no-unwrap", "severity": "warning", "message": "Method named unwrap() requires review; it may panic", "extensions": [".mbt"], "check": { "moonbit_no_unwrap": true } },
    #|    { "id": "moonbit/require-public-doc", "severity": "error", "message": "Public item is missing documentation", "extensions": [".mbt"], "check": { "moonbit_require_public_doc": true } },
    #|    { "id": "moonbit/naming", "severity": "error", "message": "Name does not follow the MoonBit naming convention", "extensions": [".mbt"], "check": { "moonbit_naming": true } }
    #|  ]
    #|}
    #|
  @lib.write_atomic_text(path, config)
  println("moonlint: created \{path}")
  println("Run with: moonlint .")
  println("For the full rule set: moonlint --preset moonbit .")
}

///|
fn run(opts : Options) -> Unit raise {
  let root = @lib.canonical_root(opts.directory)
  let config = if !opts.presets.is_empty() {
    if opts.config_set {
      raise Failure(
        "--preset and --config are mutually exclusive; use one or the other",
      )
    }
    match @lib.merge_presets(opts.presets) {
      Ok(config) => config
      Err(@lib.ConfigError(message)) =>
        raise Failure("preset error: \{message}")
    }
  } else {
    let config_src = @fs.read_file_to_string(opts.config) catch {
      _ => raise Failure("cannot read config: \{opts.config}")
    }
    // Extract directory from config path for extends resolution
    let config_dir = match opts.config.rev_split_once("/") {
      Some((dir, _)) => dir.to_owned()
      None => "."
    }
    match @lib.parse_config_with_extends(config_src, config_dir) {
      Ok(config) => config
      Err(@lib.ConfigError(message)) =>
        raise Failure("config error: \{message}")
    }
  }
  let rules = config.rules
  let file_rules = config.file_rules
  let structural_rules = config.structural_rules
  match @lib.validate_rules(rules) {
    Ok(_) => ()
    Err(@lib.ConfigError(message)) => raise Failure("config error: \{message}")
  }
  if (opts.update_baseline || opts.audit_baseline) &&
    (opts.scan_mode.tag() != "tree" || !opts.exts.is_empty()) {
    raise Failure(
      "--update-baseline requires a full tree scan without --ext or other scan modes",
    )
  }
  if opts.fix && (opts.update_baseline || opts.audit_baseline) {
    raise Failure(
      "--fix cannot be combined with baseline update/migration/audit",
    )
  }
  // --fix writes the working tree; Git-backed modes read blobs, so fixes would
  // never be reflected in the re-scan and the report would contradict disk.
  if opts.fix &&
    (opts.scan_mode.tag() == "changed" || opts.scan_mode.tag() == "staged") {
    raise Failure(
      "--fix cannot be combined with --changed or --staged; run it on the working tree",
    )
  }
  let exts = if !opts.exts.is_empty() {
    opts.exts
  } else {
    @lib.collect_extensions(rules, file_rules, structural_rules)
  }
  let files = @lib.select_files(opts.scan_mode, root, exts)
  // Repeated --glob patterns form a union, then the selector de-duplicates it.
  if opts.globs.length() > 1 {
    for pattern in opts.globs[1:] {
      for file in @lib.select_files(@lib.ScanMode::glob(pattern), root, exts) {
        files.push(file)
      }
    }
  }
  let (result, cache) = scan_with_cache(
    opts,
    root,
    files,
    rules,
    file_rules,
    structural_rules,
    config.scope,
    config.aliases,
  )
  persist_cache(opts, cache)
  let scan = @lib.ScanInfo::new(opts.scan_mode.tag(), root, exts)
  if opts.dry_run && !opts.fix {
    raise Failure("--dry-run only applies to --fix")
  }
  if opts.fix {
    if result.files_failed + result.context_files_failed > 0 {
      write_report(result, opts, scan)
      emit(result, opts, scan)
      @sys.exit(2)
      return
    }
    apply_fixes(
      root,
      files,
      file_rules,
      config.scope,
      opts.fix_tab_width,
      opts.dry_run,
    )
    // A dry run leaves the working tree untouched, so re-scanning would
    // report the same findings again and suggest the fixes did nothing. The
    // pre-fix result is the honest answer: it is what the user still has.
    if opts.dry_run {
      finish_source_run(result, opts, scan)
      return
    }
    // Re-scan after fixes. Fixes were written to the working tree, so a
    // Git-backed selection (--changed/--staged) is rejected above and cannot
    // re-read stale blobs here.
    let (result2, cache2) = scan_with_cache(
      opts,
      root,
      files,
      rules,
      file_rules,
      structural_rules,
      config.scope,
      config.aliases,
    )
    persist_cache(opts, cache2)
    finish_source_run(result2, opts, scan)
    return
  }
  finish_source_run(result, opts, scan)
}

///|
/// Run the scan, using the incremental cache when the caller asked for it.
/// Returns the result together with the refreshed cache to persist (or
/// `None` when caching is off). A cache file that is missing or unparseable
/// simply starts a fresh cache: a stale cache degrades to a full scan, never
/// to a wrong answer.
fn scan_with_cache(
  opts : Options,
  root : String,
  files : Array[String],
  rules : Array[@lib.Rule],
  file_rules : Array[@lib.FileRule],
  structural_rules : Array[@lib.StructuralRule],
  scope : @lib.Scope,
  aliases : Array[(String, String)],
) -> (@lib.LintResult, @lib.Cache?) raise {
  if !opts.incremental {
    let result = @lib.lint_selected_with(
      root,
      opts.scan_mode,
      files,
      rules,
      file_rules,
      structural_rules,
      scope,
      aliases,
    )
    return (result, None)
  }
  let previous = @fs.read_file_to_string(opts.cache_file) catch { _ => "" }
  let loaded = if previous == "" { None } else { @lib.Cache::parse(previous) }
  let (result, cache) = @lib.lint_selected_cached_with(
    root,
    opts.scan_mode,
    files,
    rules,
    file_rules,
    structural_rules,
    scope,
    loaded,
    aliases,
  )
  (result, Some(cache))
}

///|
/// Persist a refreshed cache. A write failure is reported on stderr and
/// otherwise ignored: the lint result is already complete, and a missing
/// cache only costs the next run some time.
fn persist_cache(opts : Options, cache : @lib.Cache?) -> Unit {
  match cache {
    None => ()
    Some(c) =>
      @lib.write_atomic_text(opts.cache_file, c.render()) catch {
        _ =>
          eprintln(
            "moonlint: warning: could not write cache file \{opts.cache_file}",
          )
      }
  }
}

///|
/// Apply auto-fixes for fixable file rules.
///
/// Only rules that actually apply to the path are consulted (extension *and*
/// include/exclude scope), matching what the scan reports. Fixes preserve the
/// file's existing line-ending style, and `no_tabs` is only rewritten when the
/// caller explicitly opted in via `--fix-tab-width`, because replacing a tab
/// changes indentation width and can alter semantics in Python/YAML/Makefiles.
/// Progress messages go to stderr so `--format json|sarif` stays parseable.
fn apply_fixes(
  root : String,
  files : Array[String],
  file_rules : Array[@lib.FileRule],
  scope : @lib.Scope,
  tab_width : Int32?,
  dry_run : Bool,
) -> Unit raise {
  let mut fixed_count = 0
  for rel in files {
    if !scope.allows(rel) {
      continue
    }
    // Only rules that genuinely apply to this path, including scope.
    let applicable = file_rules.filter(fr => fr.applies_to(rel))
    if applicable.is_empty() {
      continue
    }
    let path = "\{root}/\{rel}"
    @lib.validate_fix_path(root, rel)
    let source = @lib.read_fix_source(root, rel)
    let script_fix = [
        ".js", ".mjs", ".cjs", ".ts", ".mts", ".cts", ".jsx", ".tsx",
      ].any(ext => rel.has_suffix(ext)) &&
      !source.contains("<")
    let crlf = source.contains("\r\n")
    let mut fixed = source
    let mut changed = false
    if rel.has_suffix(".mbt") {
      fixed = @lib.fix_moonbit_whitespace(
        source,
        applicable.any(fr => fr.check is @lib.FileCheck::NoTrailingWhitespace),
        if applicable.any(fr => fr.check is @lib.FileCheck::NoTabs) {
          tab_width
        } else {
          None
        },
        applicable.any(fr => fr.check is @lib.FileCheck::FinalNewline),
      )
      changed = fixed != source
    }
    for fr in applicable {
      if rel.has_suffix(".mbt") {
        continue
      }
      match fr.check {
        @lib.FileCheck::NoTrailingWhitespace => {
          if !script_fix || source.contains("`") {
            continue
          }
          let lines = fixed.split("\n")
          let new_lines : Array[String] = []
          for line_view in lines {
            let line = line_view.to_owned()
            let trimmed = trim_trailing_ws(line)
            if trimmed != line {
              changed = true
            }
            new_lines.push(trimmed)
          }
          fixed = new_lines.join("\n")
        }
        @lib.FileCheck::NoTabs =>
          // Tab replacement is opt-in: it silently changes indentation width.
          match tab_width {
            Some(width) =>
              if script_fix &&
                !source.contains("`") &&
                !source.contains("\"") &&
                !source.contains("'") &&
                !source.contains("/") &&
                fixed.contains("\t") {
                let parts = fixed.split("\t")
                fixed = parts.join(" ".repeat(width))
                changed = true
              }
            None => ()
          }
        @lib.FileCheck::FinalNewline =>
          if script_fix &&
            !source.contains("`") &&
            fixed.length() > 0 &&
            !fixed.has_suffix("\n") {
            // Match the file's existing convention instead of forcing LF.
            fixed = fixed + (if crlf { "\r\n" } else { "\n" })
            changed = true
          }
        _ => ()
      }
    }
    if changed {
      if !dry_run {
        // Atomic replace: a crash mid-write must not truncate user source.
        @lib.validate_fix_path(root, rel)
        if @lib.read_fix_source(root, rel) != source {
          raise Failure("source changed before fix: \{rel}")
        }
        @lib.write_atomic_text(path, fixed)
      }
      fixed_count += 1
      eprintln(
        "moonlint: \{if dry_run { "would fix" } else { "fixed" }} \{rel}",
      )
    }
  }
  if fixed_count > 0 {
    eprintln(
      "moonlint: \{if dry_run { "would fix" } else { "fixed" }} \{fixed_count} file(s)",
    )
  }
}

///|
/// Trim trailing whitespace (spaces and tabs) from a string.
fn trim_trailing_ws(s : String) -> String {
  let chars = s.to_array()
  let has_cr = chars.length() > 0 && chars[chars.length() - 1] == '\r'
  let mut end = chars.length() - (if has_cr { 1 } else { 0 })
  while end > 0 && (chars[end - 1] == ' ' || chars[end - 1] == '\t') {
    end -= 1
  }
  String::from_array(chars[:end]) + (if has_cr { "\r" } else { "" })
}

///|
/// Write the JSON report to `--report <file>` when requested. The report is
/// written atomically, so a failed write never leaves a truncated file.
fn write_report(
  result : @lib.LintResult,
  opts : Options,
  scan : @lib.ScanInfo,
) -> Unit raise {
  match opts.report {
    None => ()
    Some(path) => @lib.write_atomic_text(path, @lib.render_json(result, scan))
  }
}

///|
/// Print the run in the requested output format. `--errors-only` filters the
/// reported findings in every format, so JSON counts stay consistent with the
/// findings array.
fn emit(result : @lib.LintResult, opts : Options, scan : @lib.ScanInfo) -> Unit {
  let shown = if opts.errors_only {
    result.findings.filter(finding => finding.severity == @lib.Severity::error())
  } else {
    result.findings
  }
  let displayed = result.with_findings(shown, result.baseline_hits)
  match opts.format {
    Text => emit_text(displayed, opts, result)
    Json => println(@lib.render_json(displayed, scan))
    Github => println(@lib.render_github(displayed))
    Sarif => println(@lib.render_sarif(displayed, scan))
  }
}

///|
fn emit_text(
  displayed : @lib.LintResult,
  opts : Options,
  result : @lib.LintResult,
) -> Unit {
  if opts.summary {
    println(@lib.render_summary(displayed))
  } else {
    println(@lib.render_detail(displayed.findings))
    if result.files_selected == 0 {
      println(
        "moonlint: no files selected (check the scan mode, extensions and paths)",
      )
    }
  }
  for diagnostic in result.diagnostics {
    println("moonlint: \{diagnostic.file}: \{diagnostic.message}")
  }
}

///|
fn[T] die(message : String) -> T {
  println("moonlint: \{message}")
  @sys.exit(2)
  abort(message)
}

///|
fn option_value(
  args : Array[String],
  index : Int32,
  flag : String,
) -> String raise {
  if index >= args.length() || args[index] == "" || args[index].has_prefix("--") {
    raise Failure("missing value for \{flag}")
  }
  args[index]
}

///|
fn set_mode(opts : Options, mode : @lib.ScanMode) -> Unit raise {
  if opts.mode_set {
    raise Failure(
      "scan modes are mutually exclusive; select one of --changed, --staged, --glob, --stdin, --stdin0",
    )
  }
  opts.mode_set = true
  opts.scan_mode = mode
}

///|
/// Parse a strictly positive decimal integer, or `None` when `value` is not
/// one. Rejects signs, whitespace and overflow beyond `Int`.
fn parse_positive_int(value : String) -> Int32? {
  if value == "" {
    return None
  }
  let mut acc : Int32 = 0
  for c in value {
    if c < '0' || c > '9' {
      return None
    }
    let digit = c.to_int() - '0'.to_int()
    // Guard against overflow: Int is at most 2^63-1.
    if acc > (2147483647 - digit) / 10 {
      return None
    }
    acc = acc * 10 + digit
  }
  if acc <= 0 {
    return None
  }
  Some(acc)
}

///|
/// Parse the `--format` value. Unknown formats are usage errors.
fn parse_format(value : String) -> Format raise {
  match value {
    "text" => Text
    "json" => Json
    "github" => Github
    "sarif" => Sarif
    _ => raise Failure("--format expects one of: text, json, github, sarif")
  }
}

///|
fn parse_args(args : Array[String]) -> Options raise {
  let opts : Options = {
    directory: ".",
    config: "moonlint.json",
    baseline: None,
    update_baseline: false,
    summary: false,
    errors_only: false,
    exts: [],
    help: false,
    scan_mode: @lib.ScanMode::tree(),
    globs: [],
    mode_set: false,
    directory_set: false,
    format: Format::Text,
    report: None,
    presets: [],
    list_presets: false,
    config_set: false,
    init: false,
    fix: false,
    dry_run: false,
    fix_tab_width: None,
    incremental: false,
    cache_file: ".moonlint-cache.json",
    project_mode: None,
    api_toolchain: None,
    api_backend: None,
    api_module_version: None,
    api_version_policy: "none",
    baseline_format: "legacy",
    baseline_format_set: false,
    baseline_reason: None,
    baseline_owner: None,
    baseline_expires: None,
    baseline_today: None,
    audit_baseline: false,
    migrate_baseline: false,
  }
  let mut i = 1
  let mut positional_only = false
  while i < args.length() {
    let arg = args[i]
    if positional_only {
      if opts.directory_set {
        raise Failure("only one scan directory is allowed")
      }
      opts.directory = arg
      opts.directory_set = true
      i += 1
      continue
    }
    match arg {
      "--" => positional_only = true
      "-h" | "--help" => opts.help = true
      "--package-graph" => {
        i += 1
        set_project_mode(opts, PackageGraph(option_value(args, i, arg)))
      }
      "--api-snapshot" => {
        i += 1
        set_project_mode(opts, ApiSnapshot(option_value(args, i, arg)))
      }
      "--api-check" => {
        i += 1
        let before = option_value(args, i, arg)
        i += 1
        let after = option_value(args, i, arg)
        set_project_mode(opts, ApiCheck(before, after))
      }
      "--api-toolchain" => {
        i += 1
        opts.api_toolchain = Some(option_value(args, i, arg))
      }
      "--api-backend" => {
        i += 1
        opts.api_backend = Some(option_value(args, i, arg))
      }
      "--api-module-version" => {
        i += 1
        opts.api_module_version = Some(option_value(args, i, arg))
      }
      "--api-version-policy" => {
        i += 1
        opts.api_version_policy = option_value(args, i, arg)
        if opts.api_version_policy != "none" &&
          opts.api_version_policy != "semver" {
          raise Failure("--api-version-policy expects none or semver")
        }
      }
      "--config" => {
        i += 1
        opts.config = option_value(args, i, arg)
        opts.config_set = true
      }
      "--preset" => {
        i += 1
        let name = option_value(args, i, arg)
        if !opts.presets.contains(name) {
          opts.presets.push(name)
        }
      }
      "--list-presets" => opts.list_presets = true
      "--init" => opts.init = true
      "--fix" => opts.fix = true
      "--fix-tab-width" => {
        i += 1
        let raw = option_value(args, i, arg)
        match parse_positive_int(raw) {
          Some(w) => opts.fix_tab_width = Some(w)
          None => raise Failure("--fix-tab-width expects a positive integer")
        }
      }
      "--baseline-format" => {
        i += 1
        opts.baseline_format = option_value(args, i, arg)
        opts.baseline_format_set = true
        if opts.baseline_format != "legacy" && opts.baseline_format != "v2" {
          raise Failure("--baseline-format expects legacy or v2")
        }
      }
      "--baseline-reason" => {
        i += 1
        opts.baseline_reason = Some(option_value(args, i, arg))
      }
      "--baseline-owner" => {
        i += 1
        opts.baseline_owner = Some(option_value(args, i, arg))
      }
      "--baseline-expires" => {
        i += 1
        opts.baseline_expires = Some(option_value(args, i, arg))
      }
      "--baseline-today" => {
        i += 1
        opts.baseline_today = Some(option_value(args, i, arg))
      }
      "--audit-baseline" => opts.audit_baseline = true
      "--migrate-baseline" => {
        opts.migrate_baseline = true
        opts.update_baseline = true
        opts.baseline_format = "v2"
        opts.baseline_format_set = true
      }
      "--baseline" => {
        i += 1
        opts.baseline = Some(option_value(args, i, arg))
      }
      "--report" => {
        i += 1
        opts.report = Some(option_value(args, i, arg))
      }
      "--format" => {
        i += 1
        opts.format = parse_format(option_value(args, i, arg))
      }
      "--dry-run" => opts.dry_run = true
      "--update-baseline" => opts.update_baseline = true
      "--summary" => opts.summary = true
      "--errors-only" => opts.errors_only = true
      "--changed" => {
        i += 1
        set_mode(opts, @lib.ScanMode::changed(option_value(args, i, arg)))
      }
      "--staged" => set_mode(opts, @lib.ScanMode::staged())
      "--glob" => {
        i += 1
        let pattern = option_value(args, i, arg)
        @lib.validate_glob(pattern)
        if opts.globs.is_empty() {
          set_mode(opts, @lib.ScanMode::glob(pattern))
        }
        opts.globs.push(pattern)
      }
      "--stdin" => set_mode(opts, @lib.ScanMode::stdin())
      "--stdin0" => set_mode(opts, @lib.ScanMode::stdin0())
      "--incremental" => opts.incremental = true
      "--cache-file" => {
        i += 1
        opts.cache_file = option_value(args, i, arg)
      }
      "--watch" | "--watch-interval" =>
        raise Failure(
          "unsupported option \{arg}: watch mode is not implemented; use --incremental for fast repeated scans",
        )
      "--ext" => {
        i += 1
        let value = option_value(args, i, arg)
        for extension in value.split(",") {
          let ext = extension.trim().to_owned()
          if ext == "" || ext == "." || ext.contains("/") || ext.contains("*") {
            raise Failure("--ext expects non-empty comma-separated extensions")
          }
          if !opts.exts.contains(ext) {
            opts.exts.push(ext)
          }
        }
      }
      _ => {
        if arg.has_prefix("-") {
          raise Failure("unknown option: \{arg}")
        }
        if opts.directory_set {
          raise Failure("only one scan directory is allowed")
        }
        opts.directory = arg
        opts.directory_set = true
      }
    }
    i += 1
  }
  if opts.project_mode is None &&
    (
      opts.api_toolchain is Some(_) ||
      opts.api_backend is Some(_) ||
      opts.api_module_version is Some(_) ||
      opts.api_version_policy != "none"
    ) {
    raise Failure("API metadata/version options require an API policy mode")
  }
  if opts.fix_tab_width is Some(_) && !opts.fix {
    raise Failure("--fix-tab-width requires --fix")
  }
  if !opts.help {
    if opts.audit_baseline && (opts.baseline is None || opts.update_baseline) {
      raise Failure("--audit-baseline requires --baseline and cannot update it")
    }
    if opts.migrate_baseline &&
      (opts.baseline is None || opts.baseline_format != "v2") {
      raise Failure(
        "--migrate-baseline requires a named legacy baseline and v2 format",
      )
    }
    if opts.baseline_format_set && !opts.update_baseline {
      raise Failure("--baseline-format only applies to baseline writes")
    }
    if (
        opts.baseline_reason is Some(_) ||
        opts.baseline_owner is Some(_) ||
        opts.baseline_expires is Some(_)
      ) &&
      (!opts.update_baseline || opts.baseline_format != "v2") {
      raise Failure("exception metadata requires a v2 baseline write")
    }
    if opts.baseline_today is Some(_) && opts.baseline is None {
      raise Failure("--baseline-today requires --baseline")
    }
  }
  opts
}

///|
fn print_help() -> Unit {
  println(
    [
      "moonlint — a config-driven convention linter", "Usage: moonlint [options] [directory]",
      "", "  --config <file>    rules JSON (default: moonlint.json)", "  --preset <name>    built-in framework preset (repeatable; see --list-presets)",
      "  --list-presets     show available presets and exit", "  --init             create a starter moonlint.json config",
      "  --fix              auto-fix file rules: trailing ws, final newline (atomic, scope-aware)",
      "  --fix-tab-width <n> enable the no_tabs fix, replacing each tab with n spaces",
      "  --dry-run          with --fix, report what would change without writing",
      "  --baseline <file>  strict legacy finding-hash JSON array", "  --update-baseline  atomically rewrite the full tree scan's findings",
      "  --summary          show rule totals and read/skip/failure counts", "  --errors-only      hide warning findings (including in --summary)",
      "  --ext <list>       comma-separated extension filter, in every mode", "  --format <fmt>     text (default), json, github, or sarif",
      "  --report <file>    also write the JSON report to this file", "  --incremental      reuse per-file results for unchanged files (content-hash cache)",
      "  --cache-file <f>   cache location (default: .moonlint-cache.json)", "  -h, --help         show this help",
      "", "Scan modes (mutually exclusive; default: working-tree walk):", "  --changed <ref>    merge-base(ref, HEAD)..HEAD files; read HEAD blobs",
      "  --staged           read actual index blobs, not working-tree copies", "  --glob <pattern>   repeatable union; *, ?, standalone ** segments",
      "  --stdin            root-relative paths, one per line (no trim)", "  --stdin0           NUL-separated paths (supports embedded newlines)",
      "", "Config scopes: top-level and per-rule include/exclude glob patterns",
      "restrict which files are scanned and which rules apply to them.", "", "Inline disables: // moonlint-disable [rule-id] / // moonlint-disable-next-line [rule-id]",
      "Config extends: \"extends\": \"base.json\" or \"extends\": [\"a.json\", \"b.json\"]",
      "Structural rules: \"structural_rules\" runs cross-file checks (see --preset imports)",
      "Matcher DSL: \"match\"/\"unless\" nest all/any/not over contains/prefix/suffix/regex/equals/word",
      "", "Symbolic links are skipped. Git/read failures exit 2; no silent fallback.",
      "Incremental caching re-lints only changed files; Watch is not implemented.",
      "", "Project policies (read pre-generated compiler output; no implicit build):",
      "  --package-graph <json> --config <policy.json>   Check moon tree schema v3",
      "  --api-snapshot <mbti> --api-toolchain <id> --api-backend <target>", "                  --api-module-version <version>   Write snapshot JSON",
      "  --api-check <before.json> <after.json>           Compare public interfaces",
      "  --api-version-policy none|semver                Opt-in release policy",
      "", "Versioned exceptions (baseline loading is always explicit):", "  --update-baseline --baseline-format v2 --baseline-reason <reason>",
      "                  --baseline-owner <owner> [--baseline-expires YYYY-MM-DD]",
      "  --audit-baseline --baseline <v2.json>    Audit a full tree and count budgets",
      "  --migrate-baseline --baseline <legacy.json> --baseline-reason R --baseline-owner O",
      "  --baseline-today YYYY-MM-DD             Override UTC date for reproducible checks",
      "Unknown graph/interface metadata or syntax exits 2, never a clean pass.",
      "Exit: 0 no lint errors, 1 lint errors, 2 argument/config/scan/IO failure.",
    ].join("\n"),
  )
}
