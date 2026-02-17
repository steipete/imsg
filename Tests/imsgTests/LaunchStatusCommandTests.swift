import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func commandRouterIncludesLaunchCommand() async {
  let router = CommandRouter()
  let names = router.specs.map(\.name)
  #expect(names.contains("launch"))
}

@Test
func commandRouterIncludesStatusCommand() async {
  let router = CommandRouter()
  let names = router.specs.map(\.name)
  #expect(names.contains("status"))
}

@Test
func statusCommandProducesJsonOutput() async throws {
  let values = ParsedValues(
    positional: [],
    options: [:],
    flags: ["jsonOutput"]
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = await StdoutCapture.capture {
    try? await StatusCommand.run(values: values, runtime: runtime)
  }
  // JSON output should contain expected keys
  #expect(output.contains("basic_features"))
  #expect(output.contains("advanced_features"))
}

@Test
func statusCommandProducesTextOutput() async throws {
  let values = ParsedValues(
    positional: [],
    options: [:],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)

  let (output, _) = await StdoutCapture.capture {
    try? await StatusCommand.run(values: values, runtime: runtime)
  }
  #expect(output.contains("imsg Status Report"))
}
