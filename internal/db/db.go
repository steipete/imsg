// Package db provides read-only access to the macOS Messages SQLite store.
package db

import (
	"bytes"
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	// modernc sqlite provides a pure-Go sqlite driver for CI/macOS without CGO.
	_ "modernc.org/sqlite"
)

// AppleEpochOffset is the number of seconds between 1970-01-01 and 2001-01-01.
const AppleEpochOffset = 978307200

// Chat represents a conversation.
type Chat struct {
	ID            int64
	Identifier    string
	Name          string
	Service       string
	LastMessageAt time.Time
}

// Message represents a single message row.
type Message struct {
	RowID       int64
	ChatID      int64
	Sender      string
	Text        string
	Date        time.Time
	IsFromMe    bool
	Service     string
	HandleID    sql.NullInt64
	Attachments int
}

// AttachmentMeta represents attachment metadata for a message.
type AttachmentMeta struct {
	Filename     string
	TransferName string
	UTI          string
	MimeType     string
	TotalBytes   int64
	IsSticker    bool
	OriginalPath string
	Missing      bool
}

// DefaultPath returns the default location of chat.db for the current user.
func DefaultPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Messages", "chat.db")
}

// Open opens chat.db read-only with sensible pragmas for concurrent access.
func Open(ctx context.Context, path string) (*sql.DB, error) {
	// Note: Do NOT use immutable=1 here - it caches the database state and
	// prevents seeing new messages (especially threaded replies) added after connection.
	dsn := fmt.Sprintf("file:%s?_pragma=busy_timeout(5000)&mode=ro", filepath.Clean(path))
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, enhanceError(err, path)
	}
	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, enhanceError(err, path)
	}
	return db, nil
}

// enhanceError adds helpful context for common permission/access errors.
func enhanceError(err error, path string) error {
	errStr := err.Error()

	// SQLite error 14 (SQLITE_CANTOPEN) and "authorization denied" both indicate permission issues
	if strings.Contains(errStr, "out of memory (14)") ||
		strings.Contains(errStr, "authorization denied") ||
		strings.Contains(errStr, "unable to open database") {
		return fmt.Errorf(`%w

⚠️  Permission Error: Cannot access Messages database

The Messages database at %s requires Full Disk Access permission.

To fix:
1. Open System Settings → Privacy & Security → Full Disk Access
2. Add your terminal application (Terminal.app, iTerm, etc.)
3. Restart your terminal
4. Try again

Note: This is required because macOS protects the Messages database.
For more details, see: https://github.com/steipete/imsg#permissions-troubleshooting`, err, path)
	}

	return err
}

// ListChats returns chats ordered by most recent activity.
func ListChats(ctx context.Context, db *sql.DB, limit int) ([]Chat, error) {
	const q = `
SELECT c.ROWID, IFNULL(c.display_name, c.chat_identifier) AS name, c.chat_identifier, c.service_name,
       MAX(m.date) AS last_date
FROM chat c
JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
JOIN message m ON m.ROWID = cmj.message_id
GROUP BY c.ROWID
ORDER BY last_date DESC
LIMIT ?`
	rows, err := db.QueryContext(ctx, q, limit)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	chats := []Chat{}
	for rows.Next() {
		var (
			id     int64
			name   sql.NullString
			ident  sql.NullString
			svc    sql.NullString
			lastNs sql.NullInt64
		)
		if err := rows.Scan(&id, &name, &ident, &svc, &lastNs); err != nil {
			return nil, err
		}
		chats = append(chats, Chat{
			ID:            id,
			Name:          name.String,
			Identifier:    ident.String,
			Service:       svc.String,
			LastMessageAt: appleTime(lastNs.Int64),
		})
	}
	return chats, rows.Err()
}

// MessagesByChat returns recent messages for a chat ordered newest first.
func MessagesByChat(ctx context.Context, db *sql.DB, chatID int64, limit int) ([]Message, error) {
	bodyCol := "''"
	if columnExists(ctx, db, "message", "attributedBody") {
		bodyCol = "m.attributedBody"
	}
	q := fmt.Sprintf(`
SELECT m.ROWID, m.handle_id, h.id, IFNULL(m.text, '') AS text, m.date, m.is_from_me, m.service,
       (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS attachments,
       %s as body
FROM message m
JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
LEFT JOIN handle h ON m.handle_id = h.ROWID
WHERE cmj.chat_id = ?
ORDER BY m.date DESC
LIMIT ?`, bodyCol)

	rows, err := db.QueryContext(ctx, q, chatID, limit)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	msgs := []Message{}
	for rows.Next() {
		var (
			rowID       int64
			handleID    sql.NullInt64
			sender      sql.NullString
			text        sql.NullString
			dateNs      sql.NullInt64
			isFromMe    bool
			service     sql.NullString
			attachments int
			body        []byte
		)
		if err := rows.Scan(&rowID, &handleID, &sender, &text, &dateNs, &isFromMe, &service, &attachments, &body); err != nil {
			return nil, err
		}
		resolvedText := text.String
		if resolvedText == "" {
			resolvedText = parseStreamTyped(body)
		}
		msgs = append(msgs, Message{
			RowID:       rowID,
			ChatID:      chatID,
			Sender:      sender.String,
			Text:        resolvedText,
			Date:        appleTime(dateNs.Int64),
			IsFromMe:    isFromMe,
			Service:     service.String,
			HandleID:    handleID,
			Attachments: attachments,
		})
	}
	return msgs, rows.Err()
}

// AttachmentsByMessage returns attachment metadata for a given message rowid.
func AttachmentsByMessage(ctx context.Context, db *sql.DB, messageID int64) ([]AttachmentMeta, error) {
	const q = `
SELECT a.filename, a.transfer_name, a.uti, a.mime_type, a.total_bytes, a.is_sticker
FROM message_attachment_join maj
JOIN attachment a ON a.ROWID = maj.attachment_id
WHERE maj.message_id = ?`

	rows, err := db.QueryContext(ctx, q, messageID)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	var out []AttachmentMeta
	for rows.Next() {
		var meta AttachmentMeta
		if err := rows.Scan(&meta.Filename, &meta.TransferName, &meta.UTI, &meta.MimeType, &meta.TotalBytes, &meta.IsSticker); err != nil {
			return nil, err
		}
		meta.OriginalPath, meta.Missing = resolvePath(meta.Filename)
		out = append(out, meta)
	}
	return out, rows.Err()
}

// MessagesAfter returns messages after a given rowid (strictly greater).
func MessagesAfter(ctx context.Context, db *sql.DB, afterRowID int64, chatIDFilter int64, limit int) ([]Message, error) {
	bodyCol := "''"
	if columnExists(ctx, db, "message", "attributedBody") {
		bodyCol = "m.attributedBody"
	}
	base := fmt.Sprintf(`
SELECT m.ROWID, cmj.chat_id, m.handle_id, h.id, IFNULL(m.text, '') AS text, m.date, m.is_from_me, m.service,
       (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS attachments,
       %s as body
FROM message m
LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
LEFT JOIN handle h ON m.handle_id = h.ROWID
WHERE m.ROWID > ?`, bodyCol)
	args := []any{afterRowID}
	if chatIDFilter != 0 {
		base += " AND cmj.chat_id = ?"
		args = append(args, chatIDFilter)
	}
	base += " ORDER BY m.ROWID ASC LIMIT ?"
	args = append(args, limit)

	rows, err := db.QueryContext(ctx, base, args...)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	msgs := []Message{}
	for rows.Next() {
		var (
			rowID       int64
			chatID      sql.NullInt64
			handleID    sql.NullInt64
			sender      sql.NullString
			text        sql.NullString
			dateNs      sql.NullInt64
			isFromMe    bool
			service     sql.NullString
			attachments int
			body        []byte
		)
		if err := rows.Scan(&rowID, &chatID, &handleID, &sender, &text, &dateNs, &isFromMe, &service, &attachments, &body); err != nil {
			return nil, err
		}
		resolvedText := text.String
		if resolvedText == "" {
			resolvedText = parseStreamTyped(body)
		}
		msgs = append(msgs, Message{
			RowID:       rowID,
			ChatID:      chatID.Int64,
			Sender:      sender.String,
			Text:        resolvedText,
			Date:        appleTime(dateNs.Int64),
			IsFromMe:    isFromMe,
			Service:     service.String,
			HandleID:    handleID,
			Attachments: attachments,
		})
	}
	return msgs, rows.Err()
}

// MaxRowID returns the current highest message rowid.
func MaxRowID(ctx context.Context, db *sql.DB) (int64, error) {
	var maxID sql.NullInt64
	if err := db.QueryRowContext(ctx, "SELECT MAX(ROWID) FROM message").Scan(&maxID); err != nil {
		return 0, err
	}
	return maxID.Int64, nil
}

func appleTime(ns int64) time.Time {
	// ns is nanoseconds since 2001-01-01 UTC
	return time.Unix(0, ns).Add(time.Duration(AppleEpochOffset) * time.Second)
}

func resolvePath(p string) (string, bool) {
	if p == "" {
		return "", true
	}
	if strings.HasPrefix(p, "~") {
		home, _ := os.UserHomeDir()
		p = strings.Replace(p, "~", home, 1)
	}
	exists := false
	if info, err := os.Stat(p); err == nil && !info.IsDir() {
		exists = true
	}
	return p, !exists
}

// parseStreamTyped attempts to recover plain text from an attributedBody typedstream blob.
// It looks for the known start/end sentinels and decodes the UTF-8 payload.
func parseStreamTyped(body []byte) string {
	if len(body) == 0 {
		return ""
	}
	const (
		startA = 0x01
		startB = 0x2b
		endA   = 0x86
		endB   = 0x84
	)

	// Trim to data between markers if present
	if idx := bytes.Index(body, []byte{startA, startB}); idx >= 0 && idx+2 < len(body) {
		body = body[idx+2:]
	}
	if idx := bytes.Index(body, []byte{endA, endB}); idx >= 0 {
		body = body[:idx]
	}

	// Decode, tolerating invalid sequences
	out := string(bytes.ToValidUTF8(body, nil))
	// Drop leading control chars/newlines that often prefix typedstream payloads
	out = strings.TrimLeftFunc(out, func(r rune) bool { return r < 32 })
	return out
}

// columnExists checks if a column is present on a table, used for older schemas.
func columnExists(ctx context.Context, db *sql.DB, table, column string) bool {
	rows, err := db.QueryContext(ctx, fmt.Sprintf("PRAGMA table_info(%s)", table))
	if err != nil {
		return false
	}
	defer func() { _ = rows.Close() }()
	for rows.Next() {
		var (
			cid     int
			name    string
			ctype   sql.NullString
			notnull sql.NullInt64
			dflt    sql.NullString
			pk      sql.NullInt64
		)
		// pragma table_info columns: cid,name,type,notnull,dflt_value,pk
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			continue
		}
		if strings.EqualFold(name, column) {
			return true
		}
	}
	return false
}
