import Foundation

public enum MessageEffect: String, Sendable, CaseIterable {
  // Bubble effects
  case slam
  case loud
  case gentle
  case invisibleink

  // Screen effects
  case confetti
  case echo
  case fireworks
  case birthday
  case love
  case lasers
  case shootingstar
  case sparkles
  case spotlight

  public init?(name: String) {
    self.init(rawValue: name.lowercased())
  }

  public var effectID: String {
    switch self {
    case .slam: return "com.apple.MobileSMS.expressivesend.impact"
    case .loud: return "com.apple.MobileSMS.expressivesend.loud"
    case .gentle: return "com.apple.MobileSMS.expressivesend.gentle"
    case .invisibleink: return "com.apple.MobileSMS.expressivesend.invisibleink"
    case .confetti: return "com.apple.messages.effect.CKConfettiEffect"
    case .echo: return "com.apple.messages.effect.CKEchoEffect"
    case .fireworks: return "com.apple.messages.effect.CKFireworksEffect"
    case .birthday: return "com.apple.messages.effect.CKHappyBirthdayEffect"
    case .love: return "com.apple.messages.effect.CKHeartEffect"
    case .lasers: return "com.apple.messages.effect.CKLasersEffect"
    case .shootingstar: return "com.apple.messages.effect.CKShootingStarEffect"
    case .sparkles: return "com.apple.messages.effect.CKSparklesEffect"
    case .spotlight: return "com.apple.messages.effect.CKSpotlightEffect"
    }
  }

  public static var allNames: [String] {
    allCases.map { $0.rawValue }
  }
}
