import Foundation
import PhoneNumberKit

public final class PhoneNumberNormalizer {
  private let phoneNumberUtility = PhoneNumberUtility()

  public init() {}

  public func normalize(_ input: String, region: String) -> String {
    do {
      let number = try phoneNumberUtility.parse(input, withRegion: region, ignoreType: true)
      return phoneNumberUtility.format(number, toType: .e164)
    } catch {
      return input
    }
  }
}
