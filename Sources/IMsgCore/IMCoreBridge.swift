import Foundation

public enum IMCoreBridge {

  // MARK: - Framework Loading

  static func loadFramework() throws -> UnsafeMutableRawPointer {
    let frameworkPath = "/System/Library/PrivateFrameworks/IMCore.framework/IMCore"
    guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
      let error = String(cString: dlerror())
      throw IMsgError.effectSendFailed("Failed to load IMCore framework: \(error)")
    }
    return handle
  }

  // MARK: - Daemon Connection

  static func ensureDaemonConnection() throws {
    guard let controllerClass = objc_getClass("IMDaemonController") as? NSObject.Type else {
      throw IMsgError.effectSendFailed("IMDaemonController class not found")
    }
    let sharedSel = sel_registerName("sharedInstance")
    guard controllerClass.responds(to: sharedSel) else {
      throw IMsgError.effectSendFailed("IMDaemonController.sharedInstance not available")
    }
    guard let controller = controllerClass.perform(sharedSel)?.takeUnretainedValue() else {
      throw IMsgError.effectSendFailed("Failed to get IMDaemonController shared instance")
    }
    let connectSel = sel_registerName("connectToDaemon")
    if controller.responds(to: connectSel) {
      _ = controller.perform(connectSel)
    }
    Thread.sleep(forTimeInterval: 0.5)
  }

  // MARK: - Chat Lookup

  static func lookupChat(identifier: String, handle: String = "") throws -> NSObject {
    guard let registryClass = objc_getClass("IMChatRegistry") as? NSObject.Type else {
      throw IMsgError.effectSendFailed("IMChatRegistry class not found")
    }
    let sharedSel = sel_registerName("sharedInstance")
    guard registryClass.responds(to: sharedSel) else {
      throw IMsgError.effectSendFailed("IMChatRegistry.sharedInstance not available")
    }
    guard let registry = registryClass.perform(sharedSel)?.takeUnretainedValue() as? NSObject
    else {
      throw IMsgError.effectSendFailed("Failed to get IMChatRegistry shared instance")
    }

    // Try GUID-based lookup first
    if !identifier.isEmpty {
      let guidSel = sel_registerName("existingChatWithGUID:")
      if registry.responds(to: guidSel) {
        if let chat = registry.perform(guidSel, with: identifier)?.takeUnretainedValue()
          as? NSObject
        {
          return chat
        }
      }
      let identSel = sel_registerName("existingChatWithChatIdentifier:")
      if registry.responds(to: identSel) {
        if let chat = registry.perform(identSel, with: identifier)?.takeUnretainedValue()
          as? NSObject
        {
          return chat
        }
      }
    }

    // Try handle-based lookup
    if !handle.isEmpty {
      let identSel = sel_registerName("existingChatWithChatIdentifier:")
      if registry.responds(to: identSel) {
        if let chat = registry.perform(identSel, with: handle)?.takeUnretainedValue() as? NSObject {
          return chat
        }
      }
    }

    throw IMsgError.effectSendFailed(
      "Chat not found for identifier=\(identifier) handle=\(handle). "
        + "Make sure Messages.app has an active conversation with this contact.")
  }

  // MARK: - Typing Indicator

  static func setTyping(_ isTyping: Bool, in chat: NSObject) throws {
    let selector = sel_registerName("setLocalUserIsTyping:")
    guard let method = class_getInstanceMethod(object_getClass(chat), selector) else {
      throw IMsgError.typingIndicatorFailed("setLocalUserIsTyping: method not found on IMChat")
    }
    let implementation = method_getImplementation(method)
    typealias SetTypingFunc = @convention(c) (AnyObject, Selector, Bool) -> Void
    let setTypingFunc = unsafeBitCast(implementation, to: SetTypingFunc.self)
    setTypingFunc(chat, selector, isTyping)
  }

  // MARK: - Send Message

  static func sendMessage(_ message: NSObject, in chat: NSObject) throws {
    let selector = sel_registerName("sendMessage:")
    guard let method = class_getInstanceMethod(object_getClass(chat), selector) else {
      throw IMsgError.effectSendFailed("sendMessage: method not found on IMChat")
    }
    let implementation = method_getImplementation(method)
    typealias SendMessageFunc = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    let sendMessageFunc = unsafeBitCast(implementation, to: SendMessageFunc.self)
    sendMessageFunc(chat, selector, message)
  }

  // MARK: - Public API: Send with Effect

  public static func sendMessageWithEffect(
    chatIdentifier: String,
    handle: String,
    text: String,
    effectID: String
  ) throws {
    let handle_ = dlopen(
      "/System/Library/PrivateFrameworks/IMCore.framework/IMCore", RTLD_LAZY)
    guard handle_ != nil else {
      let error = String(cString: dlerror())
      throw IMsgError.effectSendFailed("Failed to load IMCore framework: \(error)")
    }
    defer { dlclose(handle_) }

    try ensureDaemonConnection()
    let chat = try lookupChat(identifier: chatIdentifier, handle: handle)

    guard let messageClass = objc_getClass("IMMessage") as? NSObject.Type else {
      throw IMsgError.effectSendFailed("IMMessage class not found")
    }

    let msg = messageClass.init()
    let attributedText = NSAttributedString(string: text)
    msg.setValue(attributedText, forKey: "text")
    msg.setValue(NSArray(), forKey: "fileTransferGUIDs")
    msg.setValue(NSNumber(value: 100005), forKey: "flags")
    msg.setValue(effectID, forKey: "expressiveSendStyleID")

    try sendMessage(msg, in: chat)
  }
}
