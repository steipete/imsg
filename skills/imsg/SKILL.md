---
name: imsg
description: Send, read, and monitor iMessage/SMS from the command line on macOS. Use when the user wants to send text messages, read conversations, check message history, or monitor incoming messages.
---

# iMessage CLI (imsg)

A command-line tool for interacting with Apple Messages on macOS.

## Prerequisites

- macOS 14+ with Messages.app signed in
- Terminal must have Full Disk Access (System Settings → Privacy & Security → Full Disk Access)
- Terminal must have Automation permission to control Messages.app (prompted on first send)

## Always Use JSON Output

For programmatic use, **always** add `--json` to commands for machine-readable output:

```bash
imsg chats --json
imsg history --chat-id 1 --json
```

## Commands

### List Conversations

```bash
# List recent chats
imsg chats --limit 10 --json
```

Output includes `id` (chat rowid), `displayName`, `participants`, `lastMessage`, and `lastMessageDate`.

### Read Message History

```bash
# By chat ID (from chats command)
imsg history --chat-id 1 --limit 20 --json

# With attachments metadata
imsg history --chat-id 1 --attachments --json

# Filter by participant
imsg history --chat-id 1 --participants "+15551234567" --json

# Filter by date range (ISO8601)
imsg history --chat-id 1 --start "2025-01-01T00:00:00Z" --end "2025-01-02T00:00:00Z" --json
```

### Send Messages

```bash
# Send to phone number (E.164 format preferred)
imsg send --to "+14155551212" --text "Hello!"

# Send with attachment
imsg send --to "+14155551212" --text "Check this out" --file ~/Desktop/photo.jpg

# Reply to existing chat by ID
imsg send --chat-id 1 --text "Following up..."

# Force specific service
imsg send --to "+14155551212" --text "Hi" --service imessage
imsg send --to "+14155551212" --text "Hi" --service sms
```

**Phone number format**: Use E.164 format (`+1XXXXXXXXXX`) for reliability. The tool normalizes numbers automatically.

### Watch for New Messages

```bash
# Stream all incoming messages
imsg watch --json

# Watch specific chat
imsg watch --chat-id 1 --json

# With attachments and custom debounce
imsg watch --chat-id 1 --attachments --debounce 250ms --json

# Start from specific message rowid
imsg watch --since-rowid 12345 --json
```

The watch command runs continuously and outputs JSON objects for each new message.

## Common Workflows

### Find and Reply to a Conversation

```bash
# 1. List recent chats to find the chat ID
imsg chats --limit 10 --json

# 2. Read recent messages from that chat
imsg history --chat-id <ID> --limit 10 --json

# 3. Send a reply
imsg send --chat-id <ID> --text "Your message here"
```

### Send a Message to a New Contact

```bash
# Use phone number directly (will create new chat if needed)
imsg send --to "+14155551212" --text "Hello, this is a new message"
```

### Monitor Messages in Background

```bash
# Run watch in background, capture to file
imsg watch --json > ~/messages.jsonl &
```

## Error Handling

- If sending fails, check that Messages.app is signed in and running
- If reading fails with permission error, grant Full Disk Access to your terminal
- Phone numbers should be in E.164 format; tool attempts normalization but explicit format is safest

## JSON Output Structure

### Chat object
```json
{
  "id": 1,
  "guid": "iMessage;-;+14155551212",
  "displayName": "John Doe",
  "participants": ["+14155551212"],
  "lastMessage": "See you tomorrow",
  "lastMessageDate": "2025-01-04T10:30:00Z"
}
```

### Message object
```json
{
  "id": 12345,
  "chatId": 1,
  "text": "Hello!",
  "isFromMe": false,
  "date": "2025-01-04T10:30:00Z",
  "sender": "+14155551212",
  "attachments": []
}
```
