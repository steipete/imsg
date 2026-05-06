# imsg

`imsg` is a macOS command-line tool for Messages.app. It reads your local
Messages database, streams new iMessage/SMS rows, sends messages through
Messages.app automation, and exposes the same surfaces over JSON and JSON-RPC.

Most read workflows need only Full Disk Access. Sending and standard tapbacks
also need macOS Automation permission for Messages.app. Advanced IMCore features
such as read receipts, typing indicators, and injection status are opt-in and
are increasingly limited by macOS 26.

## Highlights

- Read recent chats and message history without modifying `chat.db`.
- Stream new messages with `watch`, including a fallback poll when macOS misses
  file events.
- Send text and files through Messages.app AppleScript, without private send
  APIs.
- Inspect direct chats and groups, including participants, GUIDs, service, and
  account routing hints.
- Emit newline-delimited JSON for automation, agents, and scripts.
- Resolve Contacts names when permission is granted, while keeping raw handles
  in the output.
- Report attachment metadata, and optionally expose model-compatible converted
  receive-side CAF/GIF files.
- Use JSON-RPC over stdio for long-running integrations.

## Requirements

- macOS 14 or newer.
- Messages.app signed in to iMessage and/or SMS relay.
- Full Disk Access for the terminal or parent app that launches `imsg`.
- Automation permission for Messages.app when using `send` or `react`.
- Optional Contacts permission for name resolution.
- Optional `ffmpeg` on `PATH` for receive-side attachment conversion.

For SMS, enable Text Message Forwarding on your iPhone for this Mac.

## Install

```bash
brew install steipete/tap/imsg
```

Build from source:

```bash
make build
./bin/imsg --help
```

## Common Workflows

List recent chats:

```bash
imsg chats --limit 10
imsg chats --limit 10 --json
```

Inspect one chat before sending or wiring automation:

```bash
imsg group --chat-id 42 --json
```

Read history:

```bash
imsg history --chat-id 42 --limit 20
imsg history --chat-id 42 --limit 20 --attachments --json
imsg history --chat-id 42 --start 2026-05-01T00:00:00Z --end 2026-05-06T00:00:00Z --json
```

Stream new messages:

```bash
imsg watch --chat-id 42 --json
imsg watch --chat-id 42 --since-rowid 9000 --attachments --reactions --debounce 250ms --json
```

Send a message or file:

```bash
imsg send --to "+14155551212" --text "hi" --service imessage
imsg send --to "Jane Appleseed" --text "voice note" --file ~/Desktop/voice.m4a
imsg send --chat-id 42 --text "same thread"
```

Send a standard tapback:

```bash
imsg react --chat-id 42 --reaction like
```

Generate integration help:

```bash
imsg completions zsh
imsg completions llm
```

## Commands

- `imsg chats [--limit 20] [--json]`
- `imsg group --chat-id <id> [--json]`
- `imsg history --chat-id <id> [--limit 50] [--attachments] [--convert-attachments] [--participants <handles>] [--start <iso>] [--end <iso>] [--json]`
- `imsg watch [--chat-id <id>] [--since-rowid <id>] [--debounce <duration>] [--attachments] [--convert-attachments] [--reactions] [--participants <handles>] [--start <iso>] [--end <iso>] [--json]`
- `imsg send (--to <handle-or-contact-name> | --chat-id <id> | --chat-identifier <id> | --chat-guid <guid>) [--text <text>] [--file <path>] [--service imessage|sms|auto] [--region US] [--json]`
- `imsg react --chat-id <id> --reaction love|like|dislike|laugh|emphasis|question`
- `imsg read --to <handle> [--chat-id <id> | --chat-identifier <id> | --chat-guid <guid>]`
- `imsg typing --to <handle> [--duration 5s] [--stop true] [--service imessage|sms|auto]`
- `imsg status [--json]`
- `imsg launch [--dylib <path>] [--kill-only] [--json]`
- `imsg rpc`
- `imsg completions bash|zsh|fish|llm`

`react` intentionally sends only the standard tapbacks that Messages.app exposes
reliably through automation. Custom emoji tapbacks can be read from
history/watch output, but are not sent by the CLI.

## JSON Output

`--json` emits one JSON object per line, so consumers can stream it directly or
collect it with `jq -s`.

Chat objects include:

- `id`, `name`, `identifier`, `guid`, `service`, `last_message_at`
- `display_name`, `contact_name`
- `is_group`, `participants`
- `account_id`, `account_login`, `last_addressed_handle`

Message objects include:

- `id`, `chat_id`, `chat_identifier`, `chat_guid`, `chat_name`
- `participants`, `is_group`
- `guid`, `reply_to_guid`, `destination_caller_id`
- `sender`, `sender_name`, `is_from_me`, `text`, `created_at`
- `attachments`, `reactions`

When `watch --reactions --json` sees a tapback event, the message object also
includes `is_reaction`, `reaction_type`, `reaction_emoji`, `is_reaction_add`,
and `reacted_to_guid`.

Routing fields such as `destination_caller_id`, `account_id`,
`account_login`, and `last_addressed_handle` are read-only diagnostics from
Messages. AppleScript does not expose a way for `imsg send` to force a specific
outgoing Apple ID phone number or inline reply target.

## JSON-RPC

`imsg rpc` speaks JSON-RPC 2.0 over stdin/stdout, one JSON object per line. It
is intended for agents and long-running integrations that want a single process
for chats, history, send, and watch.

Read methods:

- `chats.list`
- `messages.history`
- `watch.subscribe`
- `watch.unsubscribe`

Mutating method:

- `send`

See [docs/rpc.md](docs/rpc.md) for request and response shapes.

## Attachments

`--attachments` reports metadata only. It does not copy or upload files.

Attachment metadata includes filename, transfer name, UTI, MIME type, byte
count, sticker flag, missing flag, and resolved original path.

`--convert-attachments` can expose cached, model-compatible receive-side
variants:

- CAF audio -> M4A
- GIF image -> first-frame PNG

Conversion requires `ffmpeg` on `PATH`. Original Messages attachments are left
unchanged. Converted metadata is reported with `converted_path` and
`converted_mime_type`.

`send --file` sends regular files, including audio files, through Messages.app.
Before handing the file to Messages, `imsg` stages it under
`~/Library/Messages/Attachments/imsg/` so Messages can read it reliably.

## Watch Behavior

`imsg watch` starts at the newest message by default and streams messages written
after it starts. Use `--since-rowid <id>` to resume from a stored cursor.

The watcher listens for filesystem events on `chat.db`, `chat.db-wal`, and
`chat.db-shm`, then backs that up with a lightweight poll. The poll keeps
streams alive when macOS drops file events or rotates SQLite sidecar files.

RPC watch defaults to a 500ms debounce to reduce outbound echo races. CLI watch
can be tuned with `--debounce`.

## Permissions Troubleshooting

If reads fail with `unable to open database file`, empty output, or
`authorization denied`:

1. Open System Settings -> Privacy & Security -> Full Disk Access.
2. Add the terminal or parent app that launches `imsg`.
3. If launched from an editor, Node process, gateway, or shell wrapper, grant
   Full Disk Access to that parent app too.
4. Also add the built-in Terminal.app at
   `/System/Applications/Utilities/Terminal.app`; macOS can still consult the
   default terminal grant.
5. Toggle stale Full Disk Access entries off and on after terminal, Homebrew,
   Node, or app updates.
6. Confirm Messages.app is signed in and `~/Library/Messages/chat.db` exists.

For sends and tapbacks, allow the terminal or parent app under Privacy &
Security -> Automation -> Messages.

`imsg` opens `chat.db` read-only. It does not use SQLite `immutable=1` by
default because immutable reads can miss WAL-backed Messages updates.

## Advanced IMCore Features

Default `send`, `chats`, `history`, `watch`, and read-only `rpc` workflows do
not require IMCore injection.

Advanced features such as `read`, `typing`, `launch`, bridge-backed rich send,
message mutation, and chat management are opt-in. They require SIP to be
disabled and a helper dylib to be injected into Messages.app:

```bash
make build-dylib
imsg launch
imsg status
```

Important limits:

- `imsg launch` refuses to inject when SIP is enabled.
- `imsg status` is read-only and does not auto-launch or auto-inject.
- macOS 26/Tahoe can block injection through library validation.
- macOS 26/Tahoe can also reject direct IMCore clients through `imagent`
  private-entitlement checks.
- These limits affect advanced IMCore features such as typing indicators, not
  normal send/history/watch usage.

To revert after testing advanced features, re-enable SIP from Recovery mode with
`csrutil enable`.

### Bridge command surface

The bridge implements a manual port of the BlueBubbles private-API surface
inspired by their Apache-2.0 helper, into our own dylib (no third-party
binary). Commands in this section require `imsg launch` first, which means
SIP-disabled DYLD injection into Messages.app. Most commands take a `--chat`
argument that is the chat guid (e.g. `iMessage;-;+15551234567` or
`iMessage;+;chat0000` for groups). Get a chat guid via `imsg chats --json`.

Messaging:
```bash
# Rich send with effect + reply
imsg send-rich --chat 'iMessage;-;+15551234567' --text "boom" \
  --effect com.apple.MobileSMS.expressivesend.impact \
  --reply-to <messageGuid>

# Text formatting (macOS 15+ Sequoia only): bold/italic/underline/strikethrough
# applied to specific ranges of the message body.
imsg send-rich --chat ... --text 'hello world' \
  --format '[{"start":0,"length":5,"styles":["bold"]},
             {"start":6,"length":5,"styles":["italic","underline"]}]'

# Or load the ranges from a file
imsg send-rich --chat ... --text "$(cat msg.txt)" --format-file ranges.json

# Multipart send (text-only in v1; per-part textFormatting also supported)
imsg send-multipart --chat 'iMessage;+;chat0000' \
  --parts '[{"text":"hi"},
            {"text":"there","textFormatting":[{"start":0,"length":5,"styles":["bold"]}]}]'

# Attachment (file or audio)
imsg send-attachment --chat ... --file ~/Pictures/img.jpg
imsg send-attachment --chat ... --file ~/audio.caf --audio

# Tapback (bridge-backed; `imsg react` remains the AppleScript variant)
imsg tapback --chat ... --message <guid> --kind love
imsg tapback --chat ... --message <guid> --kind love --remove
```

Mutate (macOS 13+ — selector availability surfaced in `imsg status`):
```bash
imsg edit --chat ... --message <guid> --new-text "actually..."
imsg unsend --chat ... --message <guid>
imsg delete-message --chat ... --message <guid>
imsg notify-anyways --chat ... --message <guid>
```

Chat management:
```bash
imsg chat-create --addresses '+15551111111,+15552222222' --name 'Crew' --text 'gm'
imsg chat-name --chat ... --name 'Renamed'
imsg chat-photo --chat ... --file ~/Downloads/g.jpg     # set
imsg chat-photo --chat ...                              # clear
imsg chat-add-member --chat ... --address +15553333333
imsg chat-remove-member --chat ... --address +15553333333
imsg chat-leave --chat ...
imsg chat-delete --chat ...
imsg chat-mark --chat ... --read     # or --unread
```
`chat-create` currently creates iMessage chats only. SMS sending remains
available through `imsg send --service sms`.

Introspection:
```bash
imsg account                                            # active iMessage account + aliases
imsg whois --address +15551234567 --type phone
imsg whois --address foo@bar.com --type email
imsg nickname --address +15551234567
```

Local history search (does not require the bridge):
```bash
imsg search --query "pizza" --match contains
```

Live events (typing indicators surfaced through the dylib):
```bash
imsg watch --bb-events                                  # merge dylib events into stdout
imsg watch --bb-events --json                           # one JSON object per event
```

### v2 IPC under the hood

The dylib v1 used a single overwriting `.imsg-command.json` polled at 100ms,
which races when multiple CLI invocations run concurrently. v2 uses a
per-request UUID-keyed queue:

```
~/Library/Containers/com.apple.MobileSMS/Data/
  .imsg-bridge-ready          PID lock — set when injection is live
  .imsg-rpc/in/<uuid>.json    requests dropped here by the CLI (atomic rename)
  .imsg-rpc/out/<uuid>.json   responses written by the dylib (atomic rename)
  .imsg-events.jsonl          inbound async events (typing, alias-removed)
```

Set `IMSG_BRIDGE_LEGACY_IPC=1` to force the legacy single-file path for
debugging (existing v1 callers / un-rebuilt dylibs continue to work without
this).

## Development

```bash
make lint
make test
make build
```

`make test` applies the repository's SQLite.swift patch before running Swift
tests.

The reusable Swift core lives in `Sources/IMsgCore`; the CLI target lives in
`Sources/imsg`.
