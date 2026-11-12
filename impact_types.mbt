///|
/// MoonImpact configuration. Paths and glob patterns are relative to the scan
/// root. File-reader names are explicit contracts: their first argument names
/// a root-relative input. No user commands are evaluated from configuration.
#derive(Debug)
pub struct ImpactConfig {
  includes : Array[String]
  excludes : Array[String]
  tests : Array[String]
  aliases : Array[(String, String)]
  file_readers : Array[String]
  dependencies : Array[ImpactEdge]
  global_inputs : Array[String]
  style_load_paths : Array[String]
  skip_dirs : Array[String]
  runner_dir : String
  max_source_bytes : Int32
}

///|
/// A dependency edge with the location of the reference in the dependent file.
/// Manual edges use line/column zero because there is no source coordinate.
#derive(Debug)
pub struct ImpactEdge {
  dependency : String
  dependent : String
  kind : String
  line : Int32
  column : Int32
}

///|
/// An input reference before resolution. Import references identify modules;
/// read-root/read-file identify opaque file inputs; style-import-css/scss and
/// style-url distinguish stylesheet modules from static asset URLs.
#derive(Debug)
priv struct ImpactReference {
  file : String
  specifier : String
  kind : String
  line : Int32
  column : Int32
}

///|
/// A limitation or operational observation. Uncertainty forces a full test
/// plan; it must never be interpreted as evidence that no test is affected.
#derive(Debug)
pub struct ImpactIssue {
  file : String
  line : Int32
  reason : String
}

///|
/// One deterministic shortest known dependency chain from a change to a test.
#derive(Debug)
pub struct ImpactTrace {
  test_file : String
  changed : String
  chain : Array[ImpactEdge]
}

///|
/// An advisory test plan, not a passing test result. Strategy is none, related,
/// full or blocked. Tests are the effective execution set; inventory contains
/// all configured test files. A full fallback includes tests lacking a known
/// chain instead of pretending those tests were proved affected.
#derive(Debug)
pub struct ImpactPlan {
  root : String
  input : String
  changed : Array[String]
  strategy : String
  tests : Array[String]
  inventory : Array[String]
  affected : Array[String]
  traces : Array[ImpactTrace]
  issues : Array[ImpactIssue]
  reasons : Array[String]
  source_count : Int32
  edge_count : Int32
  mode : String
}

///|
pub extend ImpactConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ImpactEdge with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ImpactIssue with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ImpactTrace with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ImpactPlan with @moonbitlang/core/debug.Debug::{to_repr}
