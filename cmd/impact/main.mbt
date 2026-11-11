///|
/// MoonImpact is advisory by default. Only --run may start a test process;
/// selecting Git input does not execute project hooks or project commands.
struct ImpactOptions {
  mut root : String
  mut root_set : Bool
  mut input_mode : String
  files : Array[String]
  mut base : String?
  mut config_path : String?
  mut format : String
  mut report_path : String?
  mut execute_tests : Bool
  mut timeout_ms : Int32
  mut timeout_set : Bool
  mut help : Bool
}

///|
fn main {
  let code = impact_main(@env.args()) catch {
    error => {
      eprintln("moonimpact: \{@lib.error_message(error)}")
      2
    }
  }
  @sys.exit(code)
}

///|
fn impact_main(args : Array[String]) -> Int32 raise {
  let opts = parse_impact_args(args)
  if opts.help {
    print_impact_help()
    return 0
  }
  let root = @lib.canonical_root(opts.root)
  let config = match opts.config_path {
    None => @lib.impact_default_config()
    Some(path) => {
      let source = @fs.read_file_to_string(path) catch {
        error =>
          raise Failure(
            "cannot read config \{path}: \{@lib.error_message(error)}",
          )
      }
      @lib.parse_impact_config(source)
    }
  }
  let changed = if opts.input_mode == "files" {
    opts.files
  } else {
    @lib.impact_git_changes(root, opts.base)
  }
  let input = match opts.base {
    Some(reference) => "base:" + reference + "..working-tree"
    None =>
      if opts.input_mode == "files" {
        "files"
      } else {
        "HEAD..working-tree"
      }
  }
  let plan = @lib.impact_plan(root, changed, config, input, [])
  if !["none", "related", "full", "blocked"].contains(plan.strategy) {
    raise Failure("planner returned an unsupported execution strategy")
  }
  let json = @lib.render_impact_json(plan)
  match opts.format {
    "json" => println(json)
    "html" => println(@lib.render_impact_html(plan))
    _ => println(@lib.render_impact_text(plan))
  }
  // Publishing is create-only, including when another process creates the
  // target between planning and writing. Never replace a source/config file.
  match opts.report_path {
    Some(path) => @lib.impact_write_report_new(path, json + "\n")
    None => ()
  }
  if plan.strategy == "blocked" {
    if opts.execute_tests {
      eprintln("moonimpact: plan is blocked; no test command was executed")
    }
    return 2
  }
  if !opts.execute_tests {
    return 0
  }
  if plan.strategy == "none" {
    eprintln(
      "moonimpact: no tests selected; no test command was executed (this is not a full-suite pass)",
    )
    return 0
  }
  let full = plan.strategy == "full"
  if !full && plan.tests.is_empty() {
    raise Failure(
      "related plan contains no tests; refusing to run an unfiltered test command",
    )
  }
  if full {
    eprintln(
      "moonimpact: full fallback; running pnpm exec vitest run with no filters",
    )
  } else {
    eprintln(
      "moonimpact: running \{plan.tests.length()} selected test file(s) with Vitest",
    )
  }
  let child_code = @lib.impact_run_vitest(
    root,
    plan.tests,
    full,
    opts.timeout_ms,
  )
  eprintln(
    "moonimpact: Vitest exited with status \{child_code}; the stdout document remains an advisory plan",
  )
  if child_code == 0 {
    0
  } else {
    1
  }
}

///|
fn option_value(
  args : Array[String],
  index : Int32,
  flag : String,
) -> String raise {
  if index >= args.length() ||
    args[index].is_empty() ||
    args[index].has_prefix("--") {
    raise Failure("missing value for \{flag}")
  }
  args[index]
}

///|
fn positive_timeout(value : String) -> Int32 raise {
  if value.is_empty() {
    raise Failure(
      "--timeout-ms must be a positive Int32 number of milliseconds",
    )
  }
  let mut count : Int32 = 0
  for c in value {
    if c < '0' || c > '9' {
      raise Failure(
        "--timeout-ms must be a positive Int32 number of milliseconds",
      )
    }
    let digit = c.to_int() - '0'.to_int()
    if count > (2147483647 - digit) / 10 {
      raise Failure("--timeout-ms exceeds the Int32 limit")
    }
    count = count * 10 + digit
  }
  if count <= 0 {
    raise Failure("--timeout-ms must be positive")
  }
  count
}

///|
fn select_input(opts : ImpactOptions, mode : String) -> Unit raise {
  if opts.input_mode != "" && !(mode == "files" && opts.input_mode == "files") {
    raise Failure(
      "choose exactly one change input: repeated --file, --worktree, or --base <ref>",
    )
  }
  opts.input_mode = mode
}

///|
fn parse_impact_args(args : Array[String]) -> ImpactOptions raise {
  let opts : ImpactOptions = {
    root: ".",
    root_set: false,
    input_mode: "",
    files: [],
    base: None,
    config_path: None,
    format: "text",
    report_path: None,
    execute_tests: false,
    timeout_ms: 60000,
    timeout_set: false,
    help: false,
  }
  let mut i = if args.length() > 1 && args[1] == "plan" { 2 } else { 1 }
  let mut positional_only = false
  while i < args.length() {
    let arg = args[i]
    if positional_only {
      if opts.root_set {
        raise Failure("only one project root is allowed")
      }
      opts.root = arg
      opts.root_set = true
      i += 1
      continue
    }
    match arg {
      "--" => positional_only = true
      "--help" | "-h" => opts.help = true
      "--file" => {
        select_input(opts, "files")
        i += 1
        opts.files.push(option_value(args, i, arg))
      }
      "--worktree" => select_input(opts, "worktree")
      "--base" => {
        select_input(opts, "base")
        i += 1
        let reference = option_value(args, i, arg)
        if reference.has_prefix("-") {
          raise Failure("--base expects a commit reference, not an option")
        }
        opts.base = Some(reference)
      }
      "--config" => {
        if opts.config_path is Some(_) {
          raise Failure("--config may only be specified once")
        }
        i += 1
        opts.config_path = Some(option_value(args, i, arg))
      }
      "--format" => {
        i += 1
        let format = option_value(args, i, arg)
        if !["text", "json", "html"].contains(format) {
          raise Failure("--format expects text, json or html")
        }
        opts.format = format
      }
      "--report" => {
        if opts.report_path is Some(_) {
          raise Failure("--report may only be specified once")
        }
        i += 1
        opts.report_path = Some(option_value(args, i, arg))
      }
      "--run" => opts.execute_tests = true
      "--timeout-ms" => {
        if opts.timeout_set {
          raise Failure("--timeout-ms may only be specified once")
        }
        i += 1
        opts.timeout_ms = positive_timeout(option_value(args, i, arg))
        opts.timeout_set = true
      }
      _ => {
        if arg.has_prefix("-") {
          raise Failure("unknown option: \{arg}")
        }
        if opts.root_set {
          raise Failure("only one project root is allowed")
        }
        opts.root = arg
        opts.root_set = true
      }
    }
    i += 1
  }
  if !opts.help {
    if opts.input_mode == "" {
      raise Failure(
        "an explicit change input is required: --file, --worktree or --base",
      )
    }
    if opts.timeout_set && !opts.execute_tests {
      raise Failure("--timeout-ms only applies with --run")
    }
  }
  opts
}

///|
fn print_impact_help() -> Unit {
  println(
    [
      "MoonImpact — explain changes and plan regression tests", "Usage: moon run cmd/impact -- [plan] [options] [root]",
      "", "Change input (required; mutually exclusive):", "  --file <path>       Root-relative changed file; repeatable; missing files are allowed",
      "  --worktree          HEAD to live working tree, including staged/unstaged/untracked",
      "  --base <ref>        Given commit to live working tree, including untracked files",
      "", "Planning and output:", "  --config <json>     Explicit config; no automatic project config discovery",
      "  --format <format>   text (default), json or html on stdout", "  --report <new-file> Also save JSON plan; parent must exist; NEVER overwrite a path",
      "  --run               Explicitly invoke pnpm exec vitest run after planning",
      "  --timeout-ms <n>    Positive timeout for --run (default: 60000 milliseconds)",
      "  -h, --help          Print help", "", "The default command only plans: it does not test, build or install dependencies.",
      "Git input requires the repository root and reads live working-tree changes, not HEAD blobs.",
      "Related mode passes ./test-path arguments; full fallback runs all Vitest tests.",
      "None and blocked strategies NEVER invoke a test process. Test output goes to stderr.",
      "A plan is advisory, not proof that unselected tests cannot fail.", "Exit: 0 plan completed/tests passed; 1 test process failed; 2 usage/IO/blocked/startup/timeout.",
    ].join("\n"),
  )
}
