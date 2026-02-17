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
#import <unistd.h>

#pragma mark - Constants

static NSString *kCommandFile = nil;
static NSString *kResponseFile = nil;
static NSString *kLockFile = nil;
static NSTimer *fileWatchTimer = nil;
static int lockFd = -1;

static void initFilePaths(void) {
    if (kCommandFile == nil) {
        // Messages.app runs in a container; NSHomeDirectory() resolves to
        // ~/Library/Containers/com.apple.MobileSMS/Data inside the sandbox.
        NSString *containerPath = NSHomeDirectory();
        kCommandFile = [containerPath stringByAppendingPathComponent:@".imsg-command.json"];
        kResponseFile = [containerPath stringByAppendingPathComponent:@".imsg-response.json"];
        kLockFile = [containerPath stringByAppendingPathComponent:@".imsg-bridge-ready"];
    }
}

#pragma mark - Forward Declarations for IMCore Classes

@interface IMChatRegistry : NSObject
+ (instancetype)sharedInstance;
- (id)existingChatWithGUID:(NSString *)guid;
- (id)existingChatWithChatIdentifier:(NSString *)identifier;
- (NSArray *)allExistingChats;
@end

@interface IMChat : NSObject
- (void)setLocalUserIsTyping:(BOOL)typing;
- (void)markAllMessagesAsRead;
- (NSArray *)participants;
- (NSString *)guid;
- (NSString *)chatIdentifier;
@end

@interface IMHandle : NSObject
- (NSString *)ID;
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
        NSArray *prefixes = @[@"iMessage;-;", @"iMessage;+;", @"SMS;-;", @"SMS;+;", @"any;-;", @"any;+;"];
        for (NSString *prefix in prefixes) {
            NSString *fullGUID = [prefix stringByAppendingString:identifier];
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
        if ([identifier hasPrefix:@"+"] || [identifier hasPrefix:@"1"] ||
            [[NSCharacterSet decimalDigitCharacterSet]
             characterIsMember:[identifier characterAtIndex:0]]) {
            NSMutableString *digits = [NSMutableString string];
            for (NSUInteger i = 0; i < identifier.length; i++) {
                unichar c = [identifier characterAtIndex:i];
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
                if ([chatGUID isEqualToString:identifier]) {
                    NSLog(@"[imsg-bridge] Found chat by GUID exact match: %@", chatGUID);
                    return aChat;
                }
            }

            // Check chatIdentifier
            if ([aChat respondsToSelector:@selector(chatIdentifier)]) {
                NSString *chatId = [aChat performSelector:@selector(chatIdentifier)];
                if ([chatId isEqualToString:identifier]) {
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
                        if ([handleID isEqualToString:identifier]) {
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

    return successResponse(requestId, @{
        @"injected": @YES,
        @"registry_available": @(hasRegistry),
        @"chat_count": @(chatCount),
        @"typing_available": @(hasRegistry),
        @"read_available": @(hasRegistry)
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

#pragma mark - Command Router

static NSDictionary* processCommand(NSDictionary *command) {
    NSNumber *requestIdNum = command[@"id"];
    NSInteger requestId = requestIdNum ? [requestIdNum integerValue] : 0;
    NSString *action = command[@"action"];
    NSDictionary *params = command[@"params"] ?: @{};

    NSLog(@"[imsg-bridge] Processing command: %@ (id=%ld)", action, (long)requestId);

    if ([action isEqualToString:@"typing"]) {
        return handleTyping(requestId, params);
    } else if ([action isEqualToString:@"read"]) {
        return handleRead(requestId, params);
    } else if ([action isEqualToString:@"status"]) {
        return handleStatus(requestId, params);
    } else if ([action isEqualToString:@"list_chats"]) {
        return handleListChats(requestId, params);
    } else if ([action isEqualToString:@"ping"]) {
        return successResponse(requestId, @{@"pong": @YES});
    } else {
        return errorResponse(requestId,
            [NSString stringWithFormat:@"Unknown action: %@", action]);
    }
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

        startFileWatcher();
    });
}

__attribute__((destructor))
static void injectedCleanup(void) {
    NSLog(@"[imsg-bridge] Cleaning up...");

    if (fileWatchTimer) {
        [fileWatchTimer invalidate];
        fileWatchTimer = nil;
    }

    if (lockFd >= 0) {
        close(lockFd);
        lockFd = -1;
    }

    initFilePaths();
    [[NSFileManager defaultManager] removeItemAtPath:kLockFile error:nil];
}
