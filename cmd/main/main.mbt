///|
/// moonlint — command-line entry point.
///
/// Usage:
///   moonlint [options] [directory]
///
/// Options:
///   --config <file>     rules config JSON (default: moonlint.json)
///   --baseline <file>   baseline JSON of exempted finding hashes
///   --update-baseline   write current findings to the baseline file and exit
///   --summary           print a per-rule tally instead of detail
///   --errors-only       only report error-severity findings
///   --ext <list>        comma-separated extensions to scan (default: rule union)
///   -h, --help          show this help
///
/// Exit code: 0 when no error-severity findings remain, 1 otherwise.

///|
/// Parsed command-line options.
struct Options {
  mut directory : String
  mut config : String
  mut baseline : String?
  mut update_baseline : Bool
  mut summary : Bool
  mut errors_only : Bool
  mut exts : Array[String]
  mut help : Bool
}

///|
fn main {
  let opts = parse_args(@sys.get_cli_args())
  if opts.help {
    print_help()
    return
  }
  // Load and validate the rule config.
  let config_src = match read_file(opts.config) {
    Some(s) => s
    None => die("cannot read config: \{opts.config}")
  }
  let rules = match @lib.parse_config(config_src) {
    Ok(r) => r
    Err(@lib.ConfigError(msg)) => die("config error: \{msg}")
  }
  match @lib.validate_rules(rules) {
    Ok(_) => ()
    Err(@lib.ConfigError(msg)) => die("config error: \{msg}")
  }
  // Determine the scan extension set.
  let exts = if opts.exts.length() > 0 {
    opts.exts
  } else {
    @lib.collect_extensions(rules)
  }
  // Run the engine.
  let result = match @lib.lint_tree(opts.directory, rules, exts) {
    Ok(r) => r
    Err(_) => die("cannot scan directory: \{opts.directory}")
  }
  // Apply the baseline.
  let (findings, suppressed) = match opts.baseline {
    Some(path) =>
      match read_file(path) {
        Some(src) => {
          let bl = @lib.Baseline::load(src)
          bl.partition(result.findings)
        }
        None => (result.findings, [])
      }
    None => (result.findings, [])
  }
  let final_result : @lib.LintResult = @lib.LintResult::new(
    findings,
    result.files_scanned,
    suppressed.length(),
  )
  // --update-baseline writes the current findings and exits.
  if opts.update_baseline {
    let path = opts.baseline.unwrap_or("moonlint.baseline.json")
    let content = @lib.Baseline::render(final_result.findings)
    try @fs.write_string_to_file(path, content) catch {
      _ => println("moonlint: cannot write baseline: \{path}")
    } noraise {
      _ =>
        println(
          "moonlint: wrote \{final_result.findings.length()} hashes to \{path}",
        )
    }
    return
  }
  // Filter and report.
  let shown = if opts.errors_only {
    final_result.findings.filter(f => f.severity == @lib.Severity::error())
  } else {
    final_result.findings
  }
  if opts.summary {
    println(@lib.render_summary(final_result))
  } else {
    println(@lib.render_detail(shown))
  }
  // Exit non-zero when error-severity findings remain.
  if final_result.has_errors() {
    @sys.exit(1)
  }
}

///|
/// Print an error message and exit with code 2. Generic over the return type
/// so it can be used in any match arm.
fn[T] die(msg : String) -> T {
  println("moonlint: \{msg}")
  @sys.exit(2)
  abort(msg)
}

///|
/// Read a whole file, returning `None` on any error.
fn read_file(path : String) -> String? {
  try @fs.read_file_to_string(path) catch {
    _ => None
  } noraise {
    s => Some(s)
  }
}

///|
/// Parse command-line arguments into `Options`.
fn parse_args(args : Array[String]) -> Options {
  // Skip argv[0] (program name).
  let opts : Options = {
    directory: ".",
    config: "moonlint.json",
    baseline: None,
    update_baseline: false,
    summary: false,
    errors_only: false,
    exts: [],
    help: false,
  }
  let mut i = 1
  while i < args.length() {
    let a = args.unsafe_get(i)
    match a {
      "-h" | "--help" => opts.help = true
      "--config" => {
        i += 1
        if i < args.length() {
          opts.config = args.unsafe_get(i)
        }
      }
      "--baseline" => {
        i += 1
        if i < args.length() {
          opts.baseline = Some(args.unsafe_get(i))
        }
      }
      "--update-baseline" => opts.update_baseline = true
      "--summary" => opts.summary = true
      "--errors-only" => opts.errors_only = true
      "--ext" => {
        i += 1
        if i < args.length() {
          opts.exts = args
            .unsafe_get(i)
            .split(",")
            .map(s => s.to_owned())
            .to_array()
        }
      }
      _ => if not(a.starts_with("-")) { opts.directory = a }
    }
    i += 1
  }
  opts
}

///|
fn print_help() -> Unit {
  println(
    [
      "moonlint — a config-driven convention linter", "", "Usage: moonlint [options] [directory]",
      "", "Options:", "  --config <file>     rules config JSON (default: moonlint.json)",
      "  --baseline <file>   baseline JSON of exempted finding hashes", "  --update-baseline   write current findings to the baseline and exit",
      "  --summary           print a per-rule tally instead of detail", "  --errors-only       only report error-severity findings",
      "  --ext <list>        comma-separated extensions (default: rule union)", "  -h, --help          show this help",
      "", "Exit code: 0 when no error-severity findings remain, 1 otherwise.",
    ].join("\n"),
  )
}
