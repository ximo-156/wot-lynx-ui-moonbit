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
  try {
    run(opts)
  } catch {
    error => die(@lib.error_message(error))
  }
}

///|
fn run(opts : Options) -> Unit raise {
  let root = @lib.canonical_root(opts.directory)
  let config_src = @fs.read_file_to_string(opts.config) catch {
    _ => raise Failure("cannot read config: \{opts.config}")
  }
  let rules = match @lib.parse_config(config_src) {
    Ok(rules) => rules
    Err(@lib.ConfigError(message)) => raise Failure("config error: \{message}")
  }
  match @lib.validate_rules(rules) {
    Ok(_) => ()
    Err(@lib.ConfigError(message)) => raise Failure("config error: \{message}")
  }
  if opts.update_baseline && (opts.scan_mode.tag() != "tree" || !opts.exts.is_empty()) {
    raise Failure("--update-baseline requires a full tree scan without --ext or other scan modes")
  }
  let exts = if !opts.exts.is_empty() { opts.exts } else { @lib.collect_extensions(rules) }
  let files = @lib.select_files(opts.scan_mode, root, exts)
  // Repeated --glob patterns form a union, then the selector de-duplicates it.
  if opts.globs.length() > 1 {
    for pattern in opts.globs[1:] {
      for file in @lib.select_files(@lib.ScanMode::glob(pattern), root, exts) {
        files.push(file)
      }
    }
  }
  let result = @lib.lint_selected(root, opts.scan_mode, files, rules)
  if opts.update_baseline {
    if result.files_failed > 0 {
      report_result(result, opts)
      @sys.exit(2)
      return
    }
    let path = opts.baseline.unwrap_or("moonlint.baseline.json")
    // Refresh from raw findings BEFORE partition; repeated refresh is idempotent.
    @lib.write_atomic_text(path, @lib.Baseline::render(result.findings))
    println("moonlint: wrote \{result.findings.length()} findings to \{path}")
    return
  }
  let final_result = match opts.baseline {
    None => result
    Some(path) => {
      let source = @fs.read_file_to_string(path) catch {
        _ => raise Failure("cannot read baseline: \{path}")
      }
      let baseline = @lib.Baseline::parse(source)
      let (findings, suppressed) = baseline.partition(result.findings)
      result.with_findings(findings, suppressed.length())
    }
  }
  report_result(final_result, opts)
  if final_result.files_failed > 0 {
    @sys.exit(2)
  } else if final_result.has_errors() {
    @sys.exit(1)
  }
}

///|
fn report_result(result : @lib.LintResult, opts : Options) -> Unit {
  let shown = if opts.errors_only {
    result.findings.filter(finding => finding.severity == @lib.Severity::error())
  } else {
    result.findings
  }
  let displayed = result.with_findings(shown, result.baseline_hits)
  if opts.summary {
    println(@lib.render_summary(displayed))
  } else {
    println(@lib.render_detail(shown))
    if result.files_selected == 0 {
      println("moonlint: no files selected (check the scan mode, extensions and paths)")
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
fn option_value(args : Array[String], index : Int32, flag : String) -> String raise {
  if index >= args.length() || args[index] == "" || args[index].has_prefix("--") {
    raise Failure("missing value for \{flag}")
  }
  args[index]
}

///|
fn set_mode(opts : Options, mode : @lib.ScanMode) -> Unit raise {
  if opts.mode_set {
    raise Failure("scan modes are mutually exclusive; select one of --changed, --staged, --glob, --stdin, --stdin0")
  }
  opts.mode_set = true
  opts.scan_mode = mode
}

///|
fn parse_args(args : Array[String]) -> Options raise {
  let opts : Options = {
    directory: ".", config: "moonlint.json", baseline: None,
    update_baseline: false, summary: false, errors_only: false, exts: [],
    help: false, scan_mode: @lib.ScanMode::tree(), globs: [],
    mode_set: false, directory_set: false,
  }
  let mut i = 1
  let mut positional_only = false
  while i < args.length() {
    let arg = args[i]
    if positional_only {
      if opts.directory_set { raise Failure("only one scan directory is allowed") }
      opts.directory = arg
      opts.directory_set = true
      i += 1
      continue
    }
    match arg {
      "--" => positional_only = true
      "-h" | "--help" => opts.help = true
      "--config" => { i += 1; opts.config = option_value(args, i, arg) }
      "--baseline" => { i += 1; opts.baseline = Some(option_value(args, i, arg)) }
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
      "--incremental" | "--watch" | "--watch-interval" =>
        raise Failure("\{arg} is not implemented; use a supported single-run scan mode")
      "--ext" => {
        i += 1
        let value = option_value(args, i, arg)
        for extension in value.split(",") {
          let ext = extension.trim().to_owned()
          if ext == "" || ext == "." || ext.contains("/") || ext.contains("*") {
            raise Failure("--ext expects non-empty comma-separated extensions")
          }
          if !opts.exts.contains(ext) { opts.exts.push(ext) }
        }
      }
      _ => {
        if arg.has_prefix("-") { raise Failure("unknown option: \{arg}") }
        if opts.directory_set { raise Failure("only one scan directory is allowed") }
        opts.directory = arg
        opts.directory_set = true
      }
    }
    i += 1
  }
  opts
}

///|
fn print_help() -> Unit {
  println([
    "moonlint — a config-driven convention linter",
    "Usage: moonlint [options] [directory]",
    "",
    "  --config <file>    rules JSON (default: moonlint.json)",
    "  --baseline <file>  strict legacy finding-hash JSON array",
    "  --update-baseline  atomically refresh from a full, successful tree scan",
    "  --summary          show rule totals and read/skip/failure counts",
    "  --errors-only      hide warning findings (including in --summary)",
    "  --ext <list>       comma-separated extension filter, in every mode",
    "",
    "Scan modes (mutually exclusive; default: working-tree walk):",
    "  --changed <ref>    merge-base(ref, HEAD)..HEAD files; read HEAD blobs",
    "  --staged           read actual index blobs, not working-tree copies",
    "  --glob <pattern>   repeatable union; *, ?, standalone ** segments",
    "  --stdin            root-relative paths, one per line (no trim)",
    "  --stdin0           NUL-separated paths (supports embedded newlines)",
    "",
    "Symbolic links are skipped. Git/read failures exit 2; no silent fallback.",
    "Incremental caching and Watch are not implemented and are rejected.",
    "  -h, --help         show help",
    "Exit: 0 no lint errors, 1 lint errors, 2 argument/config/scan/IO failure.",
  ].join("\n"))
}
