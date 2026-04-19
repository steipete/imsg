# 💬 imsg — Send, read, stream iMessage & SMS

A macOS Messages.app CLI to send, read, and stream iMessage/SMS (with attachment metadata). Read-only for receives; send uses AppleScript (no private APIs).

## Features
- List chats, view history, or stream new messages (`watch`).
- Send text and attachments via iMessage or SMS (AppleScript, no private APIs).
- Phone normalization to E.164 for reliable buddy lookup (`--region`, default US).
- Optional attachment metadata output (mime, name, path, missing flag).
- Filters: participants, start/end time, JSON output for tooling.
- Read-only DB access (`mode=ro`), no DB writes.
- Event-driven watch via filesystem events.

## Requirements
- macOS 14+ with Messages.app signed in.
- Full Disk Access for your terminal to read `~/Library/Messages/chat.db`.
- Automation permission for your terminal to control Messages.app (for sending).
- For SMS relay, enable “Text Message Forwarding” on your iPhone to this Mac.

## Install
```bash
make build
# binary at ./bin/imsg
```

## Commands
- `imsg chats [--limit 20] [--json]` — list recent conversations.
- `imsg history --chat-id <id> [--limit 50] [--attachments] [--resolve-replies] [--participants +15551234567,...] [--start 2025-01-01T00:00:00Z] [--end 2025-02-01T00:00:00Z] [--json]`
- `imsg watch [--chat-id <id>] [--since-rowid <n>] [--debounce 250ms] [--attachments] [--resolve-replies] [--participants …] [--start …] [--end …] [--json]`
- `imsg send --to <handle> [--text "hi"] [--file /path/img.jpg] [--service imessage|sms|auto] [--region US]`

### Quick samples
```
# list 5 chats
imsg chats --limit 5

# list chats as JSON
imsg chats --limit 5 --json

# last 10 messages in chat 1 with attachments
imsg history --chat-id 1 --limit 10 --attachments

# filter by date and emit JSON
imsg history --chat-id 1 --start 2025-01-01T00:00:00Z --json

# live stream a chat
imsg watch --chat-id 1 --attachments --debounce 250ms

# send a picture
imsg send --to "+14155551212" --text "hi" --file ~/Desktop/pic.jpg --service imessage
```

## Attachment notes
`--attachments` prints per-attachment lines with name, MIME, missing flag, and resolved path (tilde expanded). Only metadata is shown; files aren’t copied.

## JSON output
`imsg chats --json` emits one JSON object per chat with fields: `id`, `name`, `identifier`, `service`, `last_message_at`.
`imsg history --json` and `imsg watch --json` emit one JSON object per message with fields: `id`, `chat_id`, `guid`, `reply_to_guid`, `thread_originator_guid`, `destination_caller_id`, `sender`, `is_from_me`, `text`, `created_at`, `attachments` (array of metadata with `filename`, `transfer_name`, `uti`, `mime_type`, `total_bytes`, `is_sticker`, `original_path`, `missing`), `reactions`.

Note: `reply_to_guid`, `thread_originator_guid`, `destination_caller_id`, and `reactions` are read-only metadata.

## Resolving replies

When you pass `--resolve-replies` to `history` or `watch`, messages that are inline replies (`reply_to_guid`) or thread replies (`thread_originator_guid`) get the referenced message attached inline, resolved with a single bounded SQL lookup on the same read-only connection.

**JSON mode** adds two optional nested fields:

- `reply_to` — populated when `reply_to_guid` is present and the target is found. Object with `id`, `guid`, `sender`, `is_from_me`, `text`, `created_at`.
- `thread_originator` — populated when `thread_originator_guid` is present and distinct from `reply_to_guid`. Same shape as `reply_to`.

Existing `reply_to_guid` and `thread_originator_guid` remain in their original positions. If resolution fails (GUID not in the database), the corresponding nested field is omitted — the outer message is still emitted. The flag is opt-in, so consumers that don't pass it see no schema change.

**Text mode** prefixes an `↳ reply to <sender> #<id>: <excerpt>` or `↳ thread to <sender> #<id>: <excerpt>` line before the replying message, so agents reading `imsg watch` output don't have to infer reply context from adjacent message text.

```
↳ thread to parkertoddbrooks@me.com #7424: Yeah. And it's okay to not know.…
2026-04-18T18:18:00Z [recv] parkertoddbrooks@me.com: i didnt say Joerges…
```

This was added to unblock LLM agents that were reading `imsg watch` output and mistaking quoted reply context for the user's new message (e.g. duplicate-display loops when an agent's own prior message was threaded to).

## Permissions troubleshooting
If you see “unable to open database file” or empty output:
1) Grant Full Disk Access: System Settings → Privacy & Security → Full Disk Access → add your terminal.
2) Ensure Messages.app is signed in and `~/Library/Messages/chat.db` exists.
3) For send, allow the terminal under System Settings → Privacy & Security → Automation → Messages.

## Testing
```bash
make test
```

Note: `make test` applies a small patch to SQLite.swift to silence a SwiftPM warning about `PrivacyInfo.xcprivacy`.

## Linting & formatting
```bash
make lint
make format
```

## Core library
The reusable Swift core lives in `Sources/IMsgCore` and is consumed by the CLI target. Apps can depend on the `IMsgCore` library target directly.
