import Foundation
import Testing

@testable import IMsgCore

@Test
func resolverReturnsNilForEmptyInput() {
  let resolver = ContactResolver()
  #expect(resolver.resolve("") == nil)
  #expect(resolver.resolve("   ") == nil)
}

@Test
func resolverReturnsNilForNonPhoneNonEmail() {
  let resolver = ContactResolver()
  // Chat identifiers and opaque IDs should not be looked up
  #expect(resolver.resolve("chat123456789") == nil)
  #expect(resolver.resolve("a36a822c067c4404a04ddeb731dab9b2") == nil)
}

@Test
func batchResolveReturnsEmptyForUnknownNumbers() {
  let resolver = ContactResolver()
  let results = resolver.resolve(["+15550000001", "+15550000002"])
  // These fake numbers won't match any contact
  #expect(results["+15550000001"] == nil)
  #expect(results["+15550000002"] == nil)
}

@Test
func batchResolveReturnsOnlyResolvedEntries() {
  let resolver = ContactResolver()
  let results = resolver.resolve(["+15550000001"])
  // Should not contain entries for unresolved numbers
  #expect(results.isEmpty)
}

@Test
func resolverCachesResults() {
  let resolver = ContactResolver()
  // First call
  let result1 = resolver.resolve("+15550000001")
  // Second call should hit cache (same result)
  let result2 = resolver.resolve("+15550000001")
  #expect(result1 == result2)
}
