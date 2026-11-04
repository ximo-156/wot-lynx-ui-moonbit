///|
#derive(Debug)
enum ProjectMode {
  PackageGraph(String)
  ApiSnapshot(String)
  ApiCheck(String, String)
}

///|
fn set_project_mode(opts : Options, mode : ProjectMode) -> Unit raise {
  if opts.project_mode is Some(_) {
    raise Failure("project policy modes are mutually exclusive")
  }
  opts.project_mode = Some(mode)
}

///|
fn required_api(value : String?, flag : String) -> String raise {
  match value {
    Some(value) => value
    None => raise Failure("missing required \{flag}")
  }
}

///|
fn project_input(path : String) -> String raise {
  @fs.read_file_to_string(path) catch {
    _ => raise Failure("cannot read policy input: \{path}")
  }
}

///|
fn emit_policy(report : @lib.PolicyReport, opts : Options) -> Unit raise {
  let displayed = if opts.errors_only { report.errors_only() } else { report }
  let json = @lib.render_policy_json(displayed)
  match opts.report {
    Some(path) => @lib.write_atomic_text(path, json)
    None => ()
  }
  println(
    match opts.format {
      Text => @lib.render_policy_text(displayed, summary=opts.summary)
      Json => json
      Github => @lib.render_policy_github(displayed)
      Sarif => @lib.render_policy_sarif(displayed)
    },
  )
  if report.has_errors() {
    @sys.exit(1)
  }
}

///|
fn run_project_mode(opts : Options) -> Unit raise {
  if opts.mode_set ||
    opts.fix ||
    opts.dry_run ||
    opts.incremental ||
    opts.update_baseline ||
    opts.baseline is Some(_) ||
    opts.audit_baseline ||
    opts.baseline_today is Some(_) ||
    opts.baseline_format_set ||
    !opts.exts.is_empty() ||
    !opts.presets.is_empty() ||
    opts.init ||
    opts.list_presets {
    raise Failure(
      "project policy modes cannot be combined with source scan, fix, baseline, cache, init or presets",
    )
  }
  let mode = match opts.project_mode {
    Some(mode) => mode
    None => raise Failure("missing project policy mode")
  }
  match mode {
    PackageGraph(path) => {
      if !opts.config_set {
        raise Failure(
          "--package-graph requires an explicit --config policy file",
        )
      }
      if opts.api_toolchain is Some(_) ||
        opts.api_backend is Some(_) ||
        opts.api_module_version is Some(_) ||
        opts.api_version_policy != "none" {
        raise Failure("API options do not apply to --package-graph")
      }
      let rules = match @lib.parse_package_policy(project_input(opts.config)) {
        Ok(rules) => rules
        Err(@lib.ConfigError(msg)) =>
          raise Failure("package policy config: \{msg}")
      }
      let report = match @lib.check_package_graph(project_input(path), rules) {
        Ok(report) => report
        Err(@lib.ConfigError(msg)) =>
          raise Failure("package graph inconclusive: \{msg}")
      }
      emit_policy(report, opts)
    }
    ApiSnapshot(path) => {
      if opts.config_set ||
        opts.summary ||
        opts.errors_only ||
        opts.api_version_policy != "none" ||
        (opts.format != Text && opts.format != Json) {
        raise Failure(
          "--api-snapshot writes JSON and does not accept config, summary or release policies",
        )
      }
      let snapshot = match
        @lib.make_api_snapshot(
          project_input(path),
          required_api(opts.api_toolchain, "--api-toolchain"),
          required_api(opts.api_backend, "--api-backend"),
          required_api(opts.api_module_version, "--api-module-version"),
        ) {
        Ok(snapshot) => snapshot
        Err(@lib.ConfigError(msg)) =>
          raise Failure("API snapshot inconclusive: \{msg}")
      }
      match opts.report {
        Some(path) => @lib.write_atomic_text(path, snapshot)
        None => ()
      }
      println(snapshot)
    }
    ApiCheck(before, after) => {
      if opts.config_set ||
        opts.api_toolchain is Some(_) ||
        opts.api_backend is Some(_) ||
        opts.api_module_version is Some(_) {
        raise Failure(
          "--api-check reads package, toolchain, backend and versions from the snapshots",
        )
      }
      let report = match
        @lib.check_api_snapshots(
          project_input(before),
          project_input(after),
          opts.api_version_policy,
        ) {
        Ok(report) => report
        Err(@lib.ConfigError(msg)) =>
          raise Failure("API comparison inconclusive: \{msg}")
      }
      emit_policy(report, opts)
    }
  }
}
