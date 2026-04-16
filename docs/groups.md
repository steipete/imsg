# Groups

## What counts as a group
- `chat.chat_identifier` or `chat.guid` contains `;+;` (for example
  `iMessage;+;chat1234567890`). That's what `IMsgCore.isGroupHandle(...)` checks.
- `SERVICE;-;TARGET` is a direct 1:1 chat (e.g. `iMessage;-;+15551234567`) and
  is deliberately **not** flagged as a group.
- Direct chats typically use a single handle (phone/email) with no `;+;`.

## Where the identifiers live
- `chat.ROWID` -> `chat_id` (stable within one DB).
- `chat.chat_identifier` -> group handle (used by Messages).
- `chat.guid` -> group GUID (often same chat handle semantics).
- `chat.display_name` -> group name (optional).
- Participants in `chat_handle_join` + `handle`.

## Sending to a group
- `imsg send --chat-id <rowid>` (preferred; DB local).
- `imsg send --chat-identifier <handle>` (portable).
- `imsg send --chat-guid <guid>` (portable).
- Uses AppleScript `chat id "<handle>"` for group sends (Jared pattern).
- Attachments supported same as direct sends.

## Inbound metadata (JSON)
Both the direct CLI (`imsg chats`, `imsg history`, `imsg watch`) `--json`
output and the JSON-RPC surface (`imsg rpc`) include:
- `chat_id`
- `chat_identifier`
- `chat_guid`
- `chat_name`
- `participants` (array of handles — see note below)
- `is_group`

`chat_id` is preferred for routing within one machine/DB.

### `participants` excludes the local user
`participants` is sourced from Messages.app's `chat_handle_join` table, which
only stores **external** handles. The local user ("me") is implicit: their
authorship is signaled by `is_from_me=1` on the message, not by a row in
`chat_handle_join`. A 3-person group chat where you are one of the members
reports only 2 handles in `participants`.

If a consumer needs the full roster, add the local user's handle on top. The
specific handle the user is routing through can be read from
`destination_caller_id` on any of their sent messages in the chat
(`is_from_me=1`) — useful when a Mac receives both iMessage and forwarded SMS
on different handles for the same Apple ID.

## Focused group lookup
- `imsg group --chat-id <rowid>` — prints id, identifier, guid, name, service,
  `is_group`, and participants for one chat. Works on direct chats too
  (`is_group: false` in that case). Supports `--json`.

## Notes
- Group send uses chat handle, not `buddy`.
- Messages from self may have empty `sender`; prefer `SenderName` + chat metadata.
