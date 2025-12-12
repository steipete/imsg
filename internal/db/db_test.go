package db

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func appleFromTime(t time.Time) int64 {
	return t.Add(-time.Duration(AppleEpochOffset) * time.Second).UnixNano()
}

func newTestDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", "file:imsgtest?mode=memory&cache=shared")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	stmts := []string{
		`CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT, service_name TEXT);`,
		`CREATE TABLE message (ROWID INTEGER PRIMARY KEY, handle_id INTEGER, text TEXT, date INTEGER, is_from_me INTEGER, service TEXT);`,
		`CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);`,
		`CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);`,
		`CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, filename TEXT, transfer_name TEXT, uti TEXT, mime_type TEXT, total_bytes INTEGER, is_sticker INTEGER);`,
		`CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);`,
	}
	for _, s := range stmts {
		if _, err := db.Exec(s); err != nil {
			t.Fatalf("exec %s: %v", s, err)
		}
	}

	now := time.Now().UTC()
	// sample data
	_, _ = db.Exec(`INSERT INTO chat(ROWID, chat_identifier, display_name, service_name) VALUES (1, '+123', 'Test Chat', 'iMessage')`)
	_, _ = db.Exec(`INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, 'Me')`)

	msgs := []struct {
		id      int
		handle  int
		text    string
		fromMe  bool
		date    time.Time
		attachs int
	}{
		{1, 1, "hello", false, now.Add(-10 * time.Minute), 0},
		{2, 2, "hi back", true, now.Add(-9 * time.Minute), 1},
		{3, 1, "photo", false, now.Add(-1 * time.Minute), 0},
	}
	for _, m := range msgs {
		if _, err := db.Exec(`INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service) VALUES (?,?,?,?,?,?)`, m.id, m.handle, m.text, appleFromTime(m.date), boolToInt(m.fromMe), "iMessage"); err != nil {
			t.Fatalf("insert message: %v", err)
		}
		if _, err := db.Exec(`INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)`, m.id); err != nil {
			t.Fatalf("insert cmj: %v", err)
		}
		for i := 0; i < m.attachs; i++ {
			_, _ = db.Exec(`INSERT INTO attachment(ROWID, filename, transfer_name, uti, mime_type, total_bytes, is_sticker) VALUES (?,?,?, ?, ?, ?, ?)`, i+1, "~/Library/Messages/Attachments/test.dat", "test.dat", "public.data", "application/octet-stream", 123, 0)
			_, _ = db.Exec(`INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (?, ?)`, m.id, i+1)
		}
	}
	return db
}

func newTestDBWithBody(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", "file:imsgtestbody?mode=memory&cache=shared")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	stmts := []string{
		`CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT, service_name TEXT);`,
		`CREATE TABLE message (ROWID INTEGER PRIMARY KEY, handle_id INTEGER, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER, service TEXT);`,
		`CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);`,
		`CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);`,
		`CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, filename TEXT, transfer_name TEXT, uti TEXT, mime_type TEXT, total_bytes INTEGER, is_sticker INTEGER);`,
		`CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);`,
	}
	for _, s := range stmts {
		if _, err := db.Exec(s); err != nil {
			t.Fatalf("exec %s: %v", s, err)
		}
	}

	now := time.Now().UTC()
	_, _ = db.Exec(`INSERT INTO chat(ROWID, chat_identifier, display_name, service_name) VALUES (1, '+123', 'Test Chat', 'iMessage')`)
	_, _ = db.Exec(`INSERT INTO handle(ROWID, id) VALUES (1, '+123')`)

	body := bodyBlob("fallback text")
	if _, err := db.Exec(`INSERT INTO message(ROWID, handle_id, text, attributedBody, date, is_from_me, service) VALUES (?,?,?,?,?,?,?)`, 1, 1, nil, body, appleFromTime(now), 0, "iMessage"); err != nil {
		t.Fatalf("insert message: %v", err)
	}
	_, _ = db.Exec(`INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)`)
	return db
}

func newTempDiskDB(t *testing.T) (string, func()) {
	t.Helper()
	f, err := os.CreateTemp("", "imsg-disk-*.db")
	if err != nil {
		t.Fatalf("CreateTemp: %v", err)
	}
	path := f.Name()
	_ = f.Close()
	cleanup := func() { _ = os.Remove(path) }
	return path, cleanup
}

func bodyBlob(s string) []byte {

	return append(append([]byte{0x01, 0x2b}, []byte(s)...), 0x86, 0x84)
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func TestOpenSeesLiveUpdates(t *testing.T) {
	ctx := context.Background()
	path, cleanup := newTempDiskDB(t)
	defer cleanup()

	writer, err := sql.Open("sqlite", fmt.Sprintf("file:%s?_pragma=busy_timeout(5000)&mode=rwc", filepath.Clean(path)))
	if err != nil {
		t.Fatalf("open writer: %v", err)
	}
	defer func() { _ = writer.Close() }()

	if _, err := writer.Exec(`CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT)`); err != nil {
		t.Fatalf("create table: %v", err)
	}
	if _, err := writer.Exec(`INSERT INTO message(text) VALUES ('first')`); err != nil {
		t.Fatalf("insert first: %v", err)
	}

	reader, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = reader.Close() }()

	count := func(db *sql.DB) int {
		var c int
		if err := db.QueryRowContext(ctx, "SELECT COUNT(*) FROM message").Scan(&c); err != nil {
			t.Fatalf("count: %v", err)
		}
		return c
	}

	if got := count(reader); got != 1 {
		t.Fatalf("expected initial count 1, got %d", got)
	}

	if _, err := writer.Exec(`INSERT INTO message(text) VALUES ('second')`); err != nil {
		t.Fatalf("insert second: %v", err)
	}

	if got := count(reader); got != 2 {
		t.Fatalf("expected reader to see new rows, got %d", got)
	}
}

func TestListChats(t *testing.T) {
	ctx := context.Background()
	store := newTestDB(t)
	defer func() { _ = store.Close() }()

	chats, err := ListChats(ctx, store, 5)
	if err != nil {
		t.Fatalf("ListChats: %v", err)
	}
	if len(chats) != 1 {
		t.Fatalf("expected 1 chat, got %d", len(chats))
	}
	if chats[0].Identifier != "+123" {
		t.Fatalf("unexpected identifier %s", chats[0].Identifier)
	}
}

func TestMessagesByChat(t *testing.T) {
	ctx := context.Background()
	store := newTestDB(t)
	defer func() { _ = store.Close() }()

	msgs, err := MessagesByChat(ctx, store, 1, 10)
	if err != nil {
		t.Fatalf("MessagesByChat: %v", err)
	}
	if len(msgs) != 3 {
		t.Fatalf("expected 3 messages, got %d", len(msgs))
	}
	if msgs[0].Attachments != 0 {
		t.Fatalf("expected newest message attachments 0, got %d", msgs[0].Attachments)
	}
	if !msgs[1].IsFromMe {
		t.Fatalf("expected second message from me")
	}
}

func TestMessagesAfter(t *testing.T) {
	ctx := context.Background()
	store := newTestDB(t)
	defer func() { _ = store.Close() }()

	msgs, err := MessagesAfter(ctx, store, 1, 0, 10)
	if err != nil {
		t.Fatalf("MessagesAfter: %v", err)
	}
	if len(msgs) != 2 {
		t.Fatalf("expected 2 messages after rowid 1, got %d", len(msgs))
	}
	if msgs[0].RowID != 2 {
		t.Fatalf("expected first rowid 2, got %d", msgs[0].RowID)
	}
}

func TestMessagesByChatUsesAttributedBodyFallback(t *testing.T) {
	ctx := context.Background()
	store := newTestDBWithBody(t)
	defer func() { _ = store.Close() }()

	msgs, err := MessagesByChat(ctx, store, 1, 10)
	if err != nil {
		t.Fatalf("MessagesByChat fallback: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}
	if msgs[0].Text != "fallback text" {
		t.Fatalf("expected fallback text, got %q", msgs[0].Text)
	}
}

func TestMessagesAfterUsesAttributedBodyFallback(t *testing.T) {
	ctx := context.Background()
	store := newTestDBWithBody(t)
	defer func() { _ = store.Close() }()

	msgs, err := MessagesAfter(ctx, store, 0, 0, 10)
	if err != nil {
		t.Fatalf("MessagesAfter fallback: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}
	if msgs[0].Text != "fallback text" {
		t.Fatalf("expected fallback text, got %q", msgs[0].Text)
	}
}

func TestParseStreamTypedTrimsControls(t *testing.T) {
	blob := []byte{0x00, 0x01, 0x2b, '\n', 'H', 'i', 0x86, 0x84, '\r'}
	got := parseStreamTyped(blob)
	if got != "Hi" {
		t.Fatalf("expected Hi, got %q", got)
	}
}

func TestAttachmentsByMessage(t *testing.T) {
	ctx := context.Background()
	store := newTestDB(t)
	defer func() { _ = store.Close() }()

	metas, err := AttachmentsByMessage(ctx, store, 2)
	if err != nil {
		t.Fatalf("AttachmentsByMessage: %v", err)
	}
	if len(metas) != 1 {
		t.Fatalf("expected 1 attachment, got %d", len(metas))
	}
	if metas[0].MimeType != "application/octet-stream" {
		t.Fatalf("unexpected mime %s", metas[0].MimeType)
	}
}
