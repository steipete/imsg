import Foundation
import Testing

@testable import imsg

/// Snapshot of the bridge-backed commands we expect to be wired up. Locks in
/// the surface so an accidental drop from CommandRouter.specs gets caught
/// without exercising any IMCore plumbing.
@Test
func commandRouterIncludesAllBridgeCommands() {
  let router = CommandRouter()
  let expected: [String] = [
    "send-rich", "send-multipart", "send-attachment", "tapback",
    "edit", "unsend", "delete-message", "notify-anyways",
    "chat-create", "chat-name", "chat-photo",
    "chat-add-member", "chat-remove-member",
    "chat-leave", "chat-delete", "chat-mark",
    "search", "account", "whois", "nickname",
  ]
  let registered = Set(router.specs.map { $0.name })
  for name in expected {
    #expect(registered.contains(name), "missing bridge command: \(name)")
  }
}

@Test
func bridgeMessagingCommandsExposeChatRequirement() async {
  // Each new bridge messaging command requires a `--chat` option (the chat
  // guid is the universal addressing key in v2). Ensure missing args bubble
  // up as a parse-time error rather than dropping into the bridge with empty
  // strings.
  let router = CommandRouter()
  let names = ["send-rich", "edit", "unsend", "delete-message", "tapback"]
  for name in names {
    let (_, status) = await StdoutCapture.capture {
      await router.run(argv: ["imsg", name])
    }
    #expect(status == 1, "\(name) should have required missing args")
  }
}
