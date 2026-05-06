import Commander
import Foundation
import IMsgCore

/// Helpers shared by all bridge-backed commands.
enum BridgeOutput {
  struct EmittedError: Error {}

  static func emit(_ data: [String: Any], runtime: RuntimeOptions, summary: String) {
    if runtime.jsonOutput {
      try? JSONLines.printObject(data)
    } else {
      StdoutWriter.writeLine(summary)
    }
  }

  static func emitError(_ message: String, runtime: RuntimeOptions) {
    if runtime.jsonOutput {
      try? JSONLines.printObject(["success": false, "error": message])
    } else {
      StdoutWriter.writeLine("error: \(message)")
    }
  }

  /// Invoke a bridge action and emit the result. Returns the data dict on
  /// success or nil on failure (after emitting an error message).
  static func invokeAndEmit(
    action: BridgeAction,
    params: [String: Any],
    runtime: RuntimeOptions,
    summary: (([String: Any]) -> String)
  ) async throws -> [String: Any] {
    do {
      let data = try await IMsgBridgeClient.shared.invoke(action: action, params: params)
      emit(data, runtime: runtime, summary: summary(data))
      return data
    } catch {
      emitError(String(describing: error), runtime: runtime)
      throw EmittedError()
    }
  }
}

// MARK: - send-rich

enum SendRichCommand {
  static let spec = CommandSpec(
    name: "send-rich",
    abstract: "Send a message via the IMCore bridge (effects, replies, subjects)",
    discussion: """
      Requires `imsg launch` (SIP-disabled, dylib injected). Unlike `imsg send`
      which uses AppleScript, this routes through Messages' private API for
      richer features: expressive-send effects, reply targets, subject lines.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(
            label: "chat", names: [.long("chat")], help: "chat guid (e.g. iMessage;-;+15551234567)"),
          .make(label: "text", names: [.long("text")], help: "message body"),
          .make(
            label: "effect", names: [.long("effect")],
            help: "expressive send id (impact, loud, gentle, invisibleink, confetti, …)"),
          .make(label: "subject", names: [.long("subject")], help: "subject line"),
          .make(label: "replyTo", names: [.long("reply-to")], help: "guid of message to reply to"),
          .make(label: "part", names: [.long("part")], help: "part index (default 0)"),
          .make(
            label: "format",
            names: [.long("format")],
            help: "JSON array of {start,length,styles:[...]} ranges (macOS 15+)"),
          .make(
            label: "formatFile", names: [.long("format-file")],
            help: "path to JSON file containing the format ranges array"),
        ],
        flags: [
          .make(
            label: "noDDScan", names: [.long("no-dd-scan")],
            help: "disable data-detector scan deferral")
        ]
      )
    ),
    usageExamples: [
      "imsg send-rich --chat 'iMessage;-;+15551234567' --text 'hi'",
      "imsg send-rich --chat 'iMessage;-;+15551234567' --text 'BOOM' --effect com.apple.MobileSMS.expressivesend.impact",
      "imsg send-rich --chat ... --text 'hello world' --format '[{\"start\":0,\"length\":5,\"styles\":[\"bold\"]}]'",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    let text = values.option("text") ?? ""
    var params: [String: Any] = [
      "chatGuid": chat,
      "message": text,
      "partIndex": Int(values.option("part") ?? "0") ?? 0,
      "ddScan": !values.flag("noDDScan"),
    ]
    if let effect = values.option("effect"), !effect.isEmpty { params["effectId"] = effect }
    if let subject = values.option("subject"), !subject.isEmpty { params["subject"] = subject }
    if let reply = values.option("replyTo"), !reply.isEmpty {
      params["selectedMessageGuid"] = reply
    }

    // Optional text formatting (macOS 15+ — Sequoia and later). Pass either
    // inline JSON via --format or a file path via --format-file. Format:
    //   [{"start":0,"length":5,"styles":["bold","italic"]}, ...]
    let formatRaw: String?
    if let inline = values.option("format"), !inline.isEmpty {
      formatRaw = inline
    } else if let path = values.option("formatFile"), !path.isEmpty {
      formatRaw = try String(contentsOfFile: path, encoding: .utf8)
    } else {
      formatRaw = nil
    }
    if let raw = formatRaw {
      guard
        let bytes = raw.data(using: .utf8),
        let ranges = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]]
      else {
        throw ParsedValuesError.invalidOption("format")
      }
      params["textFormatting"] = ranges
    }

    _ = try await BridgeOutput.invokeAndEmit(
      action: .sendMessage, params: params, runtime: runtime
    ) { data in
      let guid = (data["messageGuid"] as? String) ?? ""
      return guid.isEmpty ? "send-rich: queued" : "send-rich: sent (guid=\(guid))"
    }
  }
}

// MARK: - send-multipart

enum SendMultipartCommand {
  static let spec = CommandSpec(
    name: "send-multipart",
    abstract: "Send a multi-part message",
    discussion: """
      Pass --parts as a JSON array (e.g., '[{"text":"hi"},{"text":"there"}]')
      or via --parts-file pointing at a .json file. v1 supports text-only
      parts; mention/file parts are a future enhancement.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "parts", names: [.long("parts")], help: "JSON array of parts"),
          .make(
            label: "partsFile", names: [.long("parts-file")],
            help: "path to JSON file containing parts array"),
          .make(label: "effect", names: [.long("effect")], help: "expressive send id"),
          .make(label: "subject", names: [.long("subject")], help: "subject line"),
        ]
      )
    ),
    usageExamples: [
      "imsg send-multipart --chat 'iMessage;+;chat0000' --parts '[{\"text\":\"hi\"},{\"text\":\"world\"}]'"
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    let partsRaw: String
    if let inline = values.option("parts"), !inline.isEmpty {
      partsRaw = inline
    } else if let path = values.option("partsFile"), !path.isEmpty {
      partsRaw = try String(contentsOfFile: path, encoding: .utf8)
    } else {
      throw ParsedValuesError.missingOption("parts")
    }
    guard
      let data = partsRaw.data(using: .utf8),
      let parts = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
      throw ParsedValuesError.invalidOption("parts")
    }
    var params: [String: Any] = ["chatGuid": chat, "parts": parts]
    if let effect = values.option("effect"), !effect.isEmpty { params["effectId"] = effect }
    if let subject = values.option("subject"), !subject.isEmpty { params["subject"] = subject }

    _ = try await BridgeOutput.invokeAndEmit(
      action: .sendMultipart, params: params, runtime: runtime
    ) { data in
      let guid = (data["messageGuid"] as? String) ?? ""
      let count = (data["parts_count"] as? Int) ?? 0
      return "send-multipart: \(count) parts queued (guid=\(guid))"
    }
  }
}

// MARK: - send-attachment

enum SendAttachmentCommand {
  static let spec = CommandSpec(
    name: "send-attachment",
    abstract: "Send a file attachment via the IMCore bridge",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "file", names: [.long("file")], help: "absolute path to file"),
        ],
        flags: [
          .make(label: "audio", names: [.long("audio")], help: "send as audio message")
        ]
      )
    ),
    usageExamples: [
      "imsg send-attachment --chat 'iMessage;-;+15551234567' --file ~/Pictures/me.jpg"
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let file = values.option("file"), !file.isEmpty else {
      throw ParsedValuesError.missingOption("file")
    }
    let expanded = (file as NSString).expandingTildeInPath
    let params: [String: Any] = [
      "chatGuid": chat,
      "filePath": expanded,
      "isAudioMessage": values.flag("audio"),
    ]
    _ = try await BridgeOutput.invokeAndEmit(
      action: .sendAttachment, params: params, runtime: runtime
    ) { data in
      let guid = (data["messageGuid"] as? String) ?? ""
      return "send-attachment: queued (guid=\(guid))"
    }
  }
}

// MARK: - react (BB-style; complements existing AS-backed `react`)

enum BridgeReactCommand {
  static let spec = CommandSpec(
    name: "tapback",
    abstract: "Send a tapback reaction via the IMCore bridge",
    discussion: """
      `imsg tapback` uses the bridge for reliability across macOS versions.
      `imsg react` (AppleScript) remains for SIP-on machines.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "message", names: [.long("message")], help: "target message guid"),
          .make(
            label: "kind", names: [.long("kind")],
            help: "love|like|dislike|laugh|emphasize|question"),
          .make(label: "part", names: [.long("part")], help: "part index"),
        ],
        flags: [
          .make(
            label: "remove", names: [.long("remove")],
            help: "remove this reaction instead of adding")
        ]
      )
    ),
    usageExamples: [
      "imsg tapback --chat 'iMessage;-;+15551234567' --message ABCD-EFGH --kind love"
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let message = values.option("message"), !message.isEmpty else {
      throw ParsedValuesError.missingOption("message")
    }
    guard let kind = values.option("kind"), !kind.isEmpty else {
      throw ParsedValuesError.missingOption("kind")
    }
    let normalized = kind.lowercased()
    let prefixed = values.flag("remove") ? "remove-\(normalized)" : normalized
    let params: [String: Any] = [
      "chatGuid": chat,
      "selectedMessageGuid": message,
      "reactionType": prefixed,
      "partIndex": Int(values.option("part") ?? "0") ?? 0,
    ]
    _ = try await BridgeOutput.invokeAndEmit(
      action: .sendReaction, params: params, runtime: runtime
    ) { _ in "tapback: \(prefixed) sent" }
  }
}

// MARK: - edit

enum EditCommand {
  static let spec = CommandSpec(
    name: "edit",
    abstract: "Edit a sent message",
    discussion: "Requires macOS 13+ (selector-probed at startup).",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "message", names: [.long("message")], help: "target message guid"),
          .make(label: "newText", names: [.long("new-text")], help: "replacement text"),
          .make(
            label: "bcText",
            names: [.long("bc-text")],
            help: "backwards-compat text shown to older clients (default: same as new-text)"),
          .make(label: "part", names: [.long("part")], help: "part index"),
        ]
      )
    ),
    usageExamples: ["imsg edit --chat ... --message <guid> --new-text 'updated'"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let message = values.option("message"), !message.isEmpty else {
      throw ParsedValuesError.missingOption("message")
    }
    guard let newText = values.option("newText"), !newText.isEmpty else {
      throw ParsedValuesError.missingOption("new-text")
    }
    let params: [String: Any] = [
      "chatGuid": chat,
      "messageGuid": message,
      "editedMessage": newText,
      "backwardsCompatibilityMessage": values.option("bcText") ?? newText,
      "partIndex": Int(values.option("part") ?? "0") ?? 0,
    ]
    _ = try await BridgeOutput.invokeAndEmit(
      action: .editMessage, params: params, runtime: runtime
    ) { _ in "edit: queued" }
  }
}

// MARK: - unsend

enum UnsendCommand {
  static let spec = CommandSpec(
    name: "unsend",
    abstract: "Retract a sent message",
    discussion: "Requires macOS 13+ (selector-probed at startup).",
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "message", names: [.long("message")], help: "target message guid"),
          .make(label: "part", names: [.long("part")], help: "part index"),
        ]
      )
    ),
    usageExamples: ["imsg unsend --chat ... --message <guid>"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let message = values.option("message"), !message.isEmpty else {
      throw ParsedValuesError.missingOption("message")
    }
    let params: [String: Any] = [
      "chatGuid": chat,
      "messageGuid": message,
      "partIndex": Int(values.option("part") ?? "0") ?? 0,
    ]
    _ = try await BridgeOutput.invokeAndEmit(
      action: .unsendMessage, params: params, runtime: runtime
    ) { _ in "unsend: queued" }
  }
}

// MARK: - delete-message

enum DeleteMessageCommand {
  static let spec = CommandSpec(
    name: "delete-message",
    abstract: "Delete a single message from a chat",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "message", names: [.long("message")], help: "target message guid"),
        ]
      )
    ),
    usageExamples: ["imsg delete-message --chat ... --message <guid>"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let message = values.option("message"), !message.isEmpty else {
      throw ParsedValuesError.missingOption("message")
    }
    let params: [String: Any] = [
      "chatGuid": chat,
      "messageGuid": message,
    ]
    _ = try await BridgeOutput.invokeAndEmit(
      action: .deleteMessage, params: params, runtime: runtime
    ) { _ in "delete-message: queued" }
  }
}

// MARK: - notify-anyways

enum NotifyAnywaysCommand {
  static let spec = CommandSpec(
    name: "notify-anyways",
    abstract: "Force a notification for a message that was filtered/suppressed",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "message", names: [.long("message")], help: "target message guid"),
        ]
      )
    ),
    usageExamples: ["imsg notify-anyways --chat ... --message <guid>"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    guard let message = values.option("message"), !message.isEmpty else {
      throw ParsedValuesError.missingOption("message")
    }
    let params: [String: Any] = ["chatGuid": chat, "messageGuid": message]
    _ = try await BridgeOutput.invokeAndEmit(
      action: .notifyAnyways, params: params, runtime: runtime
    ) { _ in "notify-anyways: queued" }
  }
}
