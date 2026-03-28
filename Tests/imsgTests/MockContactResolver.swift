import Foundation
import IMsgCore

final class MockContactResolver: ContactResolving, Sendable {
  private let names: [String: String]
  private let contacts: [(name: String, handle: String)]

  init(
    names: [String: String] = [:],
    contacts: [(name: String, handle: String)] = []
  ) {
    self.names = names
    self.contacts = contacts
  }

  func displayName(for handle: String) -> String? {
    names[handle]
  }

  func searchByName(_ query: String) -> [(name: String, handle: String)] {
    let lower = query.lowercased()
    return contacts.filter { $0.name.lowercased().contains(lower) }
  }
}
