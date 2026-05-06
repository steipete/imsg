//
//  IMsgInjected.m
//  IMsgHelper - Injectable dylib for Messages.app
//
//  This dylib is injected into Messages.app via DYLD_INSERT_LIBRARIES
//  to gain access to IMCore's chat registry and messaging functions.
//  It provides file-based IPC for the CLI to send commands.
//
//  Requires SIP disabled for DYLD_INSERT_LIBRARIES to work on system apps.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <unistd.h>
#import <stdio.h>
#import <sys/stat.h>

#pragma mark - Constants

// v1 (legacy) single-file IPC paths.
static NSString *kCommandFile = nil;
static NSString *kResponseFile = nil;
static NSString *kLockFile = nil;

// v2 queue-directory IPC paths.
static NSString *kRpcDir = nil;       // .imsg-rpc/
static NSString *kRpcInDir = nil;     // .imsg-rpc/in/
static NSString *kRpcOutDir = nil;    // .imsg-rpc/out/
static NSString *kEventsFile = nil;   // .imsg-events.jsonl
static NSString *kEventsRotated = nil;// .imsg-events.jsonl.1

static NSTimer *fileWatchTimer = nil;
static NSTimer *rpcInboxTimer = nil;
static NSMutableSet *processedRpcIds = nil;
static os_unfair_lock eventsLock = OS_UNFAIR_LOCK_INIT;
static int lockFd = -1;

static const NSUInteger kEventsRotateBytes = 1 * 1024 * 1024;

static void initFilePaths(void) {
    if (kCommandFile == nil) {
        // Messages.app runs in a container; NSHomeDirectory() resolves to
        // ~/Library/Containers/com.apple.MobileSMS/Data inside the sandbox.
        NSString *containerPath = NSHomeDirectory();
        kCommandFile = [containerPath stringByAppendingPathComponent:@".imsg-command.json"];
        kResponseFile = [containerPath stringByAppendingPathComponent:@".imsg-response.json"];
        kLockFile = [containerPath stringByAppendingPathComponent:@".imsg-bridge-ready"];
        kRpcDir = [containerPath stringByAppendingPathComponent:@".imsg-rpc"];
        kRpcInDir = [kRpcDir stringByAppendingPathComponent:@"in"];
        kRpcOutDir = [kRpcDir stringByAppendingPathComponent:@"out"];
        kEventsFile = [containerPath stringByAppendingPathComponent:@".imsg-events.jsonl"];
        kEventsRotated = [containerPath stringByAppendingPathComponent:@".imsg-events.jsonl.1"];
    }
    if (processedRpcIds == nil) {
        processedRpcIds = [NSMutableSet set];
    }
}

#pragma mark - Selector Probes

// Populated at startup by probeSelectors(). Surfaced via the `status` action so
// the CLI can report which IMCore selectors are present on the running macOS
// (edit/unsend names changed across 13/14/15).
static BOOL gHasEditMessageItem = NO;        // editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:
static BOOL gHasEditMessage = NO;            // editMessage:atPartIndex:withNewPartText:backwardCompatabilityText:
static BOOL gHasRetractMessagePart = NO;     // retractMessagePart:
static BOOL gHasSendMessageReason = NO;      // sendMessage:reason:

static void probeSelectors(void) {
    Class chatClass = NSClassFromString(@"IMChat");
    if (!chatClass) return;
    gHasEditMessageItem = [chatClass instancesRespondToSelector:
        @selector(editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:)];
    gHasEditMessage = [chatClass instancesRespondToSelector:
        @selector(editMessage:atPartIndex:withNewPartText:backwardCompatabilityText:)];
    gHasRetractMessagePart = [chatClass instancesRespondToSelector:
        @selector(retractMessagePart:)];
    gHasSendMessageReason = [chatClass instancesRespondToSelector:
        @selector(sendMessage:reason:)];
    NSLog(@"[imsg-bridge] Selector probes: editItem=%d editLegacy=%d retract=%d sendReason=%d",
          gHasEditMessageItem, gHasEditMessage, gHasRetractMessagePart, gHasSendMessageReason);
}

#pragma mark - Forward Declarations for IMCore Classes

@interface IMHandle : NSObject
- (NSString *)ID;
- (NSString *)serviceName;
@end

@interface IMAccount : NSObject
- (NSArray *)vettedAliases;
- (id)loginIMHandle;
- (NSString *)serviceName;
- (BOOL)isActive;
@end

@interface IMAccountController : NSObject
+ (instancetype)sharedInstance;
- (IMAccount *)activeIMessageAccount;
- (NSArray *)activeAccounts;
@end

@interface IMHandleRegistrar : NSObject
+ (instancetype)sharedInstance;
- (id)IMHandleWithID:(NSString *)handleID;
@end

@interface IMChatRegistry : NSObject
+ (instancetype)sharedInstance;
- (id)existingChatWithGUID:(NSString *)guid;
- (id)existingChatWithChatIdentifier:(NSString *)identifier;
- (NSArray *)allExistingChats;
- (id)chatForIMHandle:(id)handle;
- (id)chatForIMHandles:(NSArray *)handles;
@end

@interface IMChat : NSObject
- (void)setLocalUserIsTyping:(BOOL)typing;
- (void)markAllMessagesAsRead;
- (NSArray *)participants;
- (NSString *)guid;
- (NSString *)chatIdentifier;
- (NSString *)displayName;
- (id)lastMessage;
- (id)lastSentMessage;
- (id)account;
- (NSString *)displayNameForChat;
- (void)sendMessage:(id)message;
- (void)leaveChat;
- (void)setDisplayName:(NSString *)name;
- (void)setUnreadCount:(NSInteger)count;
- (BOOL)hasUnreadMessages;
- (NSArray *)chatItems;
@end

@interface IMMessage : NSObject
- (NSString *)guid;
- (id)sender;
- (NSDate *)time;
- (NSAttributedString *)text;
- (NSAttributedString *)subject;
- (NSArray *)fileTransferGUIDs;
@end

@interface IMMessageItem : NSObject
- (NSString *)guid;
- (NSArray *)_newChatItems;
- (id)message;
@end

@interface IMMessagePartChatItem : NSObject
- (NSInteger)index;
- (NSAttributedString *)text;
- (NSRange)messagePartRange;
@end

@interface IMAggregateAttachmentMessagePartChatItem : NSObject
- (NSArray *)aggregateAttachmentParts;
@end

@interface IMFileTransfer : NSObject
- (NSString *)guid;
- (NSString *)localPath;
- (NSString *)transferState;
@end

@interface IMFileTransferCenter : NSObject
+ (instancetype)sharedInstance;
- (IMFileTransfer *)guidForNewOutgoingTransferWithLocalURL:(NSURL *)url;
- (IMFileTransfer *)transferForGUID:(NSString *)guid;
@end

@interface IMChatHistoryController : NSObject
+ (instancetype)sharedInstance;
- (void)loadedChatItemsForChat:(IMChat *)chat
                    beforeDate:(NSDate *)date
                         limit:(NSUInteger)limit
                  loadIfNeeded:(BOOL)load;
@end

@interface IMNicknameController : NSObject
+ (instancetype)sharedController;
- (id)nicknameForHandle:(NSString *)handle;
@end

@interface IDSIDQueryController : NSObject
+ (instancetype)sharedController;
- (id)currentIDStatusForDestination:(NSString *)destination service:(id)service;
@end

#pragma mark - JSON Response Helpers

static NSDictionary* successResponse(NSInteger requestId, NSDictionary *data) {
    NSMutableDictionary *response = [NSMutableDictionary dictionaryWithDictionary:data ?: @{}];
    response[@"id"] = @(requestId);
    response[@"success"] = @YES;
    response[@"timestamp"] = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
    return response;
}

static NSDictionary* errorResponse(NSInteger requestId, NSString *error) {
    return @{
        @"id": @(requestId),
        @"success": @NO,
        @"error": error ?: @"Unknown error",
        @"timestamp": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]]
    };
}

#pragma mark - Chat Resolution

static NSArray<NSString *>* chatIdentifierPrefixes(void) {
    return @[@"iMessage;-;", @"iMessage;+;", @"SMS;-;", @"SMS;+;", @"any;-;", @"any;+;"];
}

static NSString* stripKnownChatPrefix(NSString *value) {
    for (NSString *prefix in chatIdentifierPrefixes()) {
        if ([value hasPrefix:prefix]) {
            return [value substringFromIndex:prefix.length];
        }
    }
    return nil;
}

/// Try multiple methods to find a chat, including GUID lookup, chat identifier,
/// and participant matching with phone number normalization.
static id findChat(NSString *identifier) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) {
        NSLog(@"[imsg-bridge] IMChatRegistry class not found");
        return nil;
    }

    id registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) {
        NSLog(@"[imsg-bridge] Could not get IMChatRegistry instance");
        return nil;
    }

    id chat = nil;
    NSString *bareIdentifier = stripKnownChatPrefix(identifier) ?: identifier;

    // Method 1: Try existingChatWithGUID: with the identifier as-is (if it looks like a GUID)
    SEL guidSel = @selector(existingChatWithGUID:);
    if ([registry respondsToSelector:guidSel]) {
        if ([identifier containsString:@";"]) {
            chat = [registry performSelector:guidSel withObject:identifier];
            if (chat) {
                NSLog(@"[imsg-bridge] Found chat via existingChatWithGUID: %@", identifier);
                return chat;
            }
        }

        // Try constructing GUIDs with common prefixes (iMessage, SMS, any)
        for (NSString *prefix in chatIdentifierPrefixes()) {
            NSString *fullGUID = [prefix stringByAppendingString:bareIdentifier];
            chat = [registry performSelector:guidSel withObject:fullGUID];
            if (chat) {
                NSLog(@"[imsg-bridge] Found chat via existingChatWithGUID: %@", fullGUID);
                return chat;
            }
        }
    }

    // Method 2: Try existingChatWithChatIdentifier:
    SEL identSel = @selector(existingChatWithChatIdentifier:);
    if ([registry respondsToSelector:identSel]) {
        chat = [registry performSelector:identSel withObject:identifier];
        if (chat) {
            NSLog(@"[imsg-bridge] Found chat via existingChatWithChatIdentifier: %@", identifier);
            return chat;
        }
        if (![bareIdentifier isEqualToString:identifier]) {
            chat = [registry performSelector:identSel withObject:bareIdentifier];
            if (chat) {
                NSLog(@"[imsg-bridge] Found chat via existingChatWithChatIdentifier: %@", bareIdentifier);
                return chat;
            }
        }
    }

    // Method 3: Iterate all chats and match by participant
    SEL allChatsSel = @selector(allExistingChats);
    if ([registry respondsToSelector:allChatsSel]) {
        NSArray *allChats = [registry performSelector:allChatsSel];
        if (!allChats) {
            NSLog(@"[imsg-bridge] allExistingChats returned nil");
            return nil;
        }
        NSLog(@"[imsg-bridge] Searching %lu chats for identifier: %@",
              (unsigned long)allChats.count, identifier);

        // Normalize the search identifier for phone number matching
        NSString *normalizedIdentifier = nil;
        if (bareIdentifier.length > 0 &&
            ([bareIdentifier hasPrefix:@"+"] || [bareIdentifier hasPrefix:@"1"] ||
            [[NSCharacterSet decimalDigitCharacterSet]
             characterIsMember:[bareIdentifier characterAtIndex:0]])) {
            NSMutableString *digits = [NSMutableString string];
            for (NSUInteger i = 0; i < bareIdentifier.length; i++) {
                unichar c = [bareIdentifier characterAtIndex:i];
                if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:c]) {
                    [digits appendFormat:@"%C", c];
                }
            }
            normalizedIdentifier = [digits copy];
        }

        for (id aChat in allChats) {
            // Check GUID
            if ([aChat respondsToSelector:@selector(guid)]) {
                NSString *chatGUID = [aChat performSelector:@selector(guid)];
                if ([chatGUID isEqualToString:identifier] ||
                    [chatGUID isEqualToString:bareIdentifier]) {
                    NSLog(@"[imsg-bridge] Found chat by GUID exact match: %@", chatGUID);
                    return aChat;
                }
            }

            // Check chatIdentifier
            if ([aChat respondsToSelector:@selector(chatIdentifier)]) {
                NSString *chatId = [aChat performSelector:@selector(chatIdentifier)];
                if ([chatId isEqualToString:identifier] ||
                    [chatId isEqualToString:bareIdentifier]) {
                    NSLog(@"[imsg-bridge] Found chat by chatIdentifier exact match: %@", chatId);
                    return aChat;
                }
            }

            // Check participants
            if ([aChat respondsToSelector:@selector(participants)]) {
                NSArray *participants = [aChat performSelector:@selector(participants)];
                if (!participants) continue;
                for (id handle in participants) {
                    if ([handle respondsToSelector:@selector(ID)]) {
                        NSString *handleID = [handle performSelector:@selector(ID)];
                        if ([handleID isEqualToString:identifier] ||
                            [handleID isEqualToString:bareIdentifier]) {
                            NSLog(@"[imsg-bridge] Found chat by participant exact match: %@", handleID);
                            return aChat;
                        }
                        // Normalized phone number match
                        if (normalizedIdentifier && normalizedIdentifier.length >= 10) {
                            NSMutableString *handleDigits = [NSMutableString string];
                            for (NSUInteger i = 0; i < handleID.length; i++) {
                                unichar c = [handleID characterAtIndex:i];
                                if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:c]) {
                                    [handleDigits appendFormat:@"%C", c];
                                }
                            }
                            if (handleDigits.length >= 10 &&
                                ([handleDigits hasSuffix:normalizedIdentifier] ||
                                 [normalizedIdentifier hasSuffix:handleDigits])) {
                                NSLog(@"[imsg-bridge] Found chat by normalized phone match: %@ ~ %@",
                                      handleID, identifier);
                                return aChat;
                            }
                        }
                    }
                }
            }
        }
    }

    NSLog(@"[imsg-bridge] Chat not found for identifier: %@", identifier);
    return nil;
}

#pragma mark - Command Handlers

static NSDictionary* handleTyping(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSNumber *state = params[@"typing"] ?: params[@"state"];

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }

    BOOL typing = [state boolValue];
    id chat = findChat(handle);

    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    @try {
        // Gather diagnostic info
        NSString *chatGUID = @"unknown";
        NSString *chatIdent = @"unknown";
        NSString *chatClass = NSStringFromClass([chat class]);
        BOOL supportsTyping = YES;

        if ([chat respondsToSelector:@selector(guid)]) {
            chatGUID = [chat performSelector:@selector(guid)] ?: @"nil";
        }
        if ([chat respondsToSelector:@selector(chatIdentifier)]) {
            chatIdent = [chat performSelector:@selector(chatIdentifier)] ?: @"nil";
        }

        SEL supportsSel = @selector(supportsSendingTypingIndicators);
        if ([chat respondsToSelector:supportsSel]) {
            supportsTyping = ((BOOL (*)(id, SEL))objc_msgSend)(chat, supportsSel);
        }

        NSLog(@"[imsg-bridge] Chat found: class=%@, guid=%@, identifier=%@, supportsTyping=%@",
              chatClass, chatGUID, chatIdent, supportsTyping ? @"YES" : @"NO");

        SEL typingSel = @selector(setLocalUserIsTyping:);
        if ([chat respondsToSelector:typingSel]) {
            NSMethodSignature *sig = [chat methodSignatureForSelector:typingSel];
            if (!sig) {
                return errorResponse(requestId,
                    @"Could not get method signature for setLocalUserIsTyping:");
            }
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:typingSel];
            [inv setTarget:chat];
            [inv setArgument:&typing atIndex:2];
            [inv invoke];

            NSLog(@"[imsg-bridge] Called setLocalUserIsTyping:%@ for %@",
                  typing ? @"YES" : @"NO", handle);
            return successResponse(requestId, @{
                @"handle": handle,
                @"typing": @(typing)
            });
        }

        return errorResponse(requestId, @"setLocalUserIsTyping: method not available");
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Failed to set typing: %@", exception.reason]);
    }
}

static NSDictionary* handleRead(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];

    if (!handle) {
        return errorResponse(requestId, @"Missing required parameter: handle");
    }

    id chat = findChat(handle);

    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", handle]);
    }

    @try {
        SEL readSel = @selector(markAllMessagesAsRead);
        if ([chat respondsToSelector:readSel]) {
            [chat performSelector:readSel];
            NSLog(@"[imsg-bridge] Marked all messages as read for %@", handle);
            return successResponse(requestId, @{
                @"handle": handle,
                @"marked_as_read": @YES
            });
        } else {
            return errorResponse(requestId, @"markAllMessagesAsRead method not available");
        }
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Failed to mark as read: %@", exception.reason]);
    }
}

static NSDictionary* handleStatus(NSInteger requestId, NSDictionary *params) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    BOOL hasRegistry = (registryClass != nil);
    NSUInteger chatCount = 0;

    if (hasRegistry) {
        id registry = [registryClass performSelector:@selector(sharedInstance)];
        if ([registry respondsToSelector:@selector(allExistingChats)]) {
            NSArray *chats = [registry performSelector:@selector(allExistingChats)];
            chatCount = chats.count;
        }
    }

    NSDictionary *selectors = @{
        @"editMessageItem": @(gHasEditMessageItem),
        @"editMessage": @(gHasEditMessage),
        @"retractMessagePart": @(gHasRetractMessagePart),
        @"sendMessageReason": @(gHasSendMessageReason)
    };

    return successResponse(requestId, @{
        @"injected": @YES,
        @"registry_available": @(hasRegistry),
        @"chat_count": @(chatCount),
        @"typing_available": @(hasRegistry),
        @"read_available": @(hasRegistry),
        @"bridge_version": @2,
        @"v2_ready": @(rpcInboxTimer != nil),
        @"selectors": selectors
    });
}

static NSDictionary* handleListChats(NSInteger requestId, NSDictionary *params) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) {
        return errorResponse(requestId, @"IMChatRegistry not available");
    }

    id registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) {
        return errorResponse(requestId, @"Could not get IMChatRegistry instance");
    }

    NSMutableArray *chatList = [NSMutableArray array];

    if ([registry respondsToSelector:@selector(allExistingChats)]) {
        NSArray *allChats = [registry performSelector:@selector(allExistingChats)];
        for (id chat in allChats) {
            NSMutableDictionary *chatInfo = [NSMutableDictionary dictionary];

            if ([chat respondsToSelector:@selector(guid)]) {
                chatInfo[@"guid"] = [chat performSelector:@selector(guid)] ?: @"";
            }
            if ([chat respondsToSelector:@selector(chatIdentifier)]) {
                chatInfo[@"identifier"] = [chat performSelector:@selector(chatIdentifier)] ?: @"";
            }
            if ([chat respondsToSelector:@selector(participants)]) {
                NSMutableArray *handles = [NSMutableArray array];
                NSArray *participants = [chat performSelector:@selector(participants)];
                for (id handle in participants) {
                    if ([handle respondsToSelector:@selector(ID)]) {
                        [handles addObject:[handle performSelector:@selector(ID)] ?: @""];
                    }
                }
                chatInfo[@"participants"] = handles;
            }

            [chatList addObject:chatInfo];
        }
    }

    return successResponse(requestId, @{
        @"chats": chatList,
        @"count": @(chatList.count)
    });
}

#pragma mark - Resolve Chat (v2)

/// Resolve an IMChat from a chatGuid string (BlueBubbles-style addressing,
/// e.g. `iMessage;-;+15551234567` or `iMessage;+;chat0000`). Falls back to
/// `chatForIMHandle:` to materialize chats that don't yet exist in the
/// registry's allExistingChats snapshot. Returns nil if no chat could be
/// resolved or created.
static IMChat *resolveChatByGuid(NSString *chatGuid) {
    if (![chatGuid isKindOfClass:[NSString class]] || chatGuid.length == 0) {
        return nil;
    }
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) return nil;
    id registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) return nil;

    if ([registry respondsToSelector:@selector(existingChatWithGUID:)]) {
        id chat = [registry performSelector:@selector(existingChatWithGUID:)
                                 withObject:chatGuid];
        if (chat) return chat;
    }

    // Fallback: parse trailing address out of `<service>;<+|->;<address>`
    // and try to vend a handle, then materialize a chat.
    NSArray *parts = [chatGuid componentsSeparatedByString:@";"];
    if (parts.count == 3) {
        NSString *address = parts.lastObject;
        Class hrClass = NSClassFromString(@"IMHandleRegistrar");
        if (hrClass) {
            id hr = [hrClass performSelector:@selector(sharedInstance)];
            if ([hr respondsToSelector:@selector(IMHandleWithID:)]) {
                id handle = [hr performSelector:@selector(IMHandleWithID:)
                                     withObject:address];
                if (handle && [registry respondsToSelector:@selector(chatForIMHandle:)]) {
                    id chat = [registry performSelector:@selector(chatForIMHandle:)
                                             withObject:handle];
                    if (chat) return chat;
                }
            }
        }
    }
    return nil;
}

/// Resolve a chat by EITHER chatGuid (preferred) OR a free-form handle
/// (legacy path that walks `findChat`). Used to keep existing callers working.
static id resolveChatFlexible(NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if ([chatGuid isKindOfClass:[NSString class]] && chatGuid.length) {
        IMChat *chat = resolveChatByGuid(chatGuid);
        if (chat) return chat;
    }
    NSString *handle = params[@"handle"];
    if ([handle isKindOfClass:[NSString class]] && handle.length) {
        return findChat(handle);
    }
    return nil;
}

#pragma mark - AttributedBody Helpers

/// Decode a base64 NSKeyedArchiver blob into an NSAttributedString. Returns
/// nil on any decoding failure.
static NSAttributedString *attributedBodyFromBase64(NSString *b64) {
    if (![b64 isKindOfClass:[NSString class]] || b64.length == 0) return nil;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:b64
                                                       options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!data) return nil;
    NSError *err = nil;
    NSSet *allowed = [NSSet setWithObjects:
        [NSAttributedString class], [NSDictionary class], [NSString class],
        [NSArray class], [NSNumber class], [NSURL class], [NSData class], nil];
    NSAttributedString *attr = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowed
                                                                   fromData:data
                                                                      error:&err];
    if (err) {
        // Fall back to non-secure unarchiving for older blobs.
        @try {
            attr = [NSKeyedUnarchiver unarchiveObjectWithData:data];
        } @catch (__unused NSException *ex) {
            attr = nil;
        }
    }
    return attr;
}

/// Build a plain NSAttributedString carrying `text` as message-part `partIndex`.
/// Applies the private `__kIMMessagePartAttributeName` attribute IMCore expects.
static NSAttributedString *buildPlainAttributed(NSString *text, NSInteger partIndex) {
    if (![text isKindOfClass:[NSString class]]) text = @"";
    NSDictionary *attrs = @{
        @"__kIMMessagePartAttributeName": @(partIndex),
        @"__kIMBaseWritingDirectionAttributeName": @"-1"
    };
    return [[NSAttributedString alloc] initWithString:text attributes:attrs];
}

/// Apply a JSON-shape array of text-formatting ranges to `text`. Each entry is
/// `{ "start": int, "length": int, "styles": ["bold"|"italic"|"underline"|"strikethrough", ...] }`.
/// macOS 15+ only — earlier OSes silently degrade to plain text (the private
/// IMText* attribute names don't exist before Sequoia). Attribute names and
/// range shape are based on BlueBubbles helper PR #50; implementation is local.
static NSMutableAttributedString *buildFormattedAttributed(NSString *text,
                                                            NSArray *formatting,
                                                            NSInteger partIndex) {
    if (![text isKindOfClass:[NSString class]]) text = @"";
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:text];
    NSUInteger len = text.length;

    // Always carry the same base IM attributes as plain sends across the
    // whole string, then layer style ranges on top when supported.
    if (len > 0) {
        [attr addAttribute:@"__kIMMessagePartAttributeName" value:@(partIndex)
                     range:NSMakeRange(0, len)];
        [attr addAttribute:@"__kIMBaseWritingDirectionAttributeName" value:@"-1"
                     range:NSMakeRange(0, len)];
    }

    if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 15) {
        return attr;  // Pre-Sequoia: no IMText* attributes; ship plain.
    }
    if (len == 0 || ![formatting isKindOfClass:[NSArray class]] || formatting.count == 0) {
        return attr;
    }

    for (id raw in formatting) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *r = (NSDictionary *)raw;
        NSNumber *startNum = r[@"start"];
        NSNumber *lengthNum = r[@"length"];
        NSArray *styles = r[@"styles"];
        if (![startNum isKindOfClass:[NSNumber class]]) continue;
        if (![lengthNum isKindOfClass:[NSNumber class]]) continue;
        if (![styles isKindOfClass:[NSArray class]]) continue;
        NSInteger start = startNum.integerValue;
        NSInteger length = lengthNum.integerValue;
        if (start < 0 || length <= 0) continue;
        if ((NSUInteger)(start + length) > len) continue;

        NSRange range = NSMakeRange((NSUInteger)start, (NSUInteger)length);
        if ([styles containsObject:@"bold"]) {
            [attr addAttribute:@"__kIMTextBoldAttributeName" value:@1 range:range];
        }
        if ([styles containsObject:@"italic"]) {
            [attr addAttribute:@"__kIMTextItalicAttributeName" value:@1 range:range];
        }
        if ([styles containsObject:@"underline"]) {
            [attr addAttribute:@"__kIMTextUnderlineAttributeName" value:@1 range:range];
        }
        if ([styles containsObject:@"strikethrough"]) {
            [attr addAttribute:@"__kIMTextStrikethroughAttributeName" value:@1 range:range];
        }
    }
    return attr;
}

#pragma mark - IMMessage Builder

/// Build an IMMessage suitable for `[chat sendMessage:]`. Handles plain text,
/// optional subject, optional effect (`com.apple.MobileSMS.expressivesend.*`),
/// optional reply target (`selectedMessageGuid`), and ddScan flag.
static id buildIMMessage(NSAttributedString *body,
                         NSAttributedString *subject,
                         NSString *effectId,
                         NSString *threadIdentifier,
                         NSString *associatedMessageGuid,
                         long long associatedMessageType,
                         NSRange associatedMessageRange,
                         NSDictionary *summaryInfo,
                         NSArray *fileTransferGuids,
                         BOOL isAudioMessage,
                         BOOL ddScan) {
    Class messageClass = NSClassFromString(@"IMMessage");
    if (!messageClass) return nil;

    // Reaction / reply path: associatedMessageGuid + associatedMessageType.
    if (associatedMessageGuid.length && associatedMessageType > 0) {
        SEL sel = @selector(initIMMessageWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:);
        id msg = [messageClass alloc];
        if ([msg respondsToSelector:sel]) {
            unsigned long long flags = 0x5;
            NSMethodSignature *sig = [messageClass instanceMethodSignatureForSelector:sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:sel];
            [inv setTarget:msg];
            id nilObj = nil;
            NSDate *now = [NSDate date];
            [inv setArgument:&nilObj atIndex:2];        // sender
            [inv setArgument:&now atIndex:3];           // time
            [inv setArgument:&body atIndex:4];          // text
            [inv setArgument:&subject atIndex:5];       // messageSubject
            [inv setArgument:&fileTransferGuids atIndex:6];
            [inv setArgument:&flags atIndex:7];
            [inv setArgument:&nilObj atIndex:8];        // error
            [inv setArgument:&nilObj atIndex:9];        // guid
            [inv setArgument:&nilObj atIndex:10];       // subject (string form)
            [inv setArgument:&nilObj atIndex:11];       // balloonBundleID
            [inv setArgument:&nilObj atIndex:12];       // payloadData
            [inv setArgument:&effectId atIndex:13];     // expressiveSendStyleID
            [inv setArgument:&associatedMessageGuid atIndex:14];
            [inv setArgument:&associatedMessageType atIndex:15];
            [inv setArgument:&associatedMessageRange atIndex:16];
            [inv setArgument:&summaryInfo atIndex:17];
            [inv invoke];
            __unsafe_unretained id result = nil;
            [inv getReturnValue:&result];
            return result;
        }
    }

    // Normal send / reply path.
    SEL sel = @selector(initIMMessageWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:);
    id msg = [messageClass alloc];
    if ([msg respondsToSelector:sel]) {
        unsigned long long flags;
        if (isAudioMessage) {
            flags = 0x300005ULL;
        } else if (subject.length) {
            flags = 0x10000dULL;
        } else {
            flags = 0x100005ULL;
        }
        NSMethodSignature *sig = [messageClass instanceMethodSignatureForSelector:sel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:sel];
        [inv setTarget:msg];
        id nilObj = nil;
        NSDate *now = [NSDate date];
        [inv setArgument:&nilObj atIndex:2];           // sender
        [inv setArgument:&now atIndex:3];              // time
        [inv setArgument:&body atIndex:4];             // text
        [inv setArgument:&subject atIndex:5];          // messageSubject
        [inv setArgument:&fileTransferGuids atIndex:6];
        [inv setArgument:&flags atIndex:7];
        [inv setArgument:&nilObj atIndex:8];           // error
        [inv setArgument:&nilObj atIndex:9];           // guid
        [inv setArgument:&nilObj atIndex:10];          // subject string
        [inv setArgument:&nilObj atIndex:11];          // balloonBundleID
        [inv setArgument:&nilObj atIndex:12];          // payloadData
        [inv setArgument:&effectId atIndex:13];        // expressiveSendStyleID
        [inv invoke];
        __unsafe_unretained id result = nil;
        [inv getReturnValue:&result];
        return result;
    }

    // Last resort: simplest 2-arg initializer if the long form isn't available.
    SEL simple = @selector(initWithText:flags:);
    if ([msg respondsToSelector:simple]) {
        unsigned long long flags = 0x100005ULL;
        NSMethodSignature *sig2 = [messageClass instanceMethodSignatureForSelector:simple];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig2];
        [inv setSelector:simple];
        [inv setTarget:msg];
        [inv setArgument:&body atIndex:2];
        [inv setArgument:&flags atIndex:3];
        [inv invoke];
        __unsafe_unretained id result = nil;
        [inv getReturnValue:&result];
        return result;
    }
    return nil;
}

/// Async chat-item lookup. Calls cb on the main thread once items are loaded
/// (or with nil if loading times out / no match). Note: the Messages.app
/// IMChatHistoryController loads asynchronously into chat.chatItems; we issue
/// the load and then poll for the matching guid.
static id findMessageItem(IMChat *chat, NSString *messageGuid) {
    if (!chat || !messageGuid.length) {
        return nil;
    }
    Class hcClass = NSClassFromString(@"IMChatHistoryController");
    id hc = hcClass ? [hcClass performSelector:@selector(sharedInstance)] : nil;
    if (hc && [hc respondsToSelector:@selector(loadedChatItemsForChat:beforeDate:limit:loadIfNeeded:)]) {
        NSMethodSignature *sig = [hc methodSignatureForSelector:
            @selector(loadedChatItemsForChat:beforeDate:limit:loadIfNeeded:)];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:@selector(loadedChatItemsForChat:beforeDate:limit:loadIfNeeded:)];
        [inv setTarget:hc];
        [inv setArgument:&chat atIndex:2];
        NSDate *now = [NSDate date];
        [inv setArgument:&now atIndex:3];
        NSUInteger limit = 100;
        [inv setArgument:&limit atIndex:4];
        BOOL load = YES;
        [inv setArgument:&load atIndex:5];
        [inv invoke];
    }

    // Poll chat.chatItems for the guid for up to 2s. Spinning the current
    // run loop gives IMCore a chance to finish loading requested chat items.
    for (NSInteger attempts = 0; attempts < 20; attempts++) {
        NSArray *items = nil;
        if ([chat respondsToSelector:@selector(chatItems)]) {
            items = [chat performSelector:@selector(chatItems)];
        }
        for (id item in items) {
            id message = nil;
            if ([item respondsToSelector:@selector(message)]) {
                message = [item performSelector:@selector(message)];
            }
            NSString *guid = nil;
            if (message && [message respondsToSelector:@selector(guid)]) {
                guid = [message performSelector:@selector(guid)];
            } else if ([item respondsToSelector:@selector(guid)]) {
                guid = [item performSelector:@selector(guid)];
            }
            if ([guid isEqualToString:messageGuid]) {
                return item;
            }
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return nil;
}

/// Best-effort messageGuid extractor for transactional sends. Returns the
/// guid of `chat.lastSentMessage` after a brief grace period for the message
/// to register, or nil if unavailable.
static NSString *lastSentMessageGuid(IMChat *chat) {
    if (!chat || ![chat respondsToSelector:@selector(lastSentMessage)]) return nil;
    id msg = [chat performSelector:@selector(lastSentMessage)];
    if (msg && [msg respondsToSelector:@selector(guid)]) {
        return [msg performSelector:@selector(guid)];
    }
    return nil;
}

#pragma mark - v2 Response Helpers

/// Build a v2-shaped success envelope: { v:2, id, success:true, data:{...} }
static NSDictionary* successResponseV2(NSString *uuid, NSDictionary *data) {
    return @{
        @"v": @2,
        @"id": uuid ?: @"",
        @"success": @YES,
        @"data": data ?: @{},
        @"timestamp": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]]
    };
}

/// Build a v2-shaped error envelope.
static NSDictionary* errorResponseV2(NSString *uuid, NSString *error) {
    return @{
        @"v": @2,
        @"id": uuid ?: @"",
        @"success": @NO,
        @"error": error ?: @"Unknown error",
        @"timestamp": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]]
    };
}

#pragma mark - Inbound Events (v2)

/// Append a single JSON object as a line to `.imsg-events.jsonl`. Rotates the
/// file once it crosses kEventsRotateBytes by renaming to `.1` (overwriting).
/// Safe to call from any thread (guarded by an unfair lock).
__attribute__((unused))
static void appendEvent(NSDictionary *evt) {
    if (![evt isKindOfClass:[NSDictionary class]]) return;
    initFilePaths();

    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithDictionary:evt];
    if (out[@"ts"] == nil) {
        out[@"ts"] = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
    }

    NSError *err = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:out options:0 error:&err];
    if (!body) return;

    os_unfair_lock_lock(&eventsLock);

    // Rotate if oversized.
    struct stat st;
    if (stat(kEventsFile.UTF8String, &st) == 0 && st.st_size >= (off_t)kEventsRotateBytes) {
        rename(kEventsFile.UTF8String, kEventsRotated.UTF8String);
    }

    FILE *fp = fopen(kEventsFile.UTF8String, "a");
    if (fp != NULL) {
        fwrite(body.bytes, 1, body.length, fp);
        fputc('\n', fp);
        fclose(fp);
    }

    os_unfair_lock_unlock(&eventsLock);
}

#pragma mark - Send Handlers (v2)

/// Implementation core for `send-message`. Builds an IMMessage with optional
/// effect/subject/reply and dispatches via `[chat sendMessage:]`. ddScan on
/// macOS 13+ defers the send by 100ms.
static NSDictionary *handleSendMessage(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *message = params[@"message"];
    NSString *effectId = params[@"effectId"];
    NSString *subject = params[@"subject"];
    NSString *selectedMessageGuid = params[@"selectedMessageGuid"];
    NSNumber *partIndexNum = params[@"partIndex"];
    NSInteger partIndex = partIndexNum ? [partIndexNum integerValue] : 0;
    NSNumber *ddScanNum = params[@"ddScan"];
    BOOL ddScan = [ddScanNum boolValue];
    NSString *attributedBodyB64 = params[@"attributedBody"];
    NSArray *textFormatting = params[@"textFormatting"];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!message) message = @"";

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    NSAttributedString *body = attributedBodyFromBase64(attributedBodyB64);
    if (!body) {
        if ([textFormatting isKindOfClass:[NSArray class]] && textFormatting.count > 0) {
            body = buildFormattedAttributed(message, textFormatting, partIndex);
        } else {
            body = buildPlainAttributed(message, partIndex);
        }
    }
    NSAttributedString *subjectAttr = subject.length
        ? buildPlainAttributed(subject, 0)
        : nil;

    NSRange zeroRange = NSMakeRange(0, body.length);
    long long associatedType = selectedMessageGuid.length ? 100 : 0;

    @try {
        id imMessage = buildIMMessage(body, subjectAttr,
                                      effectId,
                                      /*threadIdentifier*/ nil,
                                      selectedMessageGuid,
                                      associatedType,
                                      zeroRange,
                                      /*summaryInfo*/ nil,
                                      /*fileTransferGuids*/ @[],
                                      /*isAudio*/ NO,
                                      ddScan);
        if (!imMessage) {
            return errorResponse(requestId, @"Could not construct IMMessage");
        }

        if (gHasSendMessageReason && ddScan) {
            // Deferred-send path on macOS 13+: sleep 100ms, then call
            // `sendMessage:reason:` so the spam filter can run on the body.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                NSMethodSignature *sig = [chat methodSignatureForSelector:
                    @selector(sendMessage:reason:)];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:@selector(sendMessage:reason:)];
                [inv setTarget:chat];
                __unsafe_unretained id arg = imMessage;
                [inv setArgument:&arg atIndex:2];
                NSInteger reason = 0;
                [inv setArgument:&reason atIndex:3];
                [inv invoke];
            });
        } else {
            [chat performSelector:@selector(sendMessage:) withObject:imMessage];
        }

        // Best-effort messageGuid; not always available immediately.
        NSString *guid = lastSentMessageGuid(chat);
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"messageGuid": guid ?: @"",
            @"queued": @(ddScan)
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-message failed: %@", exception.reason]);
    }
}

/// `send-multipart`: at minimum, sends an attributedBody composed of multiple
/// text parts. v1 supports text-only multipart; mention/file parts can land in
/// a follow-up.
static NSDictionary *handleSendMultipart(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSArray *parts = params[@"parts"];
    NSString *effectId = params[@"effectId"];
    NSString *subject = params[@"subject"];
    NSString *selectedMessageGuid = params[@"selectedMessageGuid"];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (![parts isKindOfClass:[NSArray class]] || parts.count == 0) {
        return errorResponse(requestId, @"Missing or empty parts array");
    }

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    NSMutableAttributedString *body = [[NSMutableAttributedString alloc] init];
    NSInteger partIndex = 0;
    for (NSDictionary *part in parts) {
        if (![part isKindOfClass:[NSDictionary class]]) continue;
        NSString *text = part[@"text"];
        if (!text.length) continue;
        NSArray *partFormatting = part[@"textFormatting"];
        NSAttributedString *seg;
        if ([partFormatting isKindOfClass:[NSArray class]] && partFormatting.count > 0) {
            seg = buildFormattedAttributed(text, partFormatting, partIndex);
        } else {
            seg = buildPlainAttributed(text, partIndex);
        }
        [body appendAttributedString:seg];
        partIndex++;
    }
    if (body.length == 0) {
        return errorResponse(requestId, @"No usable parts");
    }

    NSAttributedString *subjectAttr = subject.length
        ? buildPlainAttributed(subject, 0)
        : nil;

    @try {
        long long associatedType = selectedMessageGuid.length ? 100 : 0;
        id imMessage = buildIMMessage(body, subjectAttr, effectId, nil,
                                      selectedMessageGuid, associatedType,
                                      NSMakeRange(0, body.length),
                                      nil, @[], NO, NO);
        if (!imMessage) {
            return errorResponse(requestId, @"Could not construct multipart IMMessage");
        }
        [chat performSelector:@selector(sendMessage:) withObject:imMessage];
        NSString *guid = lastSentMessageGuid(chat);
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"messageGuid": guid ?: @"",
            @"parts_count": @(partIndex)
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-multipart failed: %@", exception.reason]);
    }
}

/// `send-attachment`: registers the file via IMFileTransferCenter and sends a
/// (typically empty-body) message referencing that transfer guid.
static NSDictionary *handleSendAttachment(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *filePath = params[@"filePath"];
    NSNumber *audioFlag = params[@"isAudioMessage"];
    BOOL isAudio = [audioFlag boolValue];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!filePath.length) return errorResponse(requestId, @"Missing filePath");
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"File not found: %@", filePath]);
    }

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    Class ftcClass = NSClassFromString(@"IMFileTransferCenter");
    if (!ftcClass) {
        return errorResponse(requestId, @"IMFileTransferCenter not available");
    }
    id ftc = [ftcClass performSelector:@selector(sharedInstance)];
    if (!ftc) return errorResponse(requestId, @"FileTransferCenter unavailable");

    NSURL *fileURL = [NSURL fileURLWithPath:filePath];
    @try {
        id transferGuid = nil;
        if ([ftc respondsToSelector:@selector(guidForNewOutgoingTransferWithLocalURL:)]) {
            transferGuid = [ftc performSelector:
                @selector(guidForNewOutgoingTransferWithLocalURL:)
                                     withObject:fileURL];
        }
        if (![transferGuid isKindOfClass:[NSString class]] || ![(NSString *)transferGuid length]) {
            return errorResponse(requestId, @"Could not register attachment transfer");
        }

        NSAttributedString *body = buildPlainAttributed(@"￼", 0); // OBJ replacement char
        id imMessage = buildIMMessage(body, nil, nil, nil, nil, 0,
                                      NSMakeRange(0, body.length), nil,
                                      @[transferGuid], isAudio, NO);
        if (!imMessage) {
            return errorResponse(requestId, @"Could not build IMMessage with attachment");
        }
        [chat performSelector:@selector(sendMessage:) withObject:imMessage];
        NSString *guid = lastSentMessageGuid(chat);
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"messageGuid": guid ?: @"",
            @"transferGuid": transferGuid
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-attachment failed: %@", exception.reason]);
    }
}

/// `send-reaction`: builds a reaction IMMessage tied to the target guid.
static NSDictionary *handleSendReaction(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *selectedMessageGuid = params[@"selectedMessageGuid"];
    NSString *reactionType = params[@"reactionType"];
    NSNumber *partIndexNum = params[@"partIndex"];
    NSInteger partIndex = partIndexNum ? [partIndexNum integerValue] : 0;

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!selectedMessageGuid.length) return errorResponse(requestId, @"Missing selectedMessageGuid");
    if (!reactionType.length) return errorResponse(requestId, @"Missing reactionType");

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    long long associatedType = -1;
    NSDictionary *kindMap = @{
        @"love": @2000, @"like": @2001, @"dislike": @2002,
        @"laugh": @2003, @"emphasize": @2004, @"question": @2005,
        @"remove-love": @3000, @"remove-like": @3001, @"remove-dislike": @3002,
        @"remove-laugh": @3003, @"remove-emphasize": @3004, @"remove-question": @3005,
    };
    NSNumber *typeNum = kindMap[reactionType.lowercaseString];
    if (typeNum) associatedType = [typeNum longLongValue];
    if (associatedType <= 0) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Unknown reactionType: %@", reactionType]);
    }

    NSAttributedString *body = buildPlainAttributed(@"", partIndex);
    NSDictionary *summary = @{
        @"amc": selectedMessageGuid,
        @"ams": @"",
    };
    @try {
        id imMessage = buildIMMessage(body, nil, nil, nil,
                                      selectedMessageGuid,
                                      associatedType,
                                      NSMakeRange(0, 1),
                                      summary,
                                      @[], NO, NO);
        if (!imMessage) {
            return errorResponse(requestId, @"Could not build reaction IMMessage");
        }
        [chat performSelector:@selector(sendMessage:) withObject:imMessage];
        NSString *guid = lastSentMessageGuid(chat);
        return successResponse(requestId, @{
            @"chatGuid": chatGuid,
            @"selectedMessageGuid": selectedMessageGuid,
            @"reactionType": reactionType,
            @"messageGuid": guid ?: @""
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"send-reaction failed: %@", exception.reason]);
    }
}

/// `notify-anyways`: ask Messages.app to deliver a low-priority notification
/// for a previously-suppressed message guid.
static NSDictionary *handleNotifyAnyways(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *messageGuid = params[@"messageGuid"];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!messageGuid.length) return errorResponse(requestId, @"Missing messageGuid");

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    @try {
        SEL sel = @selector(sendMessageAcknowledgment:forChatItem:withMessageSummaryInfo:withGuid:);
        if (![chat respondsToSelector:sel]) {
            return errorResponse(requestId, @"sendMessageAcknowledgment: not available");
        }
        id item = findMessageItem(chat, messageGuid);
        if (!item) {
            return errorResponse(requestId,
                [NSString stringWithFormat:@"Message not found: %@", messageGuid]);
        }
        NSMethodSignature *sig = [chat methodSignatureForSelector:sel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:sel];
        [inv setTarget:chat];
        NSInteger ack = 1000;
        [inv setArgument:&ack atIndex:2];
        __unsafe_unretained id ci = item;
        [inv setArgument:&ci atIndex:3];
        NSDictionary *empty = @{};
        [inv setArgument:&empty atIndex:4];
        __unsafe_unretained NSString *nilGuid = nil;
        [inv setArgument:&nilGuid atIndex:5];
        [inv invoke];
        return successResponse(requestId, @{
            @"chatGuid": chatGuid, @"messageGuid": messageGuid, @"queued": @YES
        });
    } @catch (NSException *exception) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"notify-anyways failed: %@", exception.reason]);
    }
}

#pragma mark - Mutate Handlers (v2)

/// `edit-message`: rewrite an existing message via the edit selector
/// appropriate for the running macOS. Preserves BB's "Compatability" typo.
static NSDictionary *handleEditMessage(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *messageGuid = params[@"messageGuid"];
    NSString *newText = params[@"editedMessage"];
    NSString *bcText = params[@"backwardsCompatibilityMessage"]
                     ?: params[@"backwardCompatibilityMessage"];
    NSNumber *partIndexNum = params[@"partIndex"];
    NSInteger partIndex = partIndexNum ? [partIndexNum integerValue] : 0;

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!messageGuid.length) return errorResponse(requestId, @"Missing messageGuid");
    if (!newText.length) return errorResponse(requestId, @"Missing editedMessage");
    if (!bcText) bcText = newText;

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }
    if (!gHasEditMessageItem && !gHasEditMessage) {
        return errorResponse(requestId, @"No edit-message selector available on this macOS");
    }

    NSAttributedString *newBody = buildPlainAttributed(newText, partIndex);

    id item = findMessageItem(chat, messageGuid);
    if (!item) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Message not found: %@", messageGuid]);
    }

    @try {
        NSInteger localPartIndex = partIndex;
        if (gHasEditMessageItem) {
            SEL sel = @selector(editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:);
            NSMethodSignature *sig = [chat methodSignatureForSelector:sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:sel];
            [inv setTarget:chat];
            __unsafe_unretained id ci = item;
            [inv setArgument:&ci atIndex:2];
            [inv setArgument:&localPartIndex atIndex:3];
            __unsafe_unretained NSAttributedString *newBodyArg = newBody;
            [inv setArgument:&newBodyArg atIndex:4];
            __unsafe_unretained NSString *bcArg = bcText;
            [inv setArgument:&bcArg atIndex:5];
            [inv invoke];
        } else {
            // macOS 13 path
            SEL sel = @selector(editMessage:atPartIndex:withNewPartText:backwardCompatabilityText:);
            id message = nil;
            if ([item respondsToSelector:@selector(message)]) {
                message = [item performSelector:@selector(message)];
            }
            if (!message) {
                return errorResponse(requestId,
                    [NSString stringWithFormat:@"Message object not found: %@", messageGuid]);
            }
            NSMethodSignature *sig = [chat methodSignatureForSelector:sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:sel];
            [inv setTarget:chat];
            __unsafe_unretained id msg = message;
            [inv setArgument:&msg atIndex:2];
            [inv setArgument:&localPartIndex atIndex:3];
            __unsafe_unretained NSAttributedString *newBodyArg = newBody;
            [inv setArgument:&newBodyArg atIndex:4];
            __unsafe_unretained NSString *bcArg = bcText;
            [inv setArgument:&bcArg atIndex:5];
            [inv invoke];
        }
    } @catch (NSException *ex) {
        return errorResponse(requestId, ex.reason ?: @"edit-message failed");
    }

    return successResponse(requestId, @{
        @"chatGuid": chatGuid,
        @"messageGuid": messageGuid,
        @"queued": @YES
    });
}

/// `unsend-message`: retract a part of a sent message via retractMessagePart:.
static NSDictionary *handleUnsendMessage(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *messageGuid = params[@"messageGuid"];
    NSNumber *partIndexNum = params[@"partIndex"];
    NSInteger partIndex = partIndexNum ? [partIndexNum integerValue] : 0;

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!messageGuid.length) return errorResponse(requestId, @"Missing messageGuid");

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }
    if (!gHasRetractMessagePart) {
        return errorResponse(requestId, @"retractMessagePart: not available on this macOS");
    }

    id messageItem = findMessageItem(chat, messageGuid);
    if (!messageItem) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Message not found: %@", messageGuid]);
    }

    @try {
        id newChatItems = nil;
        SEL ncSel = @selector(_newChatItems);
        if ([messageItem respondsToSelector:ncSel]) {
            // Route through objc_msgSend to avoid ARC's "performSelector
            // names a selector which retains the object" warning on the
            // underscore-prefixed selector.
            newChatItems = ((id (*)(id, SEL))objc_msgSend)(messageItem, ncSel);
        }
        id target = nil;
        if ([newChatItems isKindOfClass:[NSArray class]]) {
            NSArray *arr = newChatItems;
            if (arr.count == 0) target = messageItem;
            else if (arr.count == 1) target = arr.firstObject;
            else {
                for (id sub in arr) {
                    // Aggregate attachment unwrap
                    if ([sub respondsToSelector:@selector(aggregateAttachmentParts)]) {
                        NSArray *agg = [sub performSelector:@selector(aggregateAttachmentParts)];
                        for (id p in agg) {
                            if ([p respondsToSelector:@selector(index)]
                                && [(IMMessagePartChatItem *)p index] == partIndex) {
                                target = p; break;
                            }
                        }
                        if (target) break;
                    }
                    if ([sub respondsToSelector:@selector(index)]
                        && [(IMMessagePartChatItem *)sub index] == partIndex) {
                        target = sub; break;
                    }
                }
            }
        } else if (newChatItems != nil) {
            target = newChatItems;
        } else {
            target = messageItem;
        }
        if (!target) {
            return errorResponse(requestId,
                [NSString stringWithFormat:@"Message part not found: %ld", (long)partIndex]);
        }
        [chat performSelector:@selector(retractMessagePart:) withObject:target];
    } @catch (NSException *ex) {
        return errorResponse(requestId, ex.reason ?: @"unsend-message failed");
    }

    return successResponse(requestId, @{
        @"chatGuid": chatGuid,
        @"messageGuid": messageGuid,
        @"queued": @YES
    });
}

/// `delete-message`: remove a single message from the chat.
static NSDictionary *handleDeleteMessage(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *messageGuid = params[@"messageGuid"];

    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!messageGuid.length) return errorResponse(requestId, @"Missing messageGuid");

    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Chat not found: %@", chatGuid]);
    }

    SEL sel = @selector(deleteChatItems:);
    if (![chat respondsToSelector:sel]) {
        return errorResponse(requestId, @"deleteChatItems: not available");
    }

    id item = findMessageItem(chat, messageGuid);
    if (!item) {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Message not found: %@", messageGuid]);
    }
    @try {
        [chat performSelector:sel withObject:@[item]];
    } @catch (NSException *ex) {
        return errorResponse(requestId, ex.reason ?: @"delete-message failed");
    }

    return successResponse(requestId, @{
        @"chatGuid": chatGuid, @"messageGuid": messageGuid, @"queued": @YES
    });
}

#pragma mark - Chat Management Handlers (v2)

static NSDictionary *handleStartTyping(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    @try { [chat setLocalUserIsTyping:YES]; }
    @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"typing": @YES});
}

static NSDictionary *handleStopTyping(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    @try { [chat setLocalUserIsTyping:NO]; }
    @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"typing": @NO});
}

static NSDictionary *handleCheckTypingStatus(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    BOOL typing = NO;
    if ([chat respondsToSelector:@selector(isCurrentlyTyping)]) {
        typing = ((BOOL (*)(id, SEL))objc_msgSend)(chat, @selector(isCurrentlyTyping));
    }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"typing": @(typing)});
}

static NSDictionary *handleMarkChatRead(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *handle = params[@"handle"];
    id chat = nil;
    if (chatGuid.length) chat = resolveChatByGuid(chatGuid);
    if (!chat && handle.length) chat = findChat(handle);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    @try { [chat performSelector:@selector(markAllMessagesAsRead)]; }
    @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid ?: @"", @"marked_as_read": @YES});
}

static NSDictionary *handleMarkChatUnread(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    @try {
        if ([chat respondsToSelector:@selector(setUnreadCount:)]) {
            SEL sel = @selector(setUnreadCount:);
            NSMethodSignature *sig = [chat methodSignatureForSelector:sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:sel];
            [inv setTarget:chat];
            NSInteger unreadCount = 1;
            [inv setArgument:&unreadCount atIndex:2];
            [inv invoke];
        } else {
            return errorResponse(requestId, @"setUnreadCount: not available");
        }
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"marked_as_unread": @YES});
}

static NSDictionary *handleAddParticipant(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *address = params[@"address"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!address.length) return errorResponse(requestId, @"Missing address");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");

    Class hrClass = NSClassFromString(@"IMHandleRegistrar");
    id hr = hrClass ? [hrClass performSelector:@selector(sharedInstance)] : nil;
    id handle = (hr && [hr respondsToSelector:@selector(IMHandleWithID:)])
        ? [hr performSelector:@selector(IMHandleWithID:) withObject:address]
        : nil;
    if (!handle) return errorResponse(requestId, @"Could not vend handle");

    @try {
        SEL sel = @selector(addParticipantsToiMessageChat:reason:);
        if (![chat respondsToSelector:sel]) {
            return errorResponse(requestId, @"addParticipantsToiMessageChat:reason: not available");
        }
        NSMethodSignature *sig = [chat methodSignatureForSelector:sel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:sel];
        [inv setTarget:chat];
        NSArray *handles = @[handle];
        [inv setArgument:&handles atIndex:2];
        NSInteger reason = 0;
        [inv setArgument:&reason atIndex:3];
        [inv invoke];
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"address": address, @"added": @YES});
}

static NSDictionary *handleRemoveParticipant(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *address = params[@"address"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    if (!address.length) return errorResponse(requestId, @"Missing address");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");

    // Find the matching participant handle on the chat itself.
    id targetHandle = nil;
    if ([chat respondsToSelector:@selector(participants)]) {
        for (id h in [chat performSelector:@selector(participants)]) {
            if ([h respondsToSelector:@selector(ID)]
                && [[h performSelector:@selector(ID)] isEqualToString:address]) {
                targetHandle = h; break;
            }
        }
    }
    if (!targetHandle) return errorResponse(requestId, @"Participant not found on chat");

    @try {
        SEL sel = @selector(removeParticipantsFromiMessageChat:reason:);
        if (![chat respondsToSelector:sel]) {
            return errorResponse(requestId, @"removeParticipantsFromiMessageChat:reason: not available");
        }
        NSMethodSignature *sig = [chat methodSignatureForSelector:sel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:sel];
        [inv setTarget:chat];
        NSArray *handles = @[targetHandle];
        [inv setArgument:&handles atIndex:2];
        NSInteger reason = 0;
        [inv setArgument:&reason atIndex:3];
        [inv invoke];
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"address": address, @"removed": @YES});
}

static NSDictionary *handleSetDisplayName(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *newName = params[@"newName"] ?: params[@"name"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    @try {
        if ([chat respondsToSelector:@selector(setDisplayName:)]) {
            [chat performSelector:@selector(setDisplayName:) withObject:newName ?: @""];
        } else {
            return errorResponse(requestId, @"setDisplayName: not available");
        }
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"name": newName ?: @""});
}

static NSDictionary *handleUpdateGroupPhoto(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    NSString *filePath = params[@"filePath"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");

    NSData *photoData = nil;
    if (filePath.length) {
        photoData = [NSData dataWithContentsOfFile:filePath];
        if (!photoData) {
            return errorResponse(requestId,
                [NSString stringWithFormat:@"Could not read photo: %@", filePath]);
        }
    }
    @try {
        SEL sel = @selector(setGroupPhotoData:);
        if (![chat respondsToSelector:sel]) {
            return errorResponse(requestId, @"setGroupPhotoData: not available");
        }
        [chat performSelector:sel withObject:photoData];
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{
        @"chatGuid": chatGuid,
        @"cleared": @(filePath.length == 0),
        @"size": @(photoData.length)
    });
}

static NSDictionary *handleLeaveChat(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    @try {
        if ([chat respondsToSelector:@selector(leaveChat)]) {
            [chat performSelector:@selector(leaveChat)];
        } else {
            return errorResponse(requestId, @"leaveChat not available");
        }
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"left": @YES});
}

static NSDictionary *handleDeleteChat(NSInteger requestId, NSDictionary *params) {
    NSString *chatGuid = params[@"chatGuid"];
    if (!chatGuid.length) return errorResponse(requestId, @"Missing chatGuid");
    IMChat *chat = resolveChatByGuid(chatGuid);
    if (!chat) return errorResponse(requestId, @"Chat not found");
    Class regClass = NSClassFromString(@"IMChatRegistry");
    id reg = regClass ? [regClass performSelector:@selector(sharedInstance)] : nil;
    SEL sel = @selector(deleteChat:);
    if (!reg || ![reg respondsToSelector:sel]) {
        return errorResponse(requestId, @"deleteChat: not available");
    }
    @try {
        [reg performSelector:sel withObject:chat];
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"chatGuid": chatGuid, @"deleted": @YES});
}

/// `create-chat`: vend handles for each address, ask the registry for a chat
/// instance, optionally set the display name, optionally send an initial
/// message. Returns the new chat's guid.
static NSDictionary *handleCreateChat(NSInteger requestId, NSDictionary *params) {
    NSArray *addresses = params[@"addresses"];
    NSString *initialMessage = params[@"message"];
    NSString *displayName = params[@"displayName"] ?: params[@"name"];
    NSString *service = params[@"service"] ?: @"iMessage";

    if (![addresses isKindOfClass:[NSArray class]] || addresses.count == 0) {
        return errorResponse(requestId, @"Missing addresses array");
    }
    if ([service caseInsensitiveCompare:@"iMessage"] != NSOrderedSame) {
        return errorResponse(requestId, [NSString stringWithFormat:
            @"Unsupported chat-create service: %@", service]);
    }
    service = @"iMessage";

    Class hrClass = NSClassFromString(@"IMHandleRegistrar");
    id hr = hrClass ? [hrClass performSelector:@selector(sharedInstance)] : nil;
    if (!hr) return errorResponse(requestId, @"IMHandleRegistrar unavailable");

    NSMutableArray *handles = [NSMutableArray array];
    for (NSString *addr in addresses) {
        if (![addr isKindOfClass:[NSString class]]) continue;
        id h = [hr performSelector:@selector(IMHandleWithID:) withObject:addr];
        if (h) [handles addObject:h];
    }
    if (handles.count == 0) {
        return errorResponse(requestId, @"Could not vend handles for any address");
    }

    Class regClass = NSClassFromString(@"IMChatRegistry");
    id reg = regClass ? [regClass performSelector:@selector(sharedInstance)] : nil;
    id chat = nil;
    if (handles.count == 1 && [reg respondsToSelector:@selector(chatForIMHandle:)]) {
        chat = [reg performSelector:@selector(chatForIMHandle:) withObject:handles.firstObject];
    } else if ([reg respondsToSelector:@selector(chatForIMHandles:)]) {
        chat = [reg performSelector:@selector(chatForIMHandles:) withObject:handles];
    }
    if (!chat) return errorResponse(requestId, @"Registry could not produce chat");

    if (displayName.length && [chat respondsToSelector:@selector(setDisplayName:)]) {
        @try { [chat performSelector:@selector(setDisplayName:) withObject:displayName]; }
        @catch (__unused NSException *ex) {}
    }

    NSString *messageGuid = nil;
    if (initialMessage.length) {
        NSAttributedString *body = buildPlainAttributed(initialMessage, 0);
        @try {
            id imMessage = buildIMMessage(body, nil, nil, nil, nil, 0,
                                          NSMakeRange(0, body.length),
                                          nil, @[], NO, NO);
            if (imMessage) {
                [chat performSelector:@selector(sendMessage:) withObject:imMessage];
                messageGuid = lastSentMessageGuid(chat);
            }
        } @catch (__unused NSException *ex) {}
    }

    NSString *guid = [chat respondsToSelector:@selector(guid)]
        ? [chat performSelector:@selector(guid)] : @"";
    return successResponse(requestId, @{
        @"chatGuid": guid ?: @"",
        @"service": service,
        @"messageGuid": messageGuid ?: @"",
        @"participants": addresses
    });
}

#pragma mark - Introspection Handlers (v2)

static NSDictionary *handleSearchMessages(NSInteger requestId, NSDictionary *params) {
    NSString *query = params[@"query"];
    if (![query isKindOfClass:[NSString class]] || query.length == 0) {
        return errorResponse(requestId, @"Missing query");
    }
    // Spotlight-style search across loaded chat items via IMChatHistoryController
    // is not exposed to us cleanly without private headers; return a structured
    // not-implemented response so the CLI can degrade gracefully.
    return successResponse(requestId, @{
        @"query": query,
        @"results": @[],
        @"note": @"server-side search not yet implemented; falls back to chat.db"
    });
}

static NSDictionary *handleGetAccountInfo(NSInteger requestId, NSDictionary *params) {
    Class accClass = NSClassFromString(@"IMAccountController");
    if (!accClass) return errorResponse(requestId, @"IMAccountController unavailable");
    id ctrl = [accClass performSelector:@selector(sharedInstance)];
    if (!ctrl) return errorResponse(requestId, @"controller nil");

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if ([ctrl respondsToSelector:@selector(activeIMessageAccount)]) {
        id account = [ctrl performSelector:@selector(activeIMessageAccount)];
        if (account) {
            NSArray *aliases = nil;
            if ([account respondsToSelector:@selector(vettedAliases)]) {
                aliases = [account performSelector:@selector(vettedAliases)];
            }
            id login = nil;
            if ([account respondsToSelector:@selector(loginIMHandle)]) {
                login = [account performSelector:@selector(loginIMHandle)];
            }
            NSString *loginID = nil;
            if (login && [login respondsToSelector:@selector(ID)]) {
                loginID = [login performSelector:@selector(ID)];
            }
            info[@"vetted_aliases"] = aliases ?: @[];
            info[@"login"] = loginID ?: @"";
            info[@"service"] = @"iMessage";
        }
    }
    return successResponse(requestId, info);
}

static NSDictionary *handleGetNicknameInfo(NSInteger requestId, NSDictionary *params) {
    NSString *address = params[@"address"];
    Class nnClass = NSClassFromString(@"IMNicknameController");
    if (!nnClass) return errorResponse(requestId, @"IMNicknameController unavailable");
    id ctrl = [nnClass performSelector:@selector(sharedController)];
    if (!ctrl) return errorResponse(requestId, @"controller nil");

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (address.length && [ctrl respondsToSelector:@selector(nicknameForHandle:)]) {
        id nickname = [ctrl performSelector:@selector(nicknameForHandle:) withObject:address];
        info[@"address"] = address;
        info[@"has_nickname"] = @(nickname != nil);
        if (nickname) {
            info[@"description"] = [nickname description] ?: @"";
        }
    }
    return successResponse(requestId, info);
}

static NSDictionary *handleCheckIMessageAvailability(NSInteger requestId, NSDictionary *params) {
    NSString *address = params[@"address"];
    NSString *aliasType = params[@"aliasType"] ?: @"phone";
    if (!address.length) return errorResponse(requestId, @"Missing address");
    Class q = NSClassFromString(@"IDSIDQueryController");
    if (!q) return errorResponse(requestId, @"IDSIDQueryController unavailable");
    id ctrl = [q performSelector:@selector(sharedController)];
    if (!ctrl) return errorResponse(requestId, @"controller nil");

    NSString *destination = address;
    if ([aliasType isEqualToString:@"phone"]) {
        if (![destination hasPrefix:@"tel:"]) destination = [@"tel:" stringByAppendingString:destination];
    } else if ([aliasType isEqualToString:@"email"]) {
        if (![destination hasPrefix:@"mailto:"]) destination = [@"mailto:" stringByAppendingString:destination];
    }

    NSInteger status = 0;
    @try {
        SEL sel = @selector(currentIDStatusForDestination:service:);
        if ([ctrl respondsToSelector:sel]) {
            id result = [ctrl performSelector:sel withObject:destination withObject:nil];
            if ([result isKindOfClass:[NSNumber class]]) {
                status = [(NSNumber *)result integerValue];
            }
        }
    } @catch (__unused NSException *ex) {}

    return successResponse(requestId, @{
        @"address": address,
        @"alias_type": aliasType,
        @"destination": destination,
        @"id_status": @(status),
        @"available": @(status == 1)
    });
}

static NSDictionary *handleDownloadPurgedAttachment(NSInteger requestId, NSDictionary *params) {
    NSString *attachmentGuid = params[@"attachmentGuid"];
    if (!attachmentGuid.length) return errorResponse(requestId, @"Missing attachmentGuid");
    Class ftcClass = NSClassFromString(@"IMFileTransferCenter");
    id ftc = ftcClass ? [ftcClass performSelector:@selector(sharedInstance)] : nil;
    if (!ftc) return errorResponse(requestId, @"FileTransferCenter unavailable");

    SEL sel = @selector(acceptTransfer:);
    if (![ftc respondsToSelector:sel]) {
        return errorResponse(requestId, @"acceptTransfer: not available");
    }
    @try {
        [ftc performSelector:sel withObject:attachmentGuid];
    } @catch (NSException *ex) { return errorResponse(requestId, ex.reason ?: @"failed"); }
    return successResponse(requestId, @{@"attachmentGuid": attachmentGuid, @"queued": @YES});
}

#pragma mark - Command Router

/// Dispatch an action by name, returning a legacy-envelope NSDictionary. Used
/// by both the v1 single-file IPC path and (after key-stripping) the v2 path.
static NSDictionary* dispatchAction(NSInteger legacyId, NSString *action,
                                    NSDictionary *params) {
    if ([action isEqualToString:@"typing"]) {
        return handleTyping(legacyId, params);
    } else if ([action isEqualToString:@"read"]) {
        return handleRead(legacyId, params);
    } else if ([action isEqualToString:@"status"] ||
               [action isEqualToString:@"bridge-status"]) {
        return handleStatus(legacyId, params);
    } else if ([action isEqualToString:@"list_chats"]) {
        return handleListChats(legacyId, params);
    } else if ([action isEqualToString:@"ping"]) {
        return successResponse(legacyId, @{@"pong": @YES});
    }
    // v2 actions
    if ([action isEqualToString:@"send-message"]) return handleSendMessage(legacyId, params);
    if ([action isEqualToString:@"send-multipart"]) return handleSendMultipart(legacyId, params);
    if ([action isEqualToString:@"send-attachment"]) return handleSendAttachment(legacyId, params);
    if ([action isEqualToString:@"send-reaction"]) return handleSendReaction(legacyId, params);
    if ([action isEqualToString:@"notify-anyways"]) return handleNotifyAnyways(legacyId, params);
    if ([action isEqualToString:@"edit-message"]) return handleEditMessage(legacyId, params);
    if ([action isEqualToString:@"unsend-message"]) return handleUnsendMessage(legacyId, params);
    if ([action isEqualToString:@"delete-message"]) return handleDeleteMessage(legacyId, params);
    if ([action isEqualToString:@"start-typing"]) return handleStartTyping(legacyId, params);
    if ([action isEqualToString:@"stop-typing"]) return handleStopTyping(legacyId, params);
    if ([action isEqualToString:@"check-typing-status"]) return handleCheckTypingStatus(legacyId, params);
    if ([action isEqualToString:@"mark-chat-read"]) return handleMarkChatRead(legacyId, params);
    if ([action isEqualToString:@"mark-chat-unread"]) return handleMarkChatUnread(legacyId, params);
    if ([action isEqualToString:@"add-participant"]) return handleAddParticipant(legacyId, params);
    if ([action isEqualToString:@"remove-participant"]) return handleRemoveParticipant(legacyId, params);
    if ([action isEqualToString:@"set-display-name"]) return handleSetDisplayName(legacyId, params);
    if ([action isEqualToString:@"update-group-photo"]) return handleUpdateGroupPhoto(legacyId, params);
    if ([action isEqualToString:@"leave-chat"]) return handleLeaveChat(legacyId, params);
    if ([action isEqualToString:@"delete-chat"]) return handleDeleteChat(legacyId, params);
    if ([action isEqualToString:@"create-chat"]) return handleCreateChat(legacyId, params);
    if ([action isEqualToString:@"search-messages"]) return handleSearchMessages(legacyId, params);
    if ([action isEqualToString:@"get-account-info"]) return handleGetAccountInfo(legacyId, params);
    if ([action isEqualToString:@"get-nickname-info"]) return handleGetNicknameInfo(legacyId, params);
    if ([action isEqualToString:@"check-imessage-availability"])
        return handleCheckIMessageAvailability(legacyId, params);
    if ([action isEqualToString:@"download-purged-attachment"])
        return handleDownloadPurgedAttachment(legacyId, params);
    return errorResponse(legacyId,
        [NSString stringWithFormat:@"Unknown action: %@", action]);
}

static NSDictionary* processCommand(NSDictionary *command) {
    NSNumber *requestIdNum = command[@"id"];
    NSInteger requestId = requestIdNum ? [requestIdNum integerValue] : 0;
    NSString *action = command[@"action"];
    NSDictionary *params = command[@"params"] ?: @{};

    NSLog(@"[imsg-bridge] Processing command: %@ (id=%ld)", action, (long)requestId);
    return dispatchAction(requestId, action, params);
}

/// Process a v2 envelope: re-route to the shared dispatcher, then strip the
/// legacy envelope keys and re-wrap with the v2 shape.
static NSDictionary* processV2Envelope(NSDictionary *envelope) {
    NSString *uuid = envelope[@"id"];
    if (![uuid isKindOfClass:[NSString class]]) uuid = @"";
    NSString *action = envelope[@"action"];
    NSDictionary *params = envelope[@"params"] ?: @{};
    if (![action isKindOfClass:[NSString class]] || action.length == 0) {
        return errorResponseV2(uuid, @"Missing action");
    }

    NSLog(@"[imsg-bridge v2] action=%@ id=%@", action, uuid);

    NSDictionary *legacy = dispatchAction(0, action, params);
    if (![legacy isKindOfClass:[NSDictionary class]]) {
        return errorResponseV2(uuid, @"Internal: handler returned non-dictionary");
    }

    BOOL ok = [legacy[@"success"] boolValue];
    if (!ok) {
        NSString *errMsg = legacy[@"error"];
        return errorResponseV2(uuid, errMsg ?: @"Unknown error");
    }

    NSMutableDictionary *data = [NSMutableDictionary dictionaryWithDictionary:legacy];
    [data removeObjectForKey:@"id"];
    [data removeObjectForKey:@"success"];
    [data removeObjectForKey:@"error"];
    [data removeObjectForKey:@"timestamp"];
    return successResponseV2(uuid, data);
}

#pragma mark - File-based IPC

static void processCommandFile(void) {
    @autoreleasepool {
        initFilePaths();

        NSError *error = nil;
        NSData *commandData = [NSData dataWithContentsOfFile:kCommandFile options:0 error:&error];
        if (!commandData || error) {
            return;
        }

        NSDictionary *command = [NSJSONSerialization JSONObjectWithData:commandData
                                                                options:0
                                                                  error:&error];
        if (error || ![command isKindOfClass:[NSDictionary class]]) {
            NSDictionary *response = errorResponse(0, @"Invalid JSON in command file");
            NSData *responseData = [NSJSONSerialization dataWithJSONObject:response
                                                                  options:NSJSONWritingPrettyPrinted
                                                                    error:nil];
            [responseData writeToFile:kResponseFile atomically:YES];
            return;
        }

        NSDictionary *result = processCommand(command);

        if (result != nil) {
            NSData *responseData = [NSJSONSerialization dataWithJSONObject:result
                                                                  options:NSJSONWritingPrettyPrinted
                                                                    error:nil];
            [responseData writeToFile:kResponseFile atomically:YES];

            // Clear command file to signal processing is complete
            [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

            NSLog(@"[imsg-bridge] Processed command, wrote response");
        }
    }
}

static void startFileWatcher(void) {
    initFilePaths();

    NSLog(@"[imsg-bridge] Starting file-based IPC");
    NSLog(@"[imsg-bridge] Command file: %@", kCommandFile);
    NSLog(@"[imsg-bridge] Response file: %@", kResponseFile);

    // Create/clear IPC files
    [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"" writeToFile:kResponseFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Create lock file with PID to indicate we're ready
    lockFd = open(kLockFile.UTF8String, O_CREAT | O_WRONLY, 0644);
    if (lockFd >= 0) {
        NSString *pidStr = [NSString stringWithFormat:@"%d", getpid()];
        write(lockFd, pidStr.UTF8String, pidStr.length);
    }

    // Poll command file via NSTimer on the main run loop.
    // NSTimer survives reliably in injected dylib contexts (dispatch_source timers
    // can get deallocated).
    __block NSDate *lastModified = nil;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        @autoreleasepool {
            NSDictionary *attrs = [[NSFileManager defaultManager]
                                   attributesOfItemAtPath:kCommandFile error:nil];
            NSDate *modDate = attrs[NSFileModificationDate];

            if (modDate && ![modDate isEqualToDate:lastModified]) {
                NSData *data = [NSData dataWithContentsOfFile:kCommandFile];
                if (data && data.length > 2) {
                    lastModified = modDate;
                    processCommandFile();
                }
            }
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    fileWatchTimer = timer;

    NSLog(@"[imsg-bridge] File watcher started, ready for commands");
}

#pragma mark - Inbound Event Observers

/// Register NSNotificationCenter observers that translate IMCore notifications
/// into JSON-lines events on `.imsg-events.jsonl`. These power
/// `imsg watch --bb-events` for live typing/alias-removal indicators.
static void registerEventObservers(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    // IMChatItemsDidChange: fires whenever a chat's item list shifts. We
    // inspect the userInfo to spot inserted IMTypingChatItem instances and
    // emit started-typing / stopped-typing events.
    [nc addObserverForName:@"IMChatItemsDidChangeNotification"
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        @autoreleasepool {
            id chat = note.object;
            NSString *chatGuid = nil;
            if (chat && [chat respondsToSelector:@selector(guid)]) {
                chatGuid = [chat performSelector:@selector(guid)];
            }
            NSDictionary *userInfo = note.userInfo;
            NSArray *inserted = userInfo[@"__kIMChatValueKey"]
                              ?: userInfo[@"inserted"];
            if (![inserted isKindOfClass:[NSArray class]]) return;
            for (id item in inserted) {
                NSString *cls = NSStringFromClass([item class]);
                if ([cls containsString:@"TypingChatItem"]) {
                    BOOL isCancel = NO;
                    if ([item respondsToSelector:@selector(isCancelTypingMessage)]) {
                        isCancel = ((BOOL (*)(id, SEL))objc_msgSend)(item,
                            @selector(isCancelTypingMessage));
                    }
                    appendEvent(@{
                        @"event": isCancel ? @"stopped-typing" : @"started-typing",
                        @"data": @{ @"chatGuid": chatGuid ?: @"" }
                    });
                }
            }
        }
    }];

    // Account aliases removed (e.g., user removed an iMessage email).
    [nc addObserverForName:@"__kIMAccountAliasesRemovedNotification"
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        appendEvent(@{
            @"event": @"aliases-removed",
            @"data": note.userInfo ?: @{}
        });
    }];

    NSLog(@"[imsg-bridge] Event observers registered");
}

#pragma mark - v2 Inbox Watcher

/// Process a single inbox file end-to-end: read, dispatch, write outbox,
/// remove inbox. Skips re-processed ids via processedRpcIds.
static void processV2InboxFile(NSString *uuid) {
    @autoreleasepool {
        if ([processedRpcIds containsObject:uuid]) {
            return;
        }
        [processedRpcIds addObject:uuid];

        NSString *inPath = [kRpcInDir stringByAppendingPathComponent:
            [uuid stringByAppendingPathExtension:@"json"]];
        NSString *outPath = [kRpcOutDir stringByAppendingPathComponent:
            [uuid stringByAppendingPathExtension:@"json"]];

        NSError *err = nil;
        NSData *body = [NSData dataWithContentsOfFile:inPath options:0 error:&err];
        if (!body || err) {
            NSLog(@"[imsg-bridge v2] Could not read %@: %@", inPath, err);
            // Remove malformed file so we don't retry forever.
            [[NSFileManager defaultManager] removeItemAtPath:inPath error:nil];
            return;
        }

        NSDictionary *envelope = [NSJSONSerialization JSONObjectWithData:body
                                                                 options:0
                                                                   error:&err];
        NSDictionary *response;
        if (!envelope || ![envelope isKindOfClass:[NSDictionary class]]) {
            response = errorResponseV2(uuid, @"Invalid JSON in request");
        } else {
            response = processV2Envelope(envelope);
        }

        NSData *responseData = [NSJSONSerialization dataWithJSONObject:response
                                                               options:0
                                                                 error:&err];
        if (responseData) {
            NSString *tmp = [outPath stringByAppendingPathExtension:@"tmp"];
            [responseData writeToFile:tmp atomically:NO];
            // Atomic rename so the CLI never reads a half-written file.
            rename(tmp.UTF8String, outPath.UTF8String);
        }

        // Drop the inbox request — we're done with it.
        [[NSFileManager defaultManager] removeItemAtPath:inPath error:nil];

        // Cap the dedupe set to prevent unbounded growth on long-lived dylibs.
        if (processedRpcIds.count > 1024) {
            [processedRpcIds removeAllObjects];
        }
    }
}

static void scanV2Inbox(void) {
    @autoreleasepool {
        NSError *err = nil;
        NSArray *entries = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:kRpcInDir error:&err];
        if (!entries) return;
        for (NSString *name in entries) {
            // Only consume finalized .json files; skip in-flight .tmp.
            if (![name hasSuffix:@".json"]) continue;
            NSString *uuid = [name stringByDeletingPathExtension];
            processV2InboxFile(uuid);
        }
    }
}

static void startV2InboxWatcher(void) {
    initFilePaths();

    // Ensure the queue dirs exist (CLI also pre-creates them, but be defensive
    // in case a v2-only run happened).
    [[NSFileManager defaultManager] createDirectoryAtPath:kRpcInDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:kRpcOutDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSLog(@"[imsg-bridge v2] Inbox: %@", kRpcInDir);
    NSLog(@"[imsg-bridge v2] Outbox: %@", kRpcOutDir);

    NSTimer *timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        scanV2Inbox();
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    rpcInboxTimer = timer;

    NSLog(@"[imsg-bridge v2] Inbox watcher started");
}

#pragma mark - Dylib Entry Point

__attribute__((constructor))
static void injectedInit(void) {
    NSLog(@"[imsg-bridge] Dylib injected into %@", [[NSProcessInfo processInfo] processName]);

    // Connect to IMDaemon for full IMCore access
    Class daemonClass = NSClassFromString(@"IMDaemonController");
    if (daemonClass) {
        id daemon = [daemonClass performSelector:@selector(sharedInstance)];
        if (daemon && [daemon respondsToSelector:@selector(connectToDaemon)]) {
            [daemon performSelector:@selector(connectToDaemon)];
            NSLog(@"[imsg-bridge] Connected to IMDaemon");
        } else {
            NSLog(@"[imsg-bridge] IMDaemonController available but couldn't connect");
        }
    } else {
        NSLog(@"[imsg-bridge] IMDaemonController class not found");
    }

    // Delay initialization to let Messages.app fully start
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSLog(@"[imsg-bridge] Initializing after delay...");

        // Log IMCore status
        Class registryClass = NSClassFromString(@"IMChatRegistry");
        if (registryClass) {
            id registry = [registryClass performSelector:@selector(sharedInstance)];
            if ([registry respondsToSelector:@selector(allExistingChats)]) {
                NSArray *chats = [registry performSelector:@selector(allExistingChats)];
                NSLog(@"[imsg-bridge] IMChatRegistry available with %lu chats",
                      (unsigned long)chats.count);
            }
        } else {
            NSLog(@"[imsg-bridge] IMChatRegistry NOT available");
        }

        probeSelectors();
        startFileWatcher();
        startV2InboxWatcher();
        registerEventObservers();
    });
}

__attribute__((destructor))
static void injectedCleanup(void) {
    NSLog(@"[imsg-bridge] Cleaning up...");

    if (fileWatchTimer) {
        [fileWatchTimer invalidate];
        fileWatchTimer = nil;
    }
    if (rpcInboxTimer) {
        [rpcInboxTimer invalidate];
        rpcInboxTimer = nil;
    }

    if (lockFd >= 0) {
        close(lockFd);
        lockFd = -1;
    }

    initFilePaths();
    [[NSFileManager defaultManager] removeItemAtPath:kLockFile error:nil];
}
