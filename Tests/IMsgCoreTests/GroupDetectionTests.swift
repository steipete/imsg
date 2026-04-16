import Foundation
import Testing

@testable import IMsgCore

@Test
func isGroupHandleRecognizesGroupMarker() {
  #expect(isGroupHandle(identifier: "iMessage;+;chat1234567890", guid: "") == true)
  #expect(isGroupHandle(identifier: "", guid: "iMessage;+;chat1234567890") == true)
  #expect(isGroupHandle(identifier: "SMS;+;chatABCDEF", guid: "") == true)
}

@Test
func isGroupHandleRejectsDirectAndEmpty() {
  // SERVICE;-;TARGET is a direct chat, not a group — deliberately excluded.
  #expect(isGroupHandle(identifier: "iMessage;-;+15551234567", guid: "") == false)
  #expect(isGroupHandle(identifier: "", guid: "iMessage;-;+15551234567") == false)
  #expect(isGroupHandle(identifier: "+15551234567", guid: "") == false)
  #expect(isGroupHandle(identifier: "user@icloud.com", guid: "") == false)
  #expect(isGroupHandle(identifier: "", guid: "") == false)
}
