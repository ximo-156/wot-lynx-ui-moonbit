///|
/// One version-1 architecture rule over compiler package identities.
/// Identities are `module` for the root package or `module/rel` otherwise.
/// Pattern lists use the existing portable GlobPattern syntax and match the
/// complete identity, not every descendant of a matched directory.
#derive(Debug, Eq)
pub struct PackagePolicyRule {
  /// Unique, nonblank identifier used in policy findings.
  id : String
  /// Error or warning; JSON must explicitly use `error` or `warning`.
  severity : Severity
  /// Nonempty list of origin globs, applied only to graph root packages.
  from : Array[String]
  /// Allowed destinations; Some([]) deliberately forbids every destination.
  /// Exactly one of allow and deny must be present.
  allow : Array[String]?
  /// Nonempty list of forbidden destinations, mutually exclusive with allow.
  deny : Array[String]?
  /// Policy kind tags: source, test (blackbox-test), and wbtest (whitebox-test).
  /// An omitted JSON field defaults to ["source"]. Explicit [] is invalid.
  kinds : Array[String]
  /// Optional backend restriction: native, js, wasm, wasm-gc, or llvm.
  /// None means every backend; Some([]) is invalid.
  targets : Array[String]?
  /// Nonblank explanation copied into each finding's message and details.
  reason : String
}

///|
/// Parse a strict version-1 package-policy JSON document.
/// Requires a nonempty `package_rules` array; each rule requires id, severity,
/// from, reason, and exactly one allow/deny array. Unknown fields, duplicate
/// JSON keys or rule ids, malformed arrays, and invalid globs are ConfigError.
/// Parsed pattern/kind/target lists are deduplicated and sorted; rule declaration
/// order is retained. An empty allowlist is an explicit deny-all policy.
pub fn parse_package_policy(
  src : String,
) -> Result[Array[PackagePolicyRule], ConfigError] {
  Ok(package_policy_parse_impl(src)) catch {
    ConfigError(message) => Err(ConfigError(message))
  }
}

///|
/// Check one actual `moon tree --package --json` version-3 graph.
/// Fully validates the graph, even when no rule applies. Only direct edges
/// originating at selected root packages and ending at supplied non-stdlib
/// nodes are checked. The compiler omits stdlib imports; neither stdlib nor
/// transitive dependencies are covered. Backends are never combined, and each
/// source/test/wbtest edge kind is evaluated independently.
/// Duplicate edges are collapsed by origin, destination, kind, and alias;
/// findings are sorted by rule id, origin, destination, kind, target, and alias.
/// Details contain from/to/kind/target/alias/reason, never invented locations.
/// `packages` counts unique graph root packages; `edges_checked` counts unique
/// edge-kind/alias records to which at least one rule applies, not rule matches.
/// Empty rule sets fail. A valid graph with no applicable rule or edge returns
/// checked0 with an explicit `applicability` metadata marker, not an unqualified
/// pass. Graph versions and indices must be nonnegative integer JSON literals.
pub fn check_package_graph(
  src : String,
  rules : Array[PackagePolicyRule],
) -> Result[PolicyReport, ConfigError] {
  Ok(package_policy_check_impl(src, rules)) catch {
    ConfigError(message) => Err(ConfigError(message))
  }
}

///|
/// Expose the derived debugging representation as a regular rule method.
pub extend PackagePolicyRule with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Expose structural equality and inequality as regular rule methods.
pub extend PackagePolicyRule with Eq::{equal, not_equal}

///|
priv struct PackagePolicyCompiledRule {
  rule : PackagePolicyRule
  from : Array[GlobPattern]
  allow : Array[GlobPattern]?
  deny : Array[GlobPattern]?
}

///|
priv struct PackagePolicyNode {
  module : String
  package : String
}

///|
priv struct PackagePolicyEdge {
  from : Int32
  to : Int32
  kind : String
  alias : String
}

///|
priv struct PackagePolicyGraph {
  target : String
  nodes : Array[PackagePolicyNode]
  roots : Array[Int32]
  edges : Array[PackagePolicyEdge]
}

///|
fn package_policy_parse_json(
  src : String,
  label : String,
) -> Json raise ConfigError {
  @json.parse(src, reject_duplicate_keys=true, preserve_number_repr=true) catch {
    @json.DuplicateKey(_, key) =>
      raise ConfigError("\{label} contains duplicate JSON field \"\{key}\"")
    _ => raise ConfigError("\{label} is not valid JSON")
  }
}

///|
fn package_policy_object(
  json : Json,
  label : String,
) -> Map[String, Json] raise ConfigError {
  match json {
    Object(obj) => obj
    _ => raise ConfigError("\{label} must be a JSON object")
  }
}

///|
fn package_policy_known_fields(
  obj : Map[String, Json],
  allowed : Array[String],
  label : String,
) -> Unit raise ConfigError {
  let unknown : Array[String] = []
  for (key, _) in obj {
    if !allowed.contains(key) {
      unknown.push(key)
    }
  }
  unknown.sort_by(String::lexical_compare)
  if !unknown.is_empty() {
    raise ConfigError("\{label}: unknown field \"\{unknown[0]}\"")
  }
}

///|
fn package_policy_required(
  obj : Map[String, Json],
  key : String,
  label : String,
) -> Json raise ConfigError {
  match obj.get(key) {
    Some(value) => value
    None => raise ConfigError("\{label}: missing \"\{key}\"")
  }
}

///|
fn package_policy_required_string(
  obj : Map[String, Json],
  key : String,
  label : String,
) -> String raise ConfigError {
  match package_policy_required(obj, key, label) {
    String(value) => value
    _ => raise ConfigError("\{label}.\{key} must be a string")
  }
}

///|
fn package_policy_required_array(
  obj : Map[String, Json],
  key : String,
  label : String,
) -> Array[Json] raise ConfigError {
  match package_policy_required(obj, key, label) {
    Array(values) => values
    _ => raise ConfigError("\{label}.\{key} must be an array")
  }
}

///|
fn package_policy_string_list(
  json : Json,
  label : String,
) -> Array[String] raise ConfigError {
  let values = match json {
    Array(values) => values
    _ => raise ConfigError("\{label} must be an array of strings")
  }
  let seen : Set[String] = Set([])
  let result : Array[String] = []
  for (index, value) in values.iter2() {
    let text = match value {
      String(text) => text
      _ => raise ConfigError("\{label}[\{index}] must be a string")
    }
    if !seen.contains(text) {
      seen.add(text)
      result.push(text)
    }
  }
  result.sort_by(String::lexical_compare)
  result
}

///|
fn package_policy_integer(
  json : Json,
  label : String,
) -> Int32 raise ConfigError {
  let text = match json {
    Number(_, repr=Some(text)) => text
    _ => raise ConfigError("\{label} must be a nonnegative integer literal")
  }
  for c in text.iter() {
    if c < '0' || c > '9' {
      raise ConfigError("\{label} must be a nonnegative integer literal")
    }
  }
  @string.parse_int(text) catch {
    _ => raise ConfigError("\{label} integer is outside 0..2147483647")
  }
}

///|
fn package_policy_nonblank(
  text : String,
  label : String,
) -> Unit raise ConfigError {
  if text.trim() == "" || text.contains("\u{0}") {
    raise ConfigError("\{label} must be a nonblank string without NUL")
  }
}

///|
fn package_policy_compile_patterns(
  patterns : Array[String],
  allow_empty : Bool,
  label : String,
) -> Array[GlobPattern] raise ConfigError {
  if !allow_empty && patterns.is_empty() {
    raise ConfigError("\{label} must not be empty")
  }
  let result : Array[GlobPattern] = []
  for (index, pattern) in patterns.iter2() {
    validate_glob(pattern) catch {
      Failure(message) => raise ConfigError("\{label}[\{index}]: \{message}")
      _ => raise ConfigError("\{label}[\{index}]: invalid portable glob")
    }
    result.push(GlobPattern::new(pattern))
  }
  result
}

///|
fn package_policy_target_valid(target : String) -> Bool {
  match target {
    "native" | "js" | "wasm" | "wasm-gc" | "llvm" => true
    _ => false
  }
}

///|
fn package_policy_compile_rule(
  rule : PackagePolicyRule,
  label : String,
) -> PackagePolicyCompiledRule raise ConfigError {
  package_policy_nonblank(rule.id, "\{label}.id")
  for c in rule.id.iter() {
    if c.is_whitespace() || c.to_int() < 32 || c.to_int() == 127 {
      raise ConfigError("\{label}.id must not contain whitespace or controls")
    }
  }
  package_policy_nonblank(rule.reason, "\{label}.reason")
  let from = package_policy_compile_patterns(rule.from, false, "\{label}.from")
  let (allow, deny) = match (rule.allow, rule.deny) {
    (Some(patterns), None) =>
      (
        Some(package_policy_compile_patterns(patterns, true, "\{label}.allow")),
        None,
      )
    (None, Some(patterns)) =>
      (
        None,
        Some(package_policy_compile_patterns(patterns, false, "\{label}.deny")),
      )
    _ => raise ConfigError("\{label} requires exactly one of allow or deny")
  }
  if rule.kinds.is_empty() {
    raise ConfigError("\{label}.kinds must not be empty")
  }
  for kind in rule.kinds {
    match kind {
      "source" | "test" | "wbtest" => ()
      _ => raise ConfigError("\{label}.kinds: unknown kind \"\{kind}\"")
    }
  }
  match rule.targets {
    None => ()
    Some(targets) => {
      if targets.is_empty() {
        raise ConfigError("\{label}.targets must not be empty")
      }
      for target in targets {
        if !package_policy_target_valid(target) {
          raise ConfigError("\{label}.targets: unknown target \"\{target}\"")
        }
      }
    }
  }
  { rule, from, allow, deny, }
}

///|
fn package_policy_compile_rules(
  rules : Array[PackagePolicyRule],
) -> Array[PackagePolicyCompiledRule] raise ConfigError {
  if rules.is_empty() {
    raise ConfigError("package policy requires a nonempty package_rules array")
  }
  let ids : Set[String] = Set([])
  let compiled : Array[PackagePolicyCompiledRule] = []
  for (index, rule) in rules.iter2() {
    if ids.contains(rule.id) {
      raise ConfigError("duplicate package rule id: \{rule.id}")
    }
    ids.add(rule.id)
    compiled.push(package_policy_compile_rule(rule, "package_rules[\{index}]"))
  }
  compiled.sort_by((a, b) => a.rule.id.lexical_compare(b.rule.id))
  compiled
}

///|
fn package_policy_parse_impl(
  src : String,
) -> Array[PackagePolicyRule] raise ConfigError {
  let obj = package_policy_object(
    package_policy_parse_json(src, "package policy"),
    "package policy",
  )
  package_policy_known_fields(
    obj,
    ["version", "package_rules"],
    "package policy",
  )
  let version = package_policy_integer(
    package_policy_required(obj, "version", "package policy"),
    "package policy.version",
  )
  if version != 1 {
    raise ConfigError(
      "unsupported package policy version \{version}; expected 1",
    )
  }
  let values = package_policy_required_array(
    obj, "package_rules", "package policy",
  )
  let rules : Array[PackagePolicyRule] = []
  for (index, value) in values.iter2() {
    let label = "package_rules[\{index}]"
    let rule_obj = package_policy_object(value, label)
    package_policy_known_fields(
      rule_obj,
      ["id", "severity", "from", "allow", "deny", "kinds", "targets", "reason"],
      label,
    )
    let id = package_policy_required_string(rule_obj, "id", label)
    let severity = match
      package_policy_required_string(rule_obj, "severity", label) {
      "error" => Severity::Error
      "warning" => Severity::Warning
      other =>
        raise ConfigError("\{label}.severity: unknown severity \"\{other}\"")
    }
    let from = package_policy_string_list(
      package_policy_required(rule_obj, "from", label),
      "\{label}.from",
    )
    let allow = match rule_obj.get("allow") {
      None => None
      Some(value) => Some(package_policy_string_list(value, "\{label}.allow"))
    }
    let deny = match rule_obj.get("deny") {
      None => None
      Some(value) => Some(package_policy_string_list(value, "\{label}.deny"))
    }
    let kinds = match rule_obj.get("kinds") {
      None => ["source"]
      Some(value) => package_policy_string_list(value, "\{label}.kinds")
    }
    let targets = match rule_obj.get("targets") {
      None => None
      Some(value) => Some(package_policy_string_list(value, "\{label}.targets"))
    }
    let reason = package_policy_required_string(rule_obj, "reason", label)
    rules.push({ id, severity, from, allow, deny, kinds, targets, reason, })
  }
  ignore(package_policy_compile_rules(rules))
  rules
}

///|
fn package_policy_literal_path(
  text : String,
  allow_empty : Bool,
  label : String,
) -> Unit raise ConfigError {
  if allow_empty && text == "" {
    return
  }
  validate_glob(text) catch {
    Failure(message) =>
      raise ConfigError("\{label}: invalid package identity: \{message}")
    _ => raise ConfigError("\{label}: invalid package identity")
  }
  for c in text.iter() {
    if c == '*' ||
      c == '?' ||
      c == ':' ||
      c == '@' ||
      c.is_whitespace() ||
      c.to_int() < 32 ||
      c.to_int() == 127 {
      raise ConfigError("\{label} must be a normalized literal package path")
    }
  }
}

///|
fn package_policy_parse_node(
  json : Json,
  index : Int32,
) -> PackagePolicyNode raise ConfigError {
  let label = "graph.nodes[\{index}]"
  let obj = package_policy_object(json, label)
  package_policy_known_fields(
    obj,
    ["module", "version", "source", "rel"],
    label,
  )
  let module = package_policy_required_string(obj, "module", label)
  package_policy_literal_path(module, false, "\{label}.module")
  let version = package_policy_required_string(obj, "version", label)
  package_policy_nonblank(version, "\{label}.version")
  let rel = package_policy_required_string(obj, "rel", label)
  package_policy_literal_path(rel, true, "\{label}.rel")
  let source_label = "\{label}.source"
  let source = package_policy_object(
    package_policy_required(obj, "source", label),
    source_label,
  )
  match package_policy_required_string(source, "kind", source_label) {
    "registry" => package_policy_known_fields(source, ["kind"], source_label)
    "local" => {
      package_policy_known_fields(source, ["kind", "path"], source_label)
      package_policy_nonblank(
        package_policy_required_string(source, "path", source_label),
        "\{source_label}.path",
      )
    }
    kind =>
      raise ConfigError("\{source_label}: unsupported source kind \"\{kind}\"")
  }
  let package = if rel == "" { module } else { "\{module}/\{rel}" }
  { module, package, }
}

///|
fn package_policy_index(
  json : Json,
  node_count : Int32,
  label : String,
) -> Int32 raise ConfigError {
  let index = package_policy_integer(json, label)
  if index >= node_count {
    raise ConfigError(
      "\{label} index \{index} is outside graph.nodes (length \{node_count})",
    )
  }
  index
}

///|
fn package_policy_alias_valid(alias : String) -> Bool {
  let mut first = true
  for c in alias.iter() {
    let letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
    let digit = c >= '0' && c <= '9'
    if !letter && (first || !digit) {
      return false
    }
    first = false
  }
  !first
}

///|
fn package_policy_graph_kind(
  kind : String,
  label : String,
) -> String raise ConfigError {
  match kind {
    "source" => "source"
    "blackbox-test" => "test"
    "whitebox-test" => "wbtest"
    _ => raise ConfigError("\{label}: unknown graph edge kind \"\{kind}\"")
  }
}

///|
fn package_policy_compare_edges(
  a : PackagePolicyEdge,
  b : PackagePolicyEdge,
  nodes : Array[PackagePolicyNode],
) -> Int32 {
  let from_order = nodes[a.from].package.lexical_compare(nodes[b.from].package)
  if from_order != 0 {
    return from_order
  }
  let to_order = nodes[a.to].package.lexical_compare(nodes[b.to].package)
  if to_order != 0 {
    return to_order
  }
  let kind_order = a.kind.lexical_compare(b.kind)
  if kind_order != 0 {
    return kind_order
  }
  a.alias.lexical_compare(b.alias)
}

///|
fn package_policy_parse_graph(
  src : String,
) -> PackagePolicyGraph raise ConfigError {
  let obj = package_policy_object(
    package_policy_parse_json(src, "package graph"),
    "package graph",
  )
  package_policy_known_fields(
    obj,
    ["version", "status", "error", "target", "root", "nodes", "edges", "logs"],
    "package graph",
  )
  let version = package_policy_integer(
    package_policy_required(obj, "version", "package graph"),
    "graph.version",
  )
  if version != 3 {
    raise ConfigError(
      "unsupported package graph version \{version}; expected 3",
    )
  }
  let status = package_policy_required_string(obj, "status", "package graph")
  if status != "success" {
    raise ConfigError("package graph status must be success, got \"\{status}\"")
  }
  if !(package_policy_required(obj, "error", "package graph") is Null) {
    raise ConfigError("successful package graph must have error: null")
  }
  let target = package_policy_required_string(obj, "target", "package graph")
  if !package_policy_target_valid(target) {
    raise ConfigError("package graph: unknown target \"\{target}\"")
  }
  ignore(package_policy_required_array(obj, "logs", "package graph"))
  let node_values = package_policy_required_array(obj, "nodes", "package graph")
  if node_values.is_empty() {
    raise ConfigError("package graph.nodes must not be empty")
  }
  let nodes : Array[PackagePolicyNode] = []
  let identities : Set[String] = Set([])
  for (index, value) in node_values.iter2() {
    let node = package_policy_parse_node(value, index)
    if identities.contains(node.package) {
      raise ConfigError(
        "graph.nodes[\{index}]: duplicate package identity \{node.package}",
      )
    }
    identities.add(node.package)
    nodes.push(node)
  }
  let root_values = package_policy_required_array(obj, "root", "package graph")
  if root_values.is_empty() {
    raise ConfigError("package graph.root must select at least one package")
  }
  let roots : Array[Int32] = []
  let seen_roots : Set[Int32] = Set([])
  for (index, value) in root_values.iter2() {
    let root = package_policy_index(
      value,
      nodes.length(),
      "graph.root[\{index}]",
    )
    if !seen_roots.contains(root) {
      seen_roots.add(root)
      roots.push(root)
    }
  }
  roots.sort_by((a, b) => nodes[a].package.lexical_compare(nodes[b].package))
  let edge_values = package_policy_required_array(obj, "edges", "package graph")
  let edges : Array[PackagePolicyEdge] = []
  let seen_edges : Set[String] = Set([])
  for (index, value) in edge_values.iter2() {
    let label = "graph.edges[\{index}]"
    let edge_obj = package_policy_object(value, label)
    package_policy_known_fields(
      edge_obj,
      ["from", "to", "alias", "kinds"],
      label,
    )
    let from = package_policy_index(
      package_policy_required(edge_obj, "from", label),
      nodes.length(),
      "\{label}.from",
    )
    let to = package_policy_index(
      package_policy_required(edge_obj, "to", label),
      nodes.length(),
      "\{label}.to",
    )
    let alias = package_policy_required_string(edge_obj, "alias", label)
    if !package_policy_alias_valid(alias) {
      raise ConfigError("\{label}.alias must be a nonempty ASCII identifier")
    }
    let kinds = package_policy_string_list(
      package_policy_required(edge_obj, "kinds", label),
      "\{label}.kinds",
    )
    if kinds.is_empty() {
      raise ConfigError("\{label}.kinds must not be empty")
    }
    for graph_kind in kinds {
      let kind = package_policy_graph_kind(graph_kind, "\{label}.kinds")
      let key = "\{from}\u{0}\{to}\u{0}\{kind}\u{0}\{alias}"
      if !seen_edges.contains(key) {
        seen_edges.add(key)
        edges.push({ from, to, kind, alias, })
      }
    }
  }
  edges.sort_by((a, b) => package_policy_compare_edges(a, b, nodes))
  { target, nodes, roots, edges, }
}

///|
fn package_policy_rule_target_matches(
  rule : PackagePolicyRule,
  target : String,
) -> Bool {
  match rule.targets {
    None => true
    Some(targets) => targets.contains(target)
  }
}

///|
fn package_policy_rule_violates(
  rule : PackagePolicyCompiledRule,
  destination : String,
) -> Bool {
  match rule.allow {
    Some(patterns) => !patterns.any(pattern => pattern.matches(destination))
    None =>
      match rule.deny {
        Some(patterns) => patterns.any(pattern => pattern.matches(destination))
        None => false // Impossible after compile_rules validates exactly one.
      }
  }
}

///|
fn package_policy_compare_issues(a : PolicyIssue, b : PolicyIssue) -> Int32 {
  let rule_order = a.rule_id.lexical_compare(b.rule_id)
  if rule_order != 0 {
    return rule_order
  }
  for key in ["from", "to", "kind", "target", "alias"] {
    let order = a.details
      .get(key)
      .unwrap()
      .lexical_compare(b.details.get(key).unwrap())
    if order != 0 {
      return order
    }
  }
  0
}

///|
fn package_policy_check_impl(
  src : String,
  rules : Array[PackagePolicyRule],
) -> PolicyReport raise ConfigError {
  let compiled = package_policy_compile_rules(rules)
  let graph = package_policy_parse_graph(src)
  let active = compiled.filter(rule => {
    package_policy_rule_target_matches(rule.rule, graph.target)
  })
  let roots = Set::from_iter(graph.roots.iter())
  let selected : Set[Int32] = Set([])
  for root in graph.roots {
    let origin = graph.nodes[root]
    if origin.module != "moonbitlang/core" &&
      active.any(rule => {
        rule.from.any(pattern => pattern.matches(origin.package))
      }) {
      selected.add(root)
    }
  }
  let mut edges_checked = 0
  let issues : Array[PolicyIssue] = []
  for edge in graph.edges {
    let origin = graph.nodes[edge.from]
    let destination = graph.nodes[edge.to]
    if !roots.contains(edge.from) ||
      origin.module == "moonbitlang/core" ||
      destination.module == "moonbitlang/core" {
      continue
    }
    let mut checked = false
    for rule in active {
      if !rule.rule.kinds.contains(edge.kind) ||
        !rule.from.any(pattern => pattern.matches(origin.package)) {
        continue
      }
      checked = true
      if package_policy_rule_violates(rule, destination.package) {
        let details : Map[String, String] = {
          "from": origin.package,
          "to": destination.package,
          "kind": edge.kind,
          "target": graph.target,
          "alias": edge.alias,
          "reason": rule.rule.reason,
        }
        issues.push({
          rule_id: rule.rule.id,
          severity: rule.rule.severity,
          message: "\{origin.package} -> \{destination.package} is not permitted: \{rule.rule.reason}",
          details,
        })
      }
    }
    if checked {
      edges_checked += 1
    }
  }
  issues.sort_by(package_policy_compare_issues)
  let applicability = if active.is_empty() {
    "no-rules-for-target"
  } else if selected.is_empty() {
    "no-selected-root-packages"
  } else if edges_checked == 0 {
    "no-applicable-edges"
  } else {
    "checked"
  }
  {
    mode: "package-policy",
    metadata: {
      "graph_version": "3",
      "target": graph.target,
      "coverage": "direct root-package edges to supplied non-stdlib nodes; stdlib omitted; no transitive checks",
      "applicability": applicability,
    },
    counts: { "packages": graph.roots.length(), "edges_checked": edges_checked },
    issues,
  }
}
