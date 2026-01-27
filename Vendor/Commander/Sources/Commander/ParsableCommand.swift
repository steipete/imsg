import Foundation

/// Declarative metadata describing a command built with ``ParsableCommand``.
public struct CommandUsageExample: Sendable {
    public var command: String
    public var description: String

    public init(command: String, description: String) {
        self.command = command
        self.description = description
    }
}

public struct CommandDescription: Sendable {
    public var commandName: String?
    public var abstract: String
    public var discussion: String?
    public var version: String?
    public var subcommands: [any ParsableCommand.Type]
    public var defaultSubcommand: (any ParsableCommand.Type)?
    public var usageExamples: [CommandUsageExample]
    public var showHelpOnEmptyInvocation: Bool

    public init(
        commandName: String? = nil,
        abstract: String = "",
        discussion: String? = nil,
        version: String? = nil,
        subcommands: [any ParsableCommand.Type] = [],
        defaultSubcommand: (any ParsableCommand.Type)? = nil,
        usageExamples: [CommandUsageExample] = [],
        showHelpOnEmptyInvocation: Bool = false)
    {
        self.commandName = commandName
        self.abstract = abstract
        self.discussion = discussion
        self.version = version
        self.subcommands = subcommands
        self.defaultSubcommand = defaultSubcommand
        self.usageExamples = usageExamples
        self.showHelpOnEmptyInvocation = showHelpOnEmptyInvocation
    }
}

/// Helper for building ``CommandDescription`` values while staying on the main
/// actor (useful when you need to query `@MainActor` state).
@MainActor
public enum MainActorCommandDescription {
    public nonisolated static func describe(_ build: () -> CommandDescription) -> CommandDescription {
        build()
    }
}

/// Protocol every Commander command adopts. Provide metadata via
/// ``commandDescription`` and implement ``run()`` to perform the command's
/// work.
@MainActor
public protocol ParsableCommand: Sendable {
    init()
    static var commandDescription: CommandDescription { get }
    mutating func run() async throws
}

extension ParsableCommand {
    public static var commandDescription: CommandDescription {
        CommandDescription()
    }

    public mutating func run() async throws {}
}

/// Thrown from ``ParsableCommand/run()`` when user input fails validation.
public struct ValidationError: Error, LocalizedError, CustomStringConvertible, Sendable {
    private let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { self.message }
    public var description: String { self.message }
}

/// Exit sentinel understood by Peekaboo's CLI harness.
public struct ExitCode: Error, Equatable, CustomStringConvertible, Sendable {
    public let rawValue: Int32

    public init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let success = ExitCode(0)
    public static let failure = ExitCode(1)

    public var description: String { "ExitCode(\(self.rawValue))" }
}
