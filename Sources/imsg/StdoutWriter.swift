import Dispatch
import Foundation

enum StdoutWriter {
  private static let queue = DispatchQueue(label: "imsg.stdout.writer")

  private static let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return encoder
  }()

  static func writeLine(_ line: String) {
    queue.sync {
      FileHandle.standardOutput.write(Data((line + "\n").utf8))
      // Flush immediately to ensure real-time delivery of RPC notifications
      // Without this, writes are buffered and may be delayed by minutes
      try? FileHandle.standardOutput.synchronize()
    }
  }

  static func writeJSONLine<T: Encodable>(_ value: T) throws {
    let data = try jsonEncoder.encode(value)
    guard let line = String(data: data, encoding: .utf8), !line.isEmpty else { return }
    writeLine(line)
  }
}
