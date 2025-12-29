import Foundation

enum TypedStreamParser {
  static func parseAttributedBody(_ data: Data) -> String {
    guard !data.isEmpty else { return "" }
    let bytes = [UInt8](data)
    let start = [UInt8(0x01), UInt8(0x2b)]
    let end = [UInt8(0x86), UInt8(0x84)]
    var best = ""

    var index = 0
    while index + 1 < bytes.count {
      if bytes[index] == start[0], bytes[index + 1] == start[1] {
        let sliceStart = index + 2
        if let sliceEnd = findSequence(end, in: bytes, from: sliceStart) {
          var segment = Array(bytes[sliceStart..<sliceEnd])
          // Check if first byte equals length prefix (convert byte to Int for comparison)
          if segment.count > 1, Int(segment[0]) == segment.count - 1 {
            segment.removeFirst()
          }
          let candidate = String(decoding: segment, as: UTF8.self)
            .trimmingLeadingControlCharacters()
          if candidate.count > best.count {
            best = candidate
          }
        }
      }
      index += 1
    }

    if !best.isEmpty {
      return best
    }

    let text = String(decoding: bytes, as: UTF8.self)
    return text.trimmingLeadingControlCharacters()
  }

  private static func findSequence(_ needle: [UInt8], in haystack: [UInt8], from start: Int)
    -> Int?
  {
    guard !needle.isEmpty else { return nil }
    guard start >= 0, start < haystack.count else { return nil }
    let limit = haystack.count - needle.count
    if limit < start { return nil }
    var index = start
    while index <= limit {
      var matched = true
      for offset in 0..<needle.count {
        if haystack[index + offset] != needle[offset] {
          matched = false
          break
        }
      }
      if matched { return index }
      index += 1
    }
    return nil
  }
}

extension String {
  fileprivate func trimmingLeadingControlCharacters() -> String {
    var scalars = unicodeScalars
    while let first = scalars.first,
      CharacterSet.controlCharacters.contains(first) || first == "\n" || first == "\r"
    {
      scalars.removeFirst()
    }
    return String(String.UnicodeScalarView(scalars))
  }
}
