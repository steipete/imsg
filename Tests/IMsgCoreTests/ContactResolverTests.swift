import Foundation
import Testing

@testable import IMsgCore

@Test
func noOpResolverReturnsNil() {
  let resolver = NoOpContactResolver()
  #expect(resolver.displayName(for: "+15551234567") == nil)
  #expect(resolver.displayName(for: "test@example.com") == nil)
  #expect(resolver.searchByName("John").isEmpty)
}
