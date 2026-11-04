///|
/// Adds two numbers.
pub fn add(a : Int32, b : Int32) -> Int32 {
  a + b
}

///|
pub fn badName() -> Int32 {
  1
}

///|
pub struct Point {
  x : Int32
}

///|
pub fn parse(text : String) -> Int32 {
  let value = Some(text.length()).unwrap()
  // TODO: handle malformed input
  value
}
