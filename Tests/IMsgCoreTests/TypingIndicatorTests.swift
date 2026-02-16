import Foundation
import Testing

@testable import IMsgCore

@Test
func typingIndicatorStopsOnCancellation() async {
  var events: [String] = []

  do {
    try await TypingIndicator.typeForDuration(
      chatIdentifier: "iMessage;+;chat123",
      duration: 1,
      startTyping: { _ in events.append("start") },
      stopTyping: { _ in events.append("stop") },
      sleep: { _ in throw CancellationError() }
    )
    #expect(Bool(false))
  } catch is CancellationError {
    #expect(Bool(true))
  } catch {
    #expect(Bool(false))
  }

  #expect(events == ["start", "stop"])
}

@Test
func typingIndicatorStopsAfterNormalDuration() async throws {
  var events: [String] = []
  var didSleep = false

  try await TypingIndicator.typeForDuration(
    chatIdentifier: "iMessage;+;chat123",
    duration: 1,
    startTyping: { _ in events.append("start") },
    stopTyping: { _ in events.append("stop") },
    sleep: { _ in didSleep = true }
  )

  #expect(didSleep == true)
  #expect(events == ["start", "stop"])
}
