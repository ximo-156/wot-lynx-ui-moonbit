///|
/// A project-policy finding. Details identify the API or dependency edge;
/// no invented source line is attached when compiler output has no location.
#derive(Debug)
pub struct PolicyIssue {
  rule_id : String
  severity : Severity
  message : String
  details : Map[String, String]
}

///|
/// Result of a package-graph or interface-snapshot policy check.
/// Counts describe project entities, not source files read by the linter.
#derive(Debug)
pub struct PolicyReport {
  mode : String
  metadata : Map[String, String]
  counts : Map[String, Int32]
  issues : Array[PolicyIssue]
}

///|
/// Whether this policy run has any blocking findings.
pub fn PolicyReport::has_errors(self : PolicyReport) -> Bool {
  self.issues.any(issue => issue.severity == Severity::Error)
}

///|
/// Filter presentation without changing the project scan counters.
pub fn PolicyReport::errors_only(self : PolicyReport) -> PolicyReport {
  { mode: self.mode, metadata: self.metadata, counts: self.counts,
    issues: self.issues.filter(issue => issue.severity == Severity::Error) }
}
