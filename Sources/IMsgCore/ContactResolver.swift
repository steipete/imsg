import Contacts
import Foundation

/// Protocol for resolving handles (phone/email) to display names.
public protocol ContactResolving: Sendable {
  func displayName(for handle: String) -> String?
  func searchByName(_ query: String) -> [(name: String, handle: String)]
}

/// Always returns nil. Used when Contacts access is denied or unavailable.
public final class NoOpContactResolver: ContactResolving, Sendable {
  public init() {}
  public func displayName(for handle: String) -> String? { nil }
  public func searchByName(_ query: String) -> [(name: String, handle: String)] { [] }
}

/// Resolves phone numbers and emails to contact names via macOS Contacts framework.
/// Preloads all contacts into memory for fast O(1) lookups.
public final class ContactResolver: ContactResolving, @unchecked Sendable {
  private let phoneToName: [String: String]
  private let emailToName: [String: String]
  private let allContacts: [(name: String, phones: [String], emails: [String])]
  private let normalizer: PhoneNumberNormalizer
  private let region: String

  private init(
    phoneToName: [String: String],
    emailToName: [String: String],
    allContacts: [(name: String, phones: [String], emails: [String])],
    region: String
  ) {
    self.phoneToName = phoneToName
    self.emailToName = emailToName
    self.allContacts = allContacts
    self.normalizer = PhoneNumberNormalizer()
    self.region = region
  }

  /// Creates a ContactResolver, requesting access if needed.
  /// Returns NoOpContactResolver if access is denied.
  public static func create(region: String = "US") async -> any ContactResolving {
    let store = CNContactStore()
    let status = CNContactStore.authorizationStatus(for: .contacts)

    switch status {
    case .authorized, .limited:
      return load(store: store, region: region)
    case .notDetermined:
      do {
        let granted = try await store.requestAccess(for: .contacts)
        if granted {
          return load(store: store, region: region)
        }
      } catch {}
      return NoOpContactResolver()
    default:
      return NoOpContactResolver()
    }
  }

  private static func load(store: CNContactStore, region: String) -> ContactResolver {
    let keysToFetch: [CNKeyDescriptor] = [
      CNContactGivenNameKey as CNKeyDescriptor,
      CNContactFamilyNameKey as CNKeyDescriptor,
      CNContactPhoneNumbersKey as CNKeyDescriptor,
      CNContactEmailAddressesKey as CNKeyDescriptor,
    ]

    let normalizer = PhoneNumberNormalizer()
    var phoneMap: [String: String] = [:]
    var emailMap: [String: String] = [:]
    var contacts: [(name: String, phones: [String], emails: [String])] = []

    let request = CNContactFetchRequest(keysToFetch: keysToFetch)
    do {
      try store.enumerateContacts(with: request) { contact, _ in
        let fullName = [contact.givenName, contact.familyName]
          .filter { !$0.isEmpty }
          .joined(separator: " ")
        guard !fullName.isEmpty else { return }

        var phones: [String] = []
        for phone in contact.phoneNumbers {
          let raw = phone.value.stringValue
          let normalized = normalizer.normalize(raw, region: region)
          phoneMap[normalized] = fullName
          phones.append(normalized)
        }

        var emails: [String] = []
        for email in contact.emailAddresses {
          let addr = (email.value as String).lowercased()
          emailMap[addr] = fullName
          emails.append(addr)
        }

        if !phones.isEmpty || !emails.isEmpty {
          contacts.append((name: fullName, phones: phones, emails: emails))
        }
      }
    } catch {
      return ContactResolver(phoneToName: [:], emailToName: [:], allContacts: [], region: region)
    }

    return ContactResolver(
      phoneToName: phoneMap, emailToName: emailMap, allContacts: contacts, region: region)
  }

  public func displayName(for handle: String) -> String? {
    if handle.contains("@") {
      return emailToName[handle.lowercased()]
    }
    let normalized = normalizer.normalize(handle, region: region)
    return phoneToName[normalized]
  }

  public func searchByName(_ query: String) -> [(name: String, handle: String)] {
    let lower = query.lowercased()
    var results: [(name: String, handle: String)] = []
    for contact in allContacts {
      if contact.name.lowercased().contains(lower) {
        if let phone = contact.phones.first {
          results.append((name: contact.name, handle: phone))
        } else if let email = contact.emails.first {
          results.append((name: contact.name, handle: email))
        }
      }
    }
    return results
  }
}
