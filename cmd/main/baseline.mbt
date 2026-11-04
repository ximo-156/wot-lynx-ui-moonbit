///|
fn baseline_text(path : String) -> String raise {
  @fs.read_file_to_string(path) catch { _ => raise Failure("cannot read baseline: \{path}") }
}

///|
fn capture_baseline_v2(findings : Array[@lib.Finding], opts : Options) -> @lib.BaselineV2 raise {
  let reason = required_api(opts.baseline_reason, "--baseline-reason")
  let owner = required_api(opts.baseline_owner, "--baseline-owner")
  match @lib.BaselineV2::capture(findings, reason, owner, opts.baseline_expires) {
    Ok(baseline) => baseline
    Err(@lib.ConfigError(msg)) => raise Failure("baseline v2: \{msg}")
  }
}

///|
fn partition_baseline_v2(baseline : @lib.BaselineV2, result : @lib.LintResult,
  opts : Options) -> (@lib.LintResult, @lib.PolicyReport) raise {
  let today = match opts.baseline_today { Some(date) => date; None => @lib.utc_date() }
  match baseline.partition(result.findings, today) {
    Ok((findings, suppressed, audit)) => (result.with_findings(findings, suppressed.length()), audit)
    Err(@lib.ConfigError(msg)) => raise Failure("baseline v2: \{msg}")
  }
}

///|
/// Complete every ordinary scan, including the post-fix scan, under one
/// baseline/error contract. A baseline is loaded only when explicitly named.
fn finish_source_run(result : @lib.LintResult, opts : Options, scan : @lib.ScanInfo) -> Unit raise {
  if result.files_failed + result.context_files_failed > 0 {
    write_report(result, opts, scan)
    emit(result, opts, scan)
    @sys.exit(2)
    return
  }
  if opts.update_baseline {
    let path = opts.baseline.unwrap_or("moonlint.baseline.json")
    if opts.migrate_baseline {
      let source = baseline_text(path)
      if !source.trim().to_owned().has_prefix("[") { raise Failure("--migrate-baseline requires a legacy array baseline") }
      let legacy = @lib.Baseline::parse(source)
      let (_, suppressed) = legacy.partition(result.findings)
      let baseline = capture_baseline_v2(suppressed, opts)
      let (filtered, _) = partition_baseline_v2(baseline, result, opts)
      @lib.write_atomic_text(path, baseline.render())
      if opts.format is Text { println("moonlint: migrated only \{suppressed.length()} currently matched legacy findings to \{path}") }
      write_report(filtered, opts, scan)
      emit(filtered, opts, scan)
      if filtered.has_errors() { @sys.exit(1) }
      return
    }
    if !opts.baseline_format_set && @lib.source_path_kind(path) == 1 &&
      baseline_text(path).trim().to_owned().has_prefix("{") {
      raise Failure("updating a v2 baseline requires explicit --baseline-format v2 and exception metadata")
    }
    let source = if opts.baseline_format == "v2" {
      capture_baseline_v2(result.findings, opts).render()
    } else { @lib.Baseline::render(result.findings) }
    @lib.write_atomic_text(path, source)
    if opts.format is Text { println("moonlint: wrote \{result.findings.length()} findings to \{path}; future runs must pass --baseline \{path}") }
    write_report(result, opts, scan)
    emit(result, opts, scan)
    return
  }
  let filtered = match opts.baseline {
    None => result
    Some(path) => {
      let source = baseline_text(path)
      if source.trim().to_owned().has_prefix("[") {
        if opts.audit_baseline || opts.baseline_today is Some(_) { raise Failure("audit/date options require a v2 baseline; migrate the legacy array first") }
        let baseline = @lib.Baseline::parse(source)
        let (findings, suppressed) = baseline.partition(result.findings)
        result.with_findings(findings, suppressed.length())
      } else {
        let baseline = match @lib.BaselineV2::parse(source) {
          Ok(baseline) => baseline
          Err(@lib.ConfigError(msg)) => raise Failure("baseline v2: \{msg}")
        }
        let (filtered, audit) = partition_baseline_v2(baseline, result, opts)
        if opts.audit_baseline {
          emit_policy(@lib.baseline_audit_with_findings(audit, filtered), opts)
          return
        }
        if !audit.issues.is_empty() {
          eprintln("moonlint: baseline v2 has expired/unused exceptions; run --audit-baseline on a full scan")
        }
        filtered
      }
    }
  }
  write_report(filtered, opts, scan)
  emit(filtered, opts, scan)
  if filtered.has_errors() { @sys.exit(1) }
}
