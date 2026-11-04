///|
/// Adds two numbers.
pub fn add(a : Int, b : Int) -> Int {
  a + b
}

pub fn badName() -> Int {
  1
}

///|
pub struct Point {
  x : Int
}

///|
pub fn parse(text : String) -> Int {
  let value = Some(text.length()).unwrap()
  // TODO: handle malformed input
  value
}
