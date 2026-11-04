///|
/// A stable greeting exported by both snapshots.
pub fn greeting() -> String { "MoonBit" }
///|
/// This exported function is intentionally absent from the next snapshot.
pub fn old_api() -> Int { 1 }
