import Commander
import Foundation
import IMsgCore

// MARK: - search

enum SearchCommand {
  static let spec = CommandSpec(
    name: "search",
    abstract: "Search messages via the IMCore bridge",
    discussion: """
      Server-side search isn't fully wired in v1; this command currently
      surfaces whatever the bridge returns (note: "not yet implemented")
      and is intended to be the future home of full-fidelity search.
      For now, fall back to `imsg history --json | grep`.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "query", names: [.long("query")], help: "search query (required)"),
          .make(label: "match", names: [.long("match")], help: "exact|contains (default contains)"),
        ]
      )
    ),
    usageExamples: ["imsg search --query 'pizza tonight' --match contains"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let q = values.option("query"), !q.isEmpty else {
      throw ParsedValuesError.missingOption("query")
    }
    let params: [String: Any] = [
      "query": q,
      "matchType": values.option("match") ?? "contains",
    ]
    _ = await BridgeOutput.invokeAndEmit(
      action: .searchMessages, params: params, runtime: runtime
    ) { data in
      let count = (data["results"] as? [[String: Any]])?.count ?? 0
      let note = (data["note"] as? String) ?? ""
      return "search: \(count) result\(count == 1 ? "" : "s")\(note.isEmpty ? "" : " — \(note)")"
    }
  }
}

// MARK: - account

enum AccountCommand {
  static let spec = CommandSpec(
    name: "account",
    abstract: "Show the active iMessage account, login, and aliases",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(CommandSignature(
      options: CommandSignatures.baseOptions()
    )),
    usageExamples: ["imsg account"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    _ = await BridgeOutput.invokeAndEmit(
      action: .getAccountInfo, params: [:], runtime: runtime
    ) { data in
      let login = (data["login"] as? String) ?? ""
      let aliases = (data["vetted_aliases"] as? [String]) ?? []
      return "account: \(login)\n  aliases: \(aliases.joined(separator: ", "))"
    }
  }
}

// MARK: - whois

enum WhoisCommand {
  static let spec = CommandSpec(
    name: "whois",
    abstract: "Check whether a handle is reachable on iMessage",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "address", names: [.long("address")], help: "phone or email to check"),
          .make(label: "type", names: [.long("type")], help: "phone|email"),
        ]
      )
    ),
    usageExamples: [
      "imsg whois --address +15551234567 --type phone",
      "imsg whois --address foo@bar.com --type email",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let addr = values.option("address"), !addr.isEmpty else {
      throw ParsedValuesError.missingOption("address")
    }
    let aliasType = values.option("type") ?? (addr.contains("@") ? "email" : "phone")
    let params: [String: Any] = [
      "address": addr,
      "aliasType": aliasType,
    ]
    _ = await BridgeOutput.invokeAndEmit(
      action: .checkImessageAvailability, params: params, runtime: runtime
    ) { data in
      let avail = (data["available"] as? Bool) ?? false
      let status = (data["id_status"] as? Int) ?? 0
      return "whois \(addr): \(avail ? "available" : "unavailable") (id_status=\(status))"
    }
  }
}

// MARK: - nickname

enum NicknameCommand {
  static let spec = CommandSpec(
    name: "nickname",
    abstract: "Show contact-card / nickname info for a handle",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "address", names: [.long("address")], help: "phone or email"),
        ]
      )
    ),
    usageExamples: ["imsg nickname --address +15551234567"]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let addr = values.option("address"), !addr.isEmpty else {
      throw ParsedValuesError.missingOption("address")
    }
    let params: [String: Any] = ["address": addr]
    _ = await BridgeOutput.invokeAndEmit(
      action: .getNicknameInfo, params: params, runtime: runtime
    ) { data in
      let has = (data["has_nickname"] as? Bool) ?? false
      let desc = (data["description"] as? String) ?? ""
      return "nickname: \(has ? desc : "(none)")"
    }
  }
}
