import Foundation

/// Errors emitted by ``CommandParser`` when raw arguments cannot be bound to a
/// ``CommandSignature``.
public enum CommanderError: Error, CustomStringConvertible, Sendable, Equatable {
    case unknownOption(String)
    case missingValue(option: String)
    case unexpectedArgument(String)
    case invalidValue(option: String, value: String)

    public var description: String {
        switch self {
        case let .unknownOption(name):
            return "Unknown option \(name)"
        case let .missingValue(option):
            return "Missing value for option \(option)"
        case let .unexpectedArgument(value):
            return "Unexpected argument: \(value)"
        case let .invalidValue(option, value):
            return "Invalid value '\(value)' for option \(option)"
        }
    }
}
