///|
/// Adds two numbers.
pub fn add(a : Int, b : Int) -> Int {
  a + b
}

pub fn BadName() -> Int {
  1
}

///|
pub struct point {
  x : Int
}

///|
pub fn parse(text : String) -> Int {
  let value = @json.parse(text).unwrap()
  // TODO: handle malformed input
  value
}
