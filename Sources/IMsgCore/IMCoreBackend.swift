import Darwin
import Foundation
import ObjectiveC

enum IMCoreBackend {
  private static let allowEnvKey = "IMSG_ALLOW_PRIVATE"
  private static let replyAssociatedMessageType = 1000
  private static func msgSendPtr() -> UnsafeMutableRawPointer? {
    let handle = dlopen(nil, RTLD_LAZY)
    return dlsym(handle, "objc_msgSend")
  }

  static func send(_ options: MessageSendOptions) throws {
    guard isPrivateAllowed() else {
      throw IMsgError.privateApiFailure("Set \(allowEnvKey)=1 to enable IMCore mode.")
    }
    if !options.attachmentPath.isEmpty {
      throw IMsgError.privateApiFailure("IMCore send does not support attachments yet.")
    }
    try loadFrameworks()
    guard let registry = chatRegistry() else {
      throw IMsgError.privateApiFailure("Unable to load IMChatRegistry.")
    }

    let chat: AnyObject?
    let chatTarget = options.chatIdentifier.isEmpty ? options.chatGUID : options.chatIdentifier
    if !chatTarget.isEmpty {
      chat = callObject(registry, "existingChatWithIdentifier:", chatTarget as NSString)
        ?? callObject(registry, "existingChatWithGUID:", chatTarget as NSString)
        ?? callObject(registry, "chatWithHandle:", chatTarget as NSString)
    } else {
      guard let handle = makeHandle(recipient: options.recipient) else {
        throw IMsgError.privateApiFailure("Unable to resolve IMHandle for recipient.")
      }
      chat = callObject(registry, "existingChatWithHandle:", handle)
        ?? callObject(registry, "chatWithHandle:", handle)
    }
    guard let chat else {
      throw IMsgError.privateApiFailure("Unable to resolve IMChat for target.")
    }

    guard let message = buildMessage(options: options) else {
      throw IMsgError.privateApiFailure("Unable to construct IMMessage.")
    }

    let sendSel = Selector(("_sendMessage:adjustingSender:shouldQueue:"))
    if chat.responds(to: sendSel) {
      callVoid(chat, sendSel, message, true, true)
      return
    }

    let fallbackSel = Selector(("_sendMessage:withAccount:adjustingSender:shouldQueue:"))
    if chat.responds(to: fallbackSel) {
      let account = callObject(chat, "account")
      callVoid(chat, fallbackSel, message, account, true, true)
      return
    }

    throw IMsgError.privateApiFailure("IMChat send selector unavailable.")
  }

  private static func buildMessage(options: MessageSendOptions) -> AnyObject? {
    guard let clsType = NSClassFromString("IMMessage") else { return nil }
    guard let allocFn: ObjcMsgSendId = msgSend(ObjcMsgSendId.self) else { return nil }
    let allocSel = Selector(("alloc"))
    guard let allocated = allocFn(clsType, allocSel) else { return nil }
    var message: AnyObject = allocated

    let sel = Selector(
      (
        "initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:" +
          "associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:threadIdentifier:"
      )
    )
    let time = NSDate()
    let text = NSAttributedString(string: options.text)
    let messageSubject: NSAttributedString? = nil
    let fileTransfers: NSArray = []
    let error: NSError? = nil
    let guid: NSString? = UUID().uuidString as NSString
    let subject: AnyObject? = nil
    let associatedMessageGUID: NSString? = options.replyToGUID.isEmpty ? nil : options.replyToGUID as NSString
    let associatedMessageType: Int64 = options.replyToGUID.isEmpty ? 0 : Int64(replyAssociatedMessageType)
    let associatedMessageRange = NSRange(location: 0, length: 0)
    let messageSummaryInfo: NSDictionary? = nil
    let threadIdentifier: NSString? = nil

    guard message.responds(to: sel) else { return nil }
    guard let initFn: ObjcMsgSendInitAssociated = msgSend(ObjcMsgSendInitAssociated.self) else {
      return nil
    }
    if let created = initFn(
      message,
      sel,
      nil,
      time,
      text,
      messageSubject,
      fileTransfers,
      0,
      error,
      guid,
      subject,
      associatedMessageGUID,
      associatedMessageType,
      associatedMessageRange,
      messageSummaryInfo,
      threadIdentifier
    ) {
      message = created
    } else {
      return nil
    }

    message.setValue(options.text as NSString, forKey: "plainBody")
    return message
  }

  private static func isPrivateAllowed() -> Bool {
    return ProcessInfo.processInfo.environment[allowEnvKey] == "1"
  }

  private static func loadFrameworks() throws {
    let frameworks = [
      "/System/Library/PrivateFrameworks/IMCore.framework/IMCore",
      "/System/Library/PrivateFrameworks/IMFoundation.framework/IMFoundation",
      "/System/Library/PrivateFrameworks/IMDaemonCore.framework/IMDaemonCore",
      "/System/Library/PrivateFrameworks/IMSharedUtilities.framework/IMSharedUtilities",
    ]
    for path in frameworks {
      if dlopen(path, RTLD_LAZY) == nil {
        if let err = dlerror() {
          throw IMsgError.privateApiFailure(
            "dlopen failed for \(path): \(String(cString: err))")
        }
        throw IMsgError.privateApiFailure("dlopen failed for \(path)")
      }
    }
  }

  private static func chatRegistry() -> AnyObject? {
    guard let cls = NSClassFromString("IMChatRegistry") as AnyObject? else { return nil }
    return callObject(cls, "sharedInstance")
      ?? callObject(cls, "sharedRegistry")
      ?? callObject(cls, "sharedRegistryIfAvailable")
  }

  private static func makeHandle(recipient: String) -> AnyObject? {
    guard let handleClass = NSClassFromString("IMHandle") as AnyObject? else { return nil }
    guard let allocFn: ObjcMsgSendId = msgSend(ObjcMsgSendId.self) else { return nil }
    guard let allocated = allocFn(handleClass, Selector(("alloc"))) else { return nil }
    let selector = Selector(("initWithAccount:ID:alreadyCanonical:"))
    guard allocated.responds(to: selector) else { return nil }
    guard let initFn: ObjcMsgSendInitHandle = msgSend(ObjcMsgSendInitHandle.self) else {
      return nil
    }
    let account = iMessageAccount()
    return initFn(allocated, selector, account, recipient as NSString, false)
  }

  private static func iMessageAccount() -> AnyObject? {
    guard let controllerClass = NSClassFromString("IMAccountController") as AnyObject? else {
      return nil
    }
    guard let controller = callObject(controllerClass, "sharedInstance") else { return nil }
    guard let serviceClass = NSClassFromString("IMService") as AnyObject? else {
      return callObject(controller, "activeIMessageAccount")
    }
    let service = callObject(serviceClass, "iMessageService")
    if let service {
      if let account = callObject(controller, "bestOperationalAccountForService:", service) {
        return account
      }
      if let account = callObject(controller, "bestActiveAccountForService:", service) {
        return account
      }
    }
    return callObject(controller, "activeIMessageAccount")
  }

  private static func callObject(
    _ target: AnyObject,
    _ selectorName: String,
    _ arg: AnyObject? = nil
  ) -> AnyObject? {
    let selector = Selector(selectorName)
    guard target.responds(to: selector) else { return nil }
    guard let fn: ObjcMsgSendIdObj = msgSend(ObjcMsgSendIdObj.self) else { return nil }
    return fn(target, selector, arg)
  }

  private static func callVoid(
    _ target: AnyObject,
    _ selector: Selector,
    _ message: AnyObject,
    _ adjustingSender: Bool,
    _ shouldQueue: Bool
  ) {
    guard let fn: ObjcMsgSendVoid = msgSend(ObjcMsgSendVoid.self) else { return }
    fn(target, selector, message, adjustingSender, shouldQueue)
  }

  private static func callVoid(
    _ target: AnyObject,
    _ selector: Selector,
    _ message: AnyObject,
    _ account: AnyObject?,
    _ adjustingSender: Bool,
    _ shouldQueue: Bool
  ) {
    guard let fn: ObjcMsgSendVoidAccount = msgSend(ObjcMsgSendVoidAccount.self) else { return }
    fn(target, selector, message, account, adjustingSender, shouldQueue)
  }

  private static func msgSend<T>(_ type: T.Type) -> T? {
    guard let ptr = msgSendPtr() else { return nil }
    return unsafeBitCast(ptr, to: type)
  }
}

private typealias ObjcMsgSendId = @convention(c) (AnyObject, Selector) -> AnyObject?
private typealias ObjcMsgSendIdObj = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
private typealias ObjcMsgSendVoid = @convention(c) (AnyObject, Selector, AnyObject, Bool, Bool) -> Void
private typealias ObjcMsgSendVoidAccount =
  @convention(c) (AnyObject, Selector, AnyObject, AnyObject?, Bool, Bool) -> Void
private typealias ObjcMsgSendInitHandle =
  @convention(c) (AnyObject, Selector, AnyObject?, NSString, Bool) -> AnyObject?
private typealias ObjcMsgSendInitAssociated =
  @convention(c)
    (
      AnyObject,
      Selector,
      AnyObject?,
      NSDate,
      NSAttributedString?,
      NSAttributedString?,
      NSArray,
      UInt64,
      NSError?,
      NSString?,
      AnyObject?,
      NSString?,
      Int64,
      NSRange,
      NSDictionary?,
      NSString?
    ) -> AnyObject?
