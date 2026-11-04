///|
/// Deliberate acyclic UI dependency; the compiler accepts it, policy does not.
pub fn label() -> String { @ui.label() }
