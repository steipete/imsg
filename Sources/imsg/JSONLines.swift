import Foundation

enum JSONLines {
  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return encoder
  }()

  static func encode(_ value: some Encodable) throws -> String {
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8) ?? ""
  }

  static func print(_ value: some Encodable) throws {
    let line = try encode(value)
    if !line.isEmpty {
      StdoutWriter.writeLine(line)
    }
  }
}
