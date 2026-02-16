import Commander

enum ParsedValuesError: Error, CustomStringConvertible {
  case missingOption(String)
  case invalidOption(String)
  case missingArgument(String)

  var description: String {
    switch self {
    case .missingOption(let name):
      "Missing required option: --\(name)"
    case .invalidOption(let name):
      "Invalid value for option: --\(name)"
    case .missingArgument(let name):
      "Missing required argument: \(name)"
    }
  }
}

extension ParsedValues {
  func flag(_ label: String) -> Bool {
    flags.contains(label)
  }

  func option(_ label: String) -> String? {
    options[label]?.last
  }

  func optionValues(_ label: String) -> [String] {
    options[label] ?? []
  }

  func optionInt(_ label: String) -> Int? {
    guard let value = option(label) else { return nil }
    return Int(value)
  }

  func optionInt64(_ label: String) -> Int64? {
    guard let value = option(label) else { return nil }
    return Int64(value)
  }

  func optionRequired(_ label: String) throws -> String {
    guard let value = option(label), !value.isEmpty else {
      throw ParsedValuesError.missingOption(label)
    }
    return value
  }

  func argument(_ index: Int) -> String? {
    guard positional.indices.contains(index) else { return nil }
    return positional[index]
  }
}
