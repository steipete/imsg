import Commander

struct RuntimeOptions: Sendable {
  let jsonOutput: Bool
  let verbose: Bool
  let logLevel: String?

  init(parsedValues: ParsedValues) {
    jsonOutput = parsedValues.flags.contains("jsonOutput")
    verbose = parsedValues.flags.contains("verbose")
    logLevel = parsedValues.options["logLevel"]?.last
  }
}
