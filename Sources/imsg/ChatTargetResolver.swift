import Foundation
import IMsgCore

struct ChatTargetInput: Sendable {
  let recipient: String
  let chatID: Int64?
  let chatIdentifier: String
  let chatGUID: String

  var hasChatTarget: Bool {
    chatID != nil || !chatIdentifier.isEmpty || !chatGUID.isEmpty
  }
}

struct ResolvedChatTarget: Sendable {
  let chatIdentifier: String
  let chatGUID: String

  var preferredIdentifier: String? {
    if !chatGUID.isEmpty { return chatGUID }
    if !chatIdentifier.isEmpty { return chatIdentifier }
    return nil
  }
}

enum ChatTargetResolver {
  static func validateRecipientRequirements(
    input: ChatTargetInput,
    mixedTargetError: Error,
    missingRecipientError: Error
  ) throws {
    if input.hasChatTarget && !input.recipient.isEmpty {
      throw mixedTargetError
    }
    if !input.hasChatTarget && input.recipient.isEmpty {
      throw missingRecipientError
    }
  }

  static func resolveChatTarget(
    input: ChatTargetInput,
    lookupChat: (Int64) async throws -> ChatInfo?,
    unknownChatError: (Int64) -> Error
  ) async throws -> ResolvedChatTarget {
    var resolvedIdentifier = input.chatIdentifier
    var resolvedGUID = input.chatGUID

    if let chatID = input.chatID {
      guard let info = try await lookupChat(chatID) else {
        throw unknownChatError(chatID)
      }
      resolvedIdentifier = info.identifier
      resolvedGUID = info.guid
    }

    return ResolvedChatTarget(
      chatIdentifier: resolvedIdentifier,
      chatGUID: resolvedGUID
    )
  }

  /// Checks if a recipient string looks like a contact name rather than a phone/email.
  static func looksLikeName(_ recipient: String) -> Bool {
    if recipient.isEmpty { return false }
    if recipient.contains("@") { return false }
    if recipient.hasPrefix("+") { return false }
    if recipient.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "(" || $0 == ")" || $0 == " " }) {
      return false
    }
    return true
  }

  /// Resolves a contact name to a phone number or email.
  /// Returns the original recipient if it doesn't look like a name.
  /// Throws if multiple contacts match the name.
  static func resolveRecipientName(
    _ recipient: String,
    contacts: any ContactResolving
  ) throws -> String {
    guard looksLikeName(recipient) else { return recipient }
    let matches = contacts.searchByName(recipient)
    switch matches.count {
    case 0:
      return recipient
    case 1:
      return matches[0].handle
    default:
      let list = matches.map { "  \($0.name): \($0.handle)" }.joined(separator: "\n")
      throw IMsgError.invalidChatTarget(
        "Multiple contacts match \"\(recipient)\":\n\(list)\nSpecify a phone number or email instead."
      )
    }
  }
}
