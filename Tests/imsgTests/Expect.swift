import XCTest

@discardableResult
func expect(
  _ condition: @autoclosure () -> Bool,
  _ message: String = "",
  file: StaticString = #file,
  line: UInt = #line
) -> Bool {
  let result = condition()
  XCTAssertTrue(result, message, file: file, line: line)
  return result
}
