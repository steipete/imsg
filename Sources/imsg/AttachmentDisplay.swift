import IMsgCore

func pluralSuffix(for count: Int) -> String {
  count == 1 ? "" : "s"
}

func displayName(for meta: AttachmentMeta) -> String {
  if !meta.transferName.isEmpty { return meta.transferName }
  if !meta.filename.isEmpty { return meta.filename }
  return "(unknown)"
}

/// Truncate a string to `limit` characters, appending an ellipsis when
/// truncation occurs. Newlines are collapsed to spaces so inline previews
/// (e.g. `↳ reply to ...`) stay on a single line.
func truncate(_ text: String, to limit: Int) -> String {
  let collapsed = text.replacingOccurrences(of: "\n", with: " ")
    .replacingOccurrences(of: "\r", with: " ")
  guard collapsed.count > limit else { return collapsed }
  let cutoff = collapsed.index(collapsed.startIndex, offsetBy: limit)
  return String(collapsed[..<cutoff]) + "…"
}
