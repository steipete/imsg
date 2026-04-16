import Foundation
import IMsgCore

/// Per-`chatID` memoizer for `ChatInfo` and participant lookups.
///
/// Long-lived streams (the RPC watch subscription, `imsg watch`) visit many
/// messages belonging to a small set of chats. Repeatedly re-querying
/// `chatInfo` and `participants` for the same chat id is wasteful, so the
/// cache amortizes those reads across the lifetime of the stream.
///
/// Callers that only visit a single chat id (for example `imsg history`) do
/// not need this actor — the two direct calls cost the same.
actor ChatCache {
  private let store: MessageStore
  private var infoCache: [Int64: ChatInfo] = [:]
  private var participantsCache: [Int64: [String]] = [:]

  init(store: MessageStore) {
    self.store = store
  }

  func info(chatID: Int64) throws -> ChatInfo? {
    if let cached = infoCache[chatID] { return cached }
    if let info = try store.chatInfo(chatID: chatID) {
      infoCache[chatID] = info
      return info
    }
    return nil
  }

  func participants(chatID: Int64) throws -> [String] {
    if let cached = participantsCache[chatID] { return cached }
    let participants = try store.participants(chatID: chatID)
    participantsCache[chatID] = participants
    return participants
  }
}
