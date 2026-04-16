import Foundation

/// Returns `true` when the chat identifier or GUID encodes a group chat.
///
/// Messages stores group chats with a `SERVICE;+;TARGET` encoding (for example
/// `iMessage;+;chat1234567890`). Direct 1:1 chats use `SERVICE;-;TARGET`. Only
/// the `;+;` marker is treated as a group here; the `;-;` form is intentionally
/// excluded so SMS/iMessage direct chats are not misclassified.
public func isGroupHandle(identifier: String, guid: String) -> Bool {
  return guid.contains(";+;") || identifier.contains(";+;")
}
