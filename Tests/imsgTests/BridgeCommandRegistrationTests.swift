import Commander
import Foundation
import IMsgCore
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
    "account", "whois", "nickname",
  ]
  let registered = Set(router.specs.map { $0.name })
  for name in expected {
    #expect(registered.contains(name), "missing bridge command: \(name)")
  }
  #expect(registered.contains("search"), "missing local search command")
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

@Test
func chatMarkRejectsConflictingFlags() async {
  let router = CommandRouter()
  let (output, status) = await StdoutCapture.capture {
    await router.run(argv: [
      "imsg", "chat-mark", "--chat", "iMessage;-;+15551234567", "--read", "--unread",
    ])
  }
  #expect(status == 1)
  #expect(output.contains("Invalid value for option: --read"))
}

@Test
func chatCreateRejectsUnsupportedServiceBeforeBridgeLaunch() async {
  let values = ParsedValues(
    positional: [],
    options: [
      "addresses": ["+15551234567"],
      "service": ["SMS"],
    ],
    flags: []
  )
  let runtime = RuntimeOptions(parsedValues: values)

  do {
    try await ChatCreateCommand.run(values: values, runtime: runtime)
    #expect(Bool(false))
  } catch let error as IMsgError {
    switch error {
    case .unsupportedService(let value):
      #expect(value == "SMS")
    default:
      #expect(Bool(false))
    }
  } catch {
    #expect(Bool(false))
  }
}
