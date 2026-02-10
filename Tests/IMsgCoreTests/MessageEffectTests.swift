import Testing

@testable import IMsgCore

@Test
func allFriendlyNamesResolveToCorrectEffectIDs() {
  let expected: [(String, String)] = [
    ("slam", "com.apple.MobileSMS.expressivesend.impact"),
    ("loud", "com.apple.MobileSMS.expressivesend.loud"),
    ("gentle", "com.apple.MobileSMS.expressivesend.gentle"),
    ("invisibleink", "com.apple.MobileSMS.expressivesend.invisibleink"),
    ("confetti", "com.apple.messages.effect.CKConfettiEffect"),
    ("echo", "com.apple.messages.effect.CKEchoEffect"),
    ("fireworks", "com.apple.messages.effect.CKFireworksEffect"),
    ("birthday", "com.apple.messages.effect.CKHappyBirthdayEffect"),
    ("love", "com.apple.messages.effect.CKHeartEffect"),
    ("lasers", "com.apple.messages.effect.CKLasersEffect"),
    ("shootingstar", "com.apple.messages.effect.CKShootingStarEffect"),
    ("sparkles", "com.apple.messages.effect.CKSparklesEffect"),
    ("spotlight", "com.apple.messages.effect.CKSpotlightEffect"),
  ]

  for (name, expectedID) in expected {
    let effect = MessageEffect(name: name)
    #expect(effect != nil, "Effect '\(name)' should be valid")
    #expect(effect?.effectID == expectedID, "Effect '\(name)' should map to '\(expectedID)'")
  }
}

@Test
func unknownNameReturnsNil() {
  #expect(MessageEffect(name: "unknown") == nil)
  #expect(MessageEffect(name: "") == nil)
  #expect(MessageEffect(name: "SLAM ") == nil)
}

@Test
func allNamesContainsAllCases() {
  let names = MessageEffect.allNames
  #expect(names.count == MessageEffect.allCases.count)
  for effect in MessageEffect.allCases {
    #expect(names.contains(effect.rawValue))
  }
}

@Test
func initIsCaseInsensitive() {
  #expect(MessageEffect(name: "Slam") != nil)
  #expect(MessageEffect(name: "FIREWORKS") != nil)
  #expect(MessageEffect(name: "Love") != nil)
}
