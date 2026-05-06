import Foundation
import Testing

@testable import IMsgCore

/// Smoke tests for the events-jsonl tailer. Writes a temp file, appends a few
/// JSON lines, asserts they surface in order through the AsyncStream.
@Suite("IMsgEventTailer")
struct IMsgEventTailerTests {
  @Test
  func tailerEmitsAppendedLines() async throws {
    let dir = NSTemporaryDirectory() + "imsg-tailer-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let path = (dir as NSString).appendingPathComponent("events.jsonl")
    FileManager.default.createFile(atPath: path, contents: Data(), attributes: nil)

    let tailer = IMsgEventTailer(path: path)
    let stream = tailer.events()

    // Append two events on a background task so the tailer has a chance to
    // open and start watching before lines arrive.
    Task.detached {
      try? await Task.sleep(nanoseconds: 200_000_000)
      let line1 = """
        {"event":"started-typing","data":{"chatGuid":"iMessage;-;+15551"}}
        """ + "\n"
      let line2 = """
        {"event":"stopped-typing","data":{"chatGuid":"iMessage;-;+15551"}}
        """ + "\n"
      let fp = fopen(path, "a")
      if let fp = fp {
        line1.utf8CString.withUnsafeBufferPointer { buf in
          guard let base = buf.baseAddress else { return }
          fwrite(base, 1, strlen(base), fp)
        }
        line2.utf8CString.withUnsafeBufferPointer { buf in
          guard let base = buf.baseAddress else { return }
          fwrite(base, 1, strlen(base), fp)
        }
        fflush(fp)
        fclose(fp)
      }
    }

    var collected: [String] = []
    let deadline = Date().addingTimeInterval(3.0)
    for await event in stream {
      collected.append(event.name)
      if collected.count >= 2 { break }
      if Date() > deadline { break }
    }
    tailer.stop()

    #expect(collected == ["started-typing", "stopped-typing"])
  }

  @Test
  func tailerSkipsExistingLinesByDefault() async throws {
    let dir = NSTemporaryDirectory() + "imsg-tailer-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let path = (dir as NSString).appendingPathComponent("events.jsonl")
    let oldLine = """
      {"event":"old-typing","data":{"chatGuid":"iMessage;-;+15551"}}
      """ + "\n"
    FileManager.default.createFile(
      atPath: path,
      contents: oldLine.data(using: .utf8),
      attributes: nil
    )

    let tailer = IMsgEventTailer(path: path)
    let stream = tailer.events()

    Task.detached {
      try? await Task.sleep(nanoseconds: 200_000_000)
      let newLine = """
        {"event":"started-typing","data":{"chatGuid":"iMessage;-;+15551"}}
        """ + "\n"
      let fp = fopen(path, "a")
      if let fp = fp {
        newLine.utf8CString.withUnsafeBufferPointer { buf in
          guard let base = buf.baseAddress else { return }
          fwrite(base, 1, strlen(base), fp)
        }
        fflush(fp)
        fclose(fp)
      }
    }

    var first: String?
    for await event in stream {
      first = event.name
      break
    }
    tailer.stop()

    #expect(first == "started-typing")
  }

  @Test
  func eventDecodedPayloadRoundTrip() throws {
    let raw: [String: Any] = ["chatGuid": "iMessage;-;+1", "extra": 42]
    let data = try JSONSerialization.data(withJSONObject: raw, options: [])
    let event = IMsgEventTailer.Event(timestamp: nil, name: "x", payloadJSON: data)
    let decoded = event.decodedPayload()
    #expect(decoded["chatGuid"] as? String == "iMessage;-;+1")
    #expect(decoded["extra"] as? Int == 42)
  }
}
