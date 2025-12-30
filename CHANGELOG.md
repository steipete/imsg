# Changelog

## Unreleased
- fix: avoid crash parsing long attributed bodies (>256 bytes)

## 0.2.0 - 2025-12-28
- feat: Swift 6 rewrite with reusable IMsgCore library target
- feat: Commander-based CLI with SwiftPM build/test workflow
- feat: event-driven watch using filesystem events (no polling)
- feat: SQLite.swift + PhoneNumberKit + NSAppleScript integration
- fix: ship PhoneNumberKit resource bundle for CLI installs
- fix: embed Info.plist + AppleEvents entitlement for automation prompts
- fix: fall back to osascript when AppleEvents permission is missing
- fix: decode length-prefixed attributed bodies for sent messages
- chore: SwiftLint + swift-format linting
- change: JSON attachment keys now snake_case
- deprecation note: `--interval` replaced by `--debounce` (no compatibility)
- chore: version.env + generated version source for `--version`

## 0.1.1 - 2025-12-27
- feat: `imsg chats --json`
- fix: drop sqlite `immutable` flag so new messages/replies show up (thanks @zleman1593)
- chore: update go dependencies

## 0.1.0 - 2025-12-20
- feat: `imsg chats` list recent conversations
- feat: `imsg history` with filters (`--participants`, `--start`, `--end`) + `--json`
- feat: `imsg watch` polling stream (`--interval`, `--since-rowid`) + filters + `--json`
- feat: `imsg send` text and/or one attachment (`--service imessage|sms|auto`, `--region`)
- feat: attachment metadata output (`--attachments`) incl. resolved path + missing flag
- fix: clearer Full Disk Access error for `~/Library/Messages/chat.db`
