# Graph tab data helpers (Phase 1 MVP + Phase 2 details).
#
# Pure parsing / layout functions shared by graph_manager.gd and
# graph_renderer.gd. No git calls and no UI here, so this file needs no
# @tool annotation to be usable from @tool scripts that preload it.
#
# NOTE: the log format intentionally avoids parsing
# `git log --graph` ASCII art. graph_manager.gd requests a structured
# `--pretty=format:` (fields split by 0x1F, records by 0x1E) carrying the
# same data (hash, parents, refs, subject, author, date); lane assignment
# below derives the visual columns from the parent links instead.
# Phase 2 adds the same separator scheme for `git show --name-status`
# commit details (see parse_commit_details).
extends RefCounted

# Inline diffs are capped so a huge generated file cannot stall the
# RichTextLabel renderer. The manager truncates; the widget caps lines.
const DIFF_MAX_CHARS = 100000
const DIFF_TRUNCATED_NOTE = "\n… diff truncated (file too large to show fully) …"


# Split the single stdout blob OS.execute delivers into individual lines,
# mirroring GitManager._on_status_result ("\r" tolerant, skips blanks).
static func split_lines(text: String) -> PackedStringArray:
	var lines := PackedStringArray()
	for raw_line in text.split("\n"):
		var line: String = String(raw_line).trim_suffix("\r")
		if line.strip_edges().is_empty():
			continue
		lines.append(line)
	return lines


# Parse one page of the structured log format into commit dictionaries:
# { hash, short, parents (Array[String]), author, email, date, subject,
#   refs: { head (bool), current (String), branches (Array[String]),
#           tags (Array[String]) },
#   lane (int, via assign_lanes), connections (Array, via assign_lanes) }.
# Accepts the current 8-field shape (with author email) and the pre-Phase-4
# 7-field shape (email defaults to "").
static func parse_log(text: String) -> Array:
	var commits: Array = []
	var rs := String.chr(30)
	var fs := String.chr(31)
	for record in text.split(rs):
		var raw_record := String(record)
		if raw_record.strip_edges().is_empty():
			continue
		# NOTE: do NOT strip the record before splitting. Godot's
		# strip_edges() eats the 0x1F separators, and most records end
		# with one (their %D refs field is empty), so stripping drops
		# the last field and the record is skipped below. Split the raw
		# record with maxsplit so short/tag-less lines still yield all
		# fields, padding a missing trailing refs field with "".
		var fields: PackedStringArray = raw_record.split(fs, true, 7)
		while fields.size() < 8:
			fields.append("")
		if fields.size() != 8:
			continue
		for f in range(fields.size()):
			fields[f] = String(fields[f]).strip_edges()
		# 8-field (current): hash, parents, short, author, email, date,
		# subject, refs. 7-field (legacy): the email slot is absent, so
		# fields[4] is the date — detect by shape: legacy records were
		# padded above to 8 with "" at the END, which would put refs in
		# fields[6]... ambiguous. Instead: graph_manager always sends 8
		# fields now; treat a record as legacy only when it split to
		# exactly 7 non-padded fields. Re-split without padding to tell.
		var bare: PackedStringArray = raw_record.split(fs, true, 7)
		var author := ""
		var email := ""
		var date_text := ""
		var subject := ""
		var refs_text := ""
		if bare.size() <= 7:
			# Legacy 7-field shape.
			var legacy: PackedStringArray = raw_record.split(fs, true, 6)
			while legacy.size() < 7:
				legacy.append("")
			if String(legacy[0]).strip_edges().is_empty():
				continue
			author = String(legacy[3]).strip_edges()
			date_text = String(legacy[4]).strip_edges()
			subject = String(legacy[5]).strip_edges()
			refs_text = String(legacy[6]).strip_edges()
			var parents_legacy: Array = []
			var parent_field_legacy := String(legacy[1]).strip_edges()
			if not parent_field_legacy.is_empty():
				for p in parent_field_legacy.split(" "):
					var h := String(p).strip_edges()
					if not h.is_empty():
						parents_legacy.append(h)
			commits.append({
				"hash": String(legacy[0]).strip_edges(),
				"parents": parents_legacy,
				"short": String(legacy[2]).strip_edges(),
				"author": author,
				"email": "",
				"date": date_text,
				"subject": subject,
				"refs": parse_ref_field(refs_text),
				"lane": 0,
				"connections": [],
			})
			continue
		if String(fields[0]).is_empty():
			continue
		author = String(fields[3])
		email = String(fields[4])
		date_text = String(fields[5])
		subject = String(fields[6])
		refs_text = String(fields[7])
		var parents: Array = []
		var parent_field := String(fields[1]).strip_edges()
		if not parent_field.is_empty():
			for p in parent_field.split(" "):
				var h := String(p).strip_edges()
				if not h.is_empty():
					parents.append(h)
		commits.append({
			"hash": String(fields[0]),
			"parents": parents,
			"short": String(fields[2]),
			"author": author,
			"email": email,
			"date": date_text,
			"subject": subject,
			"refs": parse_ref_field(refs_text),
			"lane": 0,
			"connections": [],
		})
	return commits


# Parse the %D decorate field, e.g.
# "HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1".
static func parse_ref_field(field: String) -> Dictionary:
	var refs := {"head": false, "current": "", "branches": [], "tags": []}
	var text := field.strip_edges()
	if text.is_empty():
		return refs
	for entry in text.split(", "):
		var ref := String(entry).strip_edges()
		if ref.is_empty():
			continue
		if ref == "HEAD":
			refs["head"] = true
			continue
		if ref.begins_with("HEAD -> "):
			refs["head"] = true
			var target := ref.substr(len("HEAD -> "))
			refs["current"] = short_ref_name(target)
			(refs["branches"] as Array).append(short_ref_name(target))
			continue
		if ref.begins_with("tag: "):
			(refs["tags"] as Array).append(short_ref_name(ref.substr(len("tag: "))))
			continue
		if ref.begins_with("refs/heads/") or ref.begins_with("refs/remotes/"):
			(refs["branches"] as Array).append(short_ref_name(ref))
			continue
		if ref.begins_with("refs/tags/"):
			(refs["tags"] as Array).append(short_ref_name(ref))
			continue
		(refs["branches"] as Array).append(short_ref_name(ref))
	return refs


static func short_ref_name(ref: String) -> String:
	var text := ref.strip_edges()
	for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"]:
		if text.begins_with(prefix):
			return text.substr(prefix.length())
	return text


# Parse `git branch -a --no-color` output.
# Returns [{ name, current (bool), remote (bool), detached (bool) }].
# Symlink lines ("remotes/origin/HEAD -> origin/main") carry no commit and
# are skipped; a detached HEAD shows as "* (HEAD detached at ...)".
static func parse_branches(text: String) -> Array:
	var branches: Array = []
	for line in split_lines(text):
		var entry := line.strip_edges()
		if entry.is_empty() or " -> " in entry:
			continue
		var current := entry.begins_with("*")
		if current:
			entry = entry.substr(1).strip_edges()
		var detached := entry.begins_with("(HEAD detached")
		branches.append({
			"name": entry,
			"current": current,
			"remote": entry.begins_with("remotes/"),
			"detached": detached,
		})
	return branches


# Parse `git tag -l` output. Returns [{ name }].
static func parse_tags(text: String) -> Array:
	var tags: Array = []
	for line in split_lines(text):
		tags.append({"name": line.strip_edges()})
	return tags


# Parse `git stash list` output into [{ index, branch, message, raw }].
# Lines look like "stash@{0}: On main: my message" or
# "stash@{0}: WIP on main: abc1234 short subject". Branch/message are
# best-effort (custom `git stash store` messages vary); index is exact.
static func parse_stashes(text: String) -> Array:
	var stashes: Array = []
	for line in split_lines(text):
		var entry := parse_stash_line(line)
		if not entry.is_empty():
			stashes.append(entry)
	return stashes


static func parse_stash_line(line: String) -> Dictionary:
	var cleaned := String(line).trim_suffix("\r").strip_edges()
	if not cleaned.begins_with("stash@{"):
		return {}
	var close := cleaned.find("}")
	if close == -1:
		return {}
	var index := int(cleaned.substr(len("stash@{"), close - len("stash@{")))
	var rest := ""
	var sep := cleaned.find(": ", close)
	if sep != -1:
		rest = cleaned.substr(sep + 2).strip_edges()
	# "On <branch>: <msg>" / "WIP on <branch>: <msg>" — branch is the
	# middle segment when two ": " separators exist.
	var branch := ""
	var message := rest
	if rest.begins_with("On ") or rest.begins_with("WIP on "):
		var inner := rest.find(": ", 3)
		if inner != -1:
			branch = rest.substr(0, inner).strip_edges()
			if branch.begins_with("WIP on "):
				branch = branch.substr(len("WIP on "))
			elif branch.begins_with("On "):
				branch = branch.substr(len("On "))
			message = rest.substr(inner + 2).strip_edges()
	return {"index": index, "branch": branch, "message": message, "raw": cleaned}


# Canonical stash ref for apply/pop/drop commands.
static func stash_ref(index: int) -> String:
	return "stash@{%d}" % maxi(index, 0)


# Parse `git remote -v` output into [{ name, fetch_url, push_url }].
# Lines look like "origin\t<url> (fetch)". Remotes appear twice (fetch +
# push); the pair is merged into one entry. Push-only or fetch-only
# remotes keep "" for the missing side.
static func parse_remotes(text: String) -> Array:
	var remotes: Array = []
	for line in split_lines(text):
		var cleaned := String(line).trim_suffix("\r").strip_edges()
		if cleaned.is_empty():
			continue
		var kind := ""
		if cleaned.ends_with("(fetch)"):
			kind = "fetch"
		elif cleaned.ends_with("(push)"):
			kind = "push"
		else:
			continue
		var body := cleaned.left(cleaned.length() - kind.length() - 2).strip_edges()
		var cols: PackedStringArray = body.split("\t")
		if cols.size() < 2:
			cols = body.split(" ")
		if cols.size() < 2:
			continue
		var remote_name := String(cols[0]).strip_edges()
		var url := String(cols[cols.size() - 1]).strip_edges()
		if remote_name.is_empty() or url.is_empty():
			continue
		var found := false
		for r in remotes:
			var info: Dictionary = r
			if String(info.get("name", "")) == remote_name:
				info[kind + "_url"] = url
				found = true
				break
		if not found:
			var entry := {"name": remote_name, "fetch_url": "", "push_url": ""}
			entry[kind + "_url"] = url
			remotes.append(entry)
	return remotes


# Pragmatic `git check-ref-format --branch` subset for dialog validation:
# non-empty, no whitespace, none of ~ ^ : ? * [ \ and no "..", "@{",
# leading "-" / "." / "/", trailing "/" or ".lock". Covers the mistakes
# users actually make; git itself is the final arbiter (errors surface).
static func is_valid_ref_name(ref_name: String) -> bool:
	var candidate := String(ref_name).strip_edges()
	if candidate.is_empty():
		return false
	if candidate != String(ref_name):
		return false
	for bad in [" ", "\t", "~", "^", ":", "?", "*", "[", "\\", "..", "@{"]:
		if bad in candidate:
			return false
	if candidate.begins_with("-") or candidate.begins_with(".") or candidate.begins_with("/"):
		return false
	if candidate.ends_with("/") or candidate.ends_with(".lock"):
		return false
	return true


# Parse `git for-each-ref --format <refname, short, hash, HEAD flag>`.
# Returns [{ refname, short, hash, current (bool), kind }] where kind is
# one of "head", "remote", "tag", "other".
static func parse_refs(text: String) -> Array:
	var refs: Array = []
	var fs := String.chr(31)
	for line in split_lines(text):
		var fields: PackedStringArray = line.split(fs)
		if fields.size() < 3:
			continue
		var refname := String(fields[0]).strip_edges()
		var kind := "other"
		if refname.begins_with("refs/heads/"):
			kind = "head"
		elif refname.begins_with("refs/remotes/"):
			kind = "remote"
		elif refname.begins_with("refs/tags/"):
			kind = "tag"
		var current := false
		if fields.size() >= 4:
			current = String(fields[3]).strip_edges() == "*"
		refs.append({
			"refname": refname,
			"short": String(fields[1]).strip_edges(),
			"hash": String(fields[2]).strip_edges(),
			"current": current,
			"kind": kind,
		})
	return refs


# Parse one `git show --name-status --format=<9 fields>` blob into a details
# dictionary: { hash, short, author, author_date, committer,
#   committer_date, subject, body, refs (via parse_ref_field),
#   files: [{ status, path, old_path }] }.
# Status is a single letter (A/M/D/R/C/T/U); renames/copies carry old_path.
# Returns {} when the blob holds no commit metadata.
static func parse_commit_details(text: String) -> Dictionary:
	var rs := String.chr(30)
	var fs := String.chr(31)
	var parts: PackedStringArray = text.split(rs)
	if parts.is_empty():
		return {}
	var fields: PackedStringArray = parts[0].split(fs, true, 8)
	while fields.size() < 9:
		fields.append("")
	if String(fields[0]).strip_edges().is_empty():
		return {}
	var files: Array = []
	if parts.size() > 1:
		var rest := rs.join(parts.slice(1))
		for line in split_lines(rest):
			var entry := parse_name_status_line(line)
			if not entry.is_empty():
				files.append(entry)
	return {
		"hash": String(fields[0]).strip_edges(),
		"short": String(fields[1]).strip_edges(),
		"author": String(fields[2]).strip_edges(),
		"author_date": String(fields[3]).strip_edges(),
		"committer": String(fields[4]).strip_edges(),
		"committer_date": String(fields[5]).strip_edges(),
		"subject": String(fields[6]).strip_edges(),
		"body": String(fields[7]).strip_edges(),
		"refs": parse_ref_field(String(fields[8])),
		"files": files,
	}


# Parse one `git show --name-status` entry ("M\tpath", "R100\told\tnew").
# Returns {} for non-entry lines (diff content never reaches here, but the
# guard keeps stray output from becoming phantom files).
static func parse_name_status_line(line: String) -> Dictionary:
	var cols: PackedStringArray = String(line).trim_suffix("\r").split("\t")
	if cols.is_empty():
		return {}
	var letter := String(cols[0]).strip_edges().left(1).to_upper()
	if not letter in ["A", "M", "D", "R", "C", "T", "U"]:
		return {}
	if (letter == "R" or letter == "C") and cols.size() >= 3:
		return {
			"status": letter,
			"path": String(cols[2]).strip_edges(),
			"old_path": String(cols[1]).strip_edges(),
		}
	if cols.size() >= 2:
		var target := String(cols[1]).strip_edges()
		if target.is_empty():
			return {}
		return {"status": letter, "path": target, "old_path": ""}
	return {}


# Cap raw diff text for the inline viewer. Returns { text, truncated }.
static func truncate_diff(raw: String, limit: int = DIFF_MAX_CHARS) -> Dictionary:
	var text := String(raw)
	if text.length() <= limit:
		return {"text": text, "truncated": false}
	return {"text": text.left(limit) + DIFF_TRUNCATED_NOTE, "truncated": true}


# True when git reports a binary payload instead of a unified diff.
static func is_binary_diff(text: String) -> bool:
	return "Binary files " in text and " differ" in text


# Escape BBCode brackets, then linkify http(s) URLs for RichTextLabel.
# Phase 4: markdown and :emoji: shortcodes render by default; use
# message_to_bbcode_full for the settings toggles.
static func message_to_bbcode(text: String) -> String:
	return message_to_bbcode_full(text, true, true)


# Full commit-message renderer. Order matters: markdown links are lifted
# out first (their brackets must not be escaped), then raw brackets are
# escaped, then code/bold/italic, then bare-URL linkify (skips the lifted
# links), then emoji (unicode, bracket-free), then the lifted links are
# spliced back as real [url] tags.
static func message_to_bbcode_full(text: String, do_markdown: bool, do_emoji: bool) -> String:
	var links: Array = []
	var shaped := String(text)
	if do_markdown:
		shaped = _extract_markdown_links(shaped, links)
	var escaped := shaped.replace("[", "[lb]")
	shaped = escaped
	if do_markdown:
		shaped = markdown_to_bbcode(shaped)
	shaped = _linkify_bare_urls(shaped)
	if do_emoji:
		shaped = replace_emoji_shortcodes(shaped)
	if not links.is_empty():
		shaped = _restore_markdown_links(shaped, links)
	return shaped


# Lift [text](url) links out of the raw message into private-use sentinels
# so bracket-escaping and the other markdown passes leave them alone.
# Appends [label, url] pairs to `links`; returns the text with sentinels.
static func _extract_markdown_links(text: String, links: Array) -> String:
	var link_re := RegEx.new()
	if link_re.compile("\\[([^\\]\\n]+?)\\]\\((https?://[^\\s\\)]+)\\)") != OK:
		return text
	var out := ""
	var pos := 0
	for m in link_re.search_all(text):
		out += text.substr(pos, m.get_start() - pos) + "\uE000%d\uE001" % links.size()
		links.append([m.get_string(1), m.get_string(2)])
		pos = m.get_end()
	if links.is_empty():
		return text
	out += text.substr(pos)
	return out


# Splice lifted links back as [url] tags. Labels are bracket-escaped like
# the rest of the message; sentinels carry no regex/markdown characters so
# earlier passes cannot have altered them.
static func _restore_markdown_links(text: String, links: Array) -> String:
	var shaped := text
	for i in range(links.size()):
		var pair: Array = links[i]
		var label := String(pair[0]).replace("[", "[lb]")
		shaped = shaped.replace("\uE000%d\uE001" % i, "[url=%s]%s[/url]" % [String(pair[1]), label])
	return shaped


# Linkify bare http(s) URLs, skipping spans already inside [url]...[/url]
# (e.g. converted markdown links). Manual span walk: the one-shot regex
# in message_to_bbcode could not tell the two apart.
static func _linkify_bare_urls(text: String) -> String:
	var url_re := RegEx.new()
	if url_re.compile("https?://[^\\s\\])]+") != OK:
		return text
	# Collect [url]...[/url] spans to protect.
	var spans: Array = []
	var open_idx := 0
	while true:
		var o := text.find("[url", open_idx)
		if o == -1:
			break
		var close_tag := text.find("[/url]", o)
		if close_tag == -1:
			break
		spans.append([o, close_tag + len("[/url]")])
		open_idx = close_tag + len("[/url]")
	var out := ""
	var pos := 0
	for m in url_re.search_all(text):
		var s := m.get_start()
		var e := m.get_end()
		var protected := false
		for span in spans:
			if s >= int(span[0]) and s < int(span[1]):
				protected = true
				break
		if protected:
			continue
		out += text.substr(pos, s - pos) + "[url]" + text.substr(s, e - s) + "[/url]"
		pos = e
	# Note: spans were computed on the original string; out rebuilds only
	# around unprotected matches, so protected regions pass through intact.
	# Any tail after the last match is appended below.
	if pos == 0:
		return text
	# Rebuild caveat: matches inside protected spans were skipped without
	# advancing pos, so re-walk is unnecessary — but skipped matches before
	# pos are impossible since matches are ordered and pos only advances
	# past emitted matches. Append the remainder.
	out += text.substr(pos)
	return out


# Minimal markdown subset for commit bodies: fenced blocks, inline code,
# **bold**/__bold__, *italic*, ~~strike~~, # headers, > quotes, - bullets.
# [text](url) links are lifted out before this runs (see
# message_to_bbcode_full) so their brackets survive escaping. Input must
# already be [lb]-escaped. [code] spans are protected from all formatting.
static func markdown_to_bbcode(text: String) -> String:
	var shaped := String(text)
	# Fenced code blocks first so inner markdown chars are protected.
	var fence_re := RegEx.new()
	if fence_re.compile("(?s)```([^`]*?)```") == OK:
		shaped = fence_re.sub(shaped, "[code]$1[/code]", true)
	var inline_re := RegEx.new()
	if inline_re.compile("`([^`\\n]+?)`") == OK:
		shaped = inline_re.sub(shaped, "[code]$1[/code]", true)
	var patterns: Array = []
	var bold_re := RegEx.new()
	if bold_re.compile("\\*\\*([^\\*\\n]+?)\\*\\*") == OK:
		patterns.append([bold_re, "[b]$1[/b]"])
	var bold2_re := RegEx.new()
	if bold2_re.compile("__([^_\\n]+?)__") == OK:
		patterns.append([bold2_re, "[b]$1[/b]"])
	var strike_re := RegEx.new()
	if strike_re.compile("~~([^~\\n]+?)~~") == OK:
		patterns.append([strike_re, "[s]$1[/s]"])
	var italic_re := RegEx.new()
	if italic_re.compile("(^|[^\\w\\*])\\*([^\\*\\n]+?)\\*") == OK:
		patterns.append([italic_re, "$1[i]$2[/i]"])
	shaped = _format_outside_code(shaped, patterns)
	var lines := shaped.split("\n")
	var in_code := false
	for i in range(lines.size()):
		var line := String(lines[i])
		if "[code]" in line and not ("[/code]" in line and line.find("[/code]") > line.find("[code]")):
			in_code = true
			continue
		if in_code:
			if "[/code]" in line:
				in_code = false
			continue
		var stripped := line.strip_edges()
		if stripped.begins_with("###### "):
			lines[i] = "[b]" + stripped.substr(7) + "[/b]"
		elif stripped.begins_with("##### "):
			lines[i] = "[b]" + stripped.substr(6) + "[/b]"
		elif stripped.begins_with("#### "):
			lines[i] = "[b]" + stripped.substr(5) + "[/b]"
		elif stripped.begins_with("### "):
			lines[i] = "[b]" + stripped.substr(4) + "[/b]"
		elif stripped.begins_with("## "):
			lines[i] = "[b]" + stripped.substr(3) + "[/b]"
		elif stripped.begins_with("# "):
			lines[i] = "[b]" + stripped.substr(2) + "[/b]"
		elif stripped.begins_with("> "):
			lines[i] = "[i]" + stripped.substr(2) + "[/i]"
		elif stripped.begins_with("- ") or stripped.begins_with("* "):
			lines[i] = "• " + stripped.substr(2)
		elif stripped.length() >= 3 and stripped.left(1).is_valid_int() and stripped.substr(1, 2) == ". ":
			lines[i] = "• " + stripped.substr(3)
	return "\n".join(lines)


# Apply regex replacements only to text outside [code]...[/code] spans.
# Splits the string into alternating normal/code segments (even indices
# are normal text) so formatting never touches literal code.
static func _format_outside_code(text: String, patterns: Array) -> String:
	if patterns.is_empty():
		return text
	var parts: PackedStringArray = []
	var pos := 0
	while true:
		var o := text.find("[code]", pos)
		if o == -1:
			parts.append(text.substr(pos))
			break
		var c := text.find("[/code]", o)
		if c == -1:
			parts.append(text.substr(pos))
			break
		parts.append(text.substr(pos, o - pos))
		parts.append(text.substr(o, c + len("[/code]") - o))
		pos = c + len("[/code]")
	for i in range(parts.size()):
		if i % 2 == 0:
			var seg := String(parts[i])
			for p in patterns:
				seg = (p[0] as RegEx).sub(seg, String(p[1]), true)
			parts[i] = seg
	return "".join(parts)


# Common :shortcode: -> unicode emoji. Unknown codes pass through intact.
const EMOJI_SHORTCODES = {
	"+1": "👍",
	"-1": "👎",
	"100": "💯",
	"boom": "💥",
	"bug": "🐛",
	"building_construction": "🏗️",
	"bulb": "💡",
	"busts_in_silhouette": "👥",
	"card_file_box": "🗃️",
	"chart_with_upwards_trend": "📈",
	"checkered_flag": "🏁",
	"children_crossing": "🚸",
	"clown_face": "🤡",
	"coffin": "⚰️",
	"construction": "🚧",
	"fire": "🔥",
	"gem": "💎",
	"globe_with_meridians": "🌐",
	"green_heart": "💚",
	"hammer": "🔨",
	"heavy_check_mark": "✔️",
	"heavy_plus_sign": "➕",
	"lipstick": "💄",
	"lock": "🔒",
	"loud_sound": "🔊",
	"memo": "📝",
	"mute": "🔇",
	"ok_hand": "👌",
	"poop": "💩",
	"recycle": "♻️",
	"rewind": "⏪",
	"rocket": "🚀",
	"rotating_light": "🚨",
	"sparkles": "✨",
	"tada": "🎉",
	"truck": "🚚",
	"white_check_mark": "✅",
	"wrench": "🔧",
	"x": "❌",
	"zap": "⚡️",
}


static func replace_emoji_shortcodes(text: String) -> String:
	var code_re := RegEx.new()
	if code_re.compile(":([a-zA-Z0-9_\\+\\-]+):") != OK:
		return text
	var out := ""
	var pos := 0
	for m in code_re.search_all(text):
		var key := m.get_string(1)
		if not EMOJI_SHORTCODES.has(key):
			continue
		var s := m.get_start()
		out += text.substr(pos, s - pos) + String(EMOJI_SHORTCODES[key])
		pos = m.get_end()
	if pos == 0:
		return text
	out += text.substr(pos)
	return out


# Find-widget matching over one parsed commit dict. Scope is one of
# "all", "message", "author", "hash", "branch", "tag". Empty query never
# matches (the widget shows the idle hint instead of selecting all).
static func match_commit(commit: Dictionary, query: String, scope: String) -> bool:
	var q := String(query).strip_edges().to_lower()
	if q.is_empty():
		return false
	match String(scope).to_lower():
		"message":
			return q in String(commit.get("subject", "")).to_lower()
		"author":
			return q in String(commit.get("author", "")).to_lower()
		"hash":
			return String(commit.get("hash", "")).to_lower().begins_with(q) or q in String(commit.get("short", "")).to_lower()
		"branch":
			var refs_b: Dictionary = commit.get("refs", {})
			for branch_name in refs_b.get("branches", []):
				if q in String(branch_name).to_lower():
					return true
			return false
		"tag":
			var refs_t: Dictionary = commit.get("refs", {})
			for tag_name in refs_t.get("tags", []):
				if q in String(tag_name).to_lower():
					return true
			return false
		_:
			if q in String(commit.get("subject", "")).to_lower():
				return true
			if q in String(commit.get("author", "")).to_lower():
				return true
			if String(commit.get("hash", "")).to_lower().begins_with(q):
				return true
			if q in String(commit.get("short", "")).to_lower():
				return true
			var refs: Dictionary = commit.get("refs", {})
			for branch_name in refs.get("branches", []):
				if q in String(branch_name).to_lower():
					return true
			for tag_name in refs.get("tags", []):
				if q in String(tag_name).to_lower():
					return true
			return false


# Indices of commits matching the query, in graph order.
static func filter_commit_indices(commits: Array, query: String, scope: String) -> Array:
	var hits: Array = []
	if String(query).strip_edges().is_empty():
		return hits
	for i in range(commits.size()):
		if match_commit(commits[i], query, scope):
			hits.append(i)
	return hits


# Parse `git diff --name-status <a> <b>` output. Same line shape as
# `git show --name-status`, so entries reuse parse_name_status_line.
static func parse_diff_name_status(text: String) -> Array:
	var files: Array = []
	for line in split_lines(text):
		var entry := parse_name_status_line(line)
		if not entry.is_empty():
			files.append(entry)
	return files


# Settings date display: "iso" (raw git date), "short" (YYYY-MM-DD), or
# "relative" ("3h ago"). Unparseable input falls back to the raw string.
static func format_graph_date(iso_text: String, mode: String) -> String:
	var raw := String(iso_text).strip_edges()
	if raw.is_empty():
		return ""
	match String(mode).to_lower():
		"short":
			return raw.left(10)
		"relative":
			return _relative_date(raw)
		_:
			return raw


static func _relative_date(iso_text: String) -> String:
	var raw := String(iso_text).strip_edges()
	# Git --date=iso uses a space separator; tolerate the 'T' variant too.
	# The engine parser reads naive wall time as UTC, so a numeric zone
	# suffix ("+0200", carried by %ad) is shifted back for a true instant.
	var body := raw.left(19).replace("T", " ")
	# Pre-validate so garbage never reaches the engine parser (which prints
	# a noisy error and returns -1/0 for unparseable input).
	var sane := RegEx.new()
	if sane.compile("^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}(:\\d{2})?$") != OK:
		return iso_text
	if not sane.search(body):
		return iso_text
	var stamp := Time.get_unix_time_from_datetime_string(body)
	if int(stamp) <= 0:
		return iso_text
	var zone := RegEx.new()
	if zone.compile("([+-])(\\d{2})(\\d{2})\\s*$") == OK:
		var tail := raw.right(maxi(raw.length() - 19, 0))
		var zm := zone.search(tail)
		if zm != null:
			var off := int(zm.get_string(2)) * 3600 + int(zm.get_string(3)) * 60
			stamp += -off if zm.get_string(1) == "+" else off
	var delta := int(Time.get_unix_time_from_system()) - int(stamp)
	if delta < 0:
		# Slightly future-dated (clock skew across machines) reads as now;
		# genuinely future dates fall back to the raw string.
		return "just now" if delta >= -120 else iso_text
	if delta < 60:
		return "just now"
	if delta < 3600:
		var mins := delta / 60
		return "%dm ago" % mins if mins != 1 else "1m ago"
	if delta < 86400:
		var hours := delta / 3600
		return "%dh ago" % hours if hours != 1 else "1h ago"
	if delta < 86400 * 30:
		var days := delta / 86400
		return "%dd ago" % days if days != 1 else "1d ago"
	if delta < 86400 * 365:
		var months := delta / (86400 * 30)
		return "%dmo ago" % months if months != 1 else "1mo ago"
	var years := delta / (86400 * 365)
	return "%dy ago" % years if years != 1 else "1y ago"


# Phase 5: single glob match. Supports `*` (any run), `?` (one char),
# and `[...]` character classes; everything else is literal. Empty
# pattern matches everything (an empty filter row means "no filter").
static func match_glob(text: String, pattern: String) -> bool:
	var pat := String(pattern).strip_edges()
	if pat.is_empty() or pat == "*":
		return true
	var rx := RegEx.new()
	if rx.compile(glob_to_regex(pat)) != OK:
		return String(text) == pat
	var m := rx.search(String(text))
	return m != null


# Phase 5: comma-separated glob list from the filter row / settings.
# Empty string matches everything. A `!`-prefixed pattern negates
# (excludes); otherwise at least one positive pattern must match.
static func match_any_glob(text: String, glob_csv: String) -> bool:
	var raw := String(glob_csv).strip_edges()
	if raw.is_empty():
		return true
	var positives: Array = []
	var negatives: Array = []
	for chunk in raw.split(","):
		var pat := String(chunk).strip_edges()
		if pat.is_empty():
			continue
		if pat.begins_with("!") and pat.length() > 1:
			negatives.append(pat.substr(1).strip_edges())
		else:
			positives.append(pat)
	for neg in negatives:
		if match_glob(text, String(neg)):
			return false
	if positives.is_empty():
		return true
	for pos in positives:
		if match_glob(text, String(pos)):
			return true
	return false


# Phase 5: translate one glob pattern to an anchored regex string.
static func glob_to_regex(pattern: String) -> String:
	var out := "^"
	var i := 0
	var pat := String(pattern)
	# NOTE: String[i] yields an int codepoint in Godot 4, so single
	# characters are read via substr().
	while i < pat.length():
		var ch := pat.substr(i, 1)
		if ch == "*":
			out += ".*"
		elif ch == "?":
			out += "."
		elif ch == "[":
			var close := pat.find("]", i + 1)
			if close == -1:
				out += "\\["
			else:
				out += pat.substr(i, close - i + 1)
				i = close + 1
				continue
		elif ch in ["\\", ".", "+", "(", ")", "|", "{", "}", "^", "$"]:
			out += "\\" + ch
		else:
			out += ch
		i += 1
	out += "$"
	return out


# Phase 5: file-status code to a human word for the accessibility mode
# (commit_details.gd) and tooltips. Unknown codes pass through raw.
static func file_status_word(code: String) -> String:
	match String(code).strip_edges().to_upper().left(1):
		"A":
			return "Added"
		"M":
			return "Modified"
		"D":
			return "Deleted"
		"R":
			return "Renamed"
		"C":
			return "Copied"
		"T":
			return "Type change"
		"U", "?":
			return "Unmerged"
	return String(code)


# Phase 5: deterministic lane color for a branch name (tab icon "branch"
# theme). Same hue family as the default graph palette so the icon reads
# as part of the graph.
const BRANCH_THEME_COLORS = [
	Color(0.45, 0.75, 1.0),
	Color(0.55, 0.9, 0.55),
	Color(1.0, 0.75, 0.35),
	Color(1.0, 0.5, 0.55),
	Color(0.75, 0.6, 1.0),
	Color(0.45, 0.9, 0.85),
	Color(1.0, 0.95, 0.5),
	Color(1.0, 0.6, 0.35),
]


static func branch_color_for(branch_name: String) -> Color:
	var label := String(branch_name).strip_edges()
	if label.is_empty() or label == "-":
		return Color(1, 1, 1)
	return BRANCH_THEME_COLORS[absi(hash(label)) % BRANCH_THEME_COLORS.size()]


# Phase 5: parse a git remote URL into { provider, host, path, owner,
# repo, web_url }. Handles https/http/git/ssh and the scp-like
# `git@host:owner/repo(.git)` shape. Returns {} when unparseable.
static func parse_remote_url(url: String) -> Dictionary:
	var raw := String(url).strip_edges()
	if raw.is_empty():
		return {}
	# scp-like: [user@]host:path
	var scp := RegEx.new()
	if scp.compile("^(?:[^@:/\\s]+@)?([^:/\\s]+):(.+)$") == OK:
		var scp_m := scp.search(raw)
		if scp_m != null and "://" not in raw:
			return _shape_remote_info(scp_m.get_string(1), scp_m.get_string(2))
	# scheme://[user@]host/path
	var uri := RegEx.new()
	if uri.compile("^[a-zA-Z][a-zA-Z0-9+\\-.]*://(?:[^@/\\s]+@)?([^/:\\s]+)(?::\\d+)?/(.+)$") == OK:
		var uri_m := uri.search(raw)
		if uri_m != null:
			return _shape_remote_info(uri_m.get_string(1), uri_m.get_string(2))
	return {}


static func _as_dict(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


static func _shape_remote_info(host: String, path: String) -> Dictionary:
	var clean_host := String(host).strip_edges().to_lower().trim_prefix("www.")
	var clean_path := String(path).strip_edges().trim_prefix("/").trim_suffix("/").trim_suffix(".git")
	if clean_host.is_empty() or clean_path.is_empty():
		return {}
	if clean_host.length() == 1:
		# Windows drive letter from a local-path remote (e.g. `C:\repos`);
		# not a host, so there is no PR page to link.
		return {}
	var bits: PackedStringArray = clean_path.split("/", false)
	if bits.is_empty():
		return {}
	var provider := "generic"
	if "github" in clean_host:
		provider = "github"
	elif "gitlab" in clean_host:
		provider = "gitlab"
	elif "bitbucket" in clean_host:
		provider = "bitbucket"
	var owner := String(bits[0]) if bits.size() > 1 else ""
	var repo := String(bits[bits.size() - 1])
	return {
		"provider": provider,
		"host": clean_host,
		"path": clean_path,
		"owner": owner,
		"repo": repo,
		"web_url": "https://" + clean_host + "/" + clean_path,
	}


# Phase 5: pull/merge-request list page for the parsed remote info.
static func pr_list_url(info: Dictionary) -> String:
	var web := String(info.get("web_url", ""))
	if web.is_empty():
		return ""
	match String(info.get("provider", "generic")):
		"github":
			return web + "/pulls"
		"gitlab":
			return web + "/-/merge_requests"
		"bitbucket":
			return web + "/pull-requests/"
	return web


# Phase 5: "create a pull request" page. Head/base are best-effort per
# provider; empty when the info has no web URL.
static func pr_new_url(info: Dictionary, head_branch: String = "", base_branch: String = "") -> String:
	var web := String(info.get("web_url", ""))
	if web.is_empty():
		return ""
	var head := String(head_branch).strip_edges()
	var base := String(base_branch).strip_edges()
	match String(info.get("provider", "generic")):
		"github":
			if not head.is_empty() and not base.is_empty() and head != base:
				return "%s/compare/%s...%s?expand=1" % [web, base.uri_encode(), head.uri_encode()]
			if not base.is_empty():
				return "%s/pull/new/%s" % [web, base.uri_encode()]
			return web + "/pulls"
		"gitlab":
			if not head.is_empty():
				return "%s/-/merge_requests/new?merge_request[source_branch]=%s" % [web, head.uri_encode()]
			return web + "/-/merge_requests/new"
		"bitbucket":
			if not head.is_empty():
				return "%s/pull-requests/new?source=%s" % [web, head.uri_encode()]
			return web + "/pull-requests/new"
	return web


# Phase 5: REST endpoint for the open-PR submenu. Empty for generic
# hosts (the panel then only offers open-in-browser actions).
static func pr_api_url(info: Dictionary) -> String:
	var provider := String(info.get("provider", "generic"))
	var path := String(info.get("path", ""))
	var host := String(info.get("host", ""))
	if path.is_empty() or host.is_empty():
		return ""
	match provider:
		"github":
			return "https://api.github.com/repos/" + path + "/pulls?state=open&per_page=20"
		"gitlab":
			return "https://" + host + "/api/v4/projects/" + path.uri_encode() + "/merge_requests?state=opened&per_page=20"
		"bitbucket":
			return "https://api.bitbucket.org/2.0/repositories/" + path + "/pullrequests?state=OPEN&pagelen=20"
	return ""


# Phase 5: normalize one open-PR API entry to
# { number, title, author, url }. Returns {} for unrecognized shapes.
static func parse_pr_entry(entry: Dictionary, provider: String) -> Dictionary:
	if entry.is_empty():
		return {}
	match String(provider):
		"github":
			if not entry.has("html_url"):
				return {}
			var user := _as_dict(entry.get("user", {}))
			return {
				"number": int(entry.get("number", 0)),
				"title": String(entry.get("title", "")),
				"author": String(user.get("login", "")),
				"url": String(entry.get("html_url", "")),
			}
		"gitlab":
			if not entry.has("web_url"):
				return {}
			var author := _as_dict(entry.get("author", {}))
			return {
				"number": int(entry.get("iid", entry.get("id", 0))),
				"title": String(entry.get("title", "")),
				"author": String(author.get("username", author.get("name", ""))),
				"url": String(entry.get("web_url", "")),
			}
		"bitbucket":
			var links := _as_dict(entry.get("links", {}))
			var html := _as_dict(links.get("html", {}))
			var bb_author := _as_dict(entry.get("author", {}))
			return {
				"number": int(entry.get("id", 0)),
				"title": String(entry.get("title", "")),
				"author": String(bb_author.get("display_name", bb_author.get("nickname", ""))),
				"url": String(html.get("href", "")),
			}
	return {}


# Assign a visual lane to every commit (mutates the dicts in place) and
# return the number of lanes used (max lane index + 1, at least 1).
#
# Classic active-lane walk over topo-ordered commits: the commit reuses the
# lane its hash already occupies (or the first freed lane); the first
# parent continues on that lane while extra parents open new lanes.
# Each commit records `connections` ([{ "to_lane": int }], one per parent)
# so the renderer can draw the edges into the next row without keeping the
# lane table around.
static func assign_lanes(commits: Array) -> int:
	var lanes: Array = []
	var max_used := 0
	for c in commits:
		var commit: Dictionary = c
		var hash_value := String(commit.get("hash", ""))
		var idx := lanes.find(hash_value)
		if idx == -1:
			idx = lanes.find("")
			if idx == -1:
				idx = lanes.size()
				lanes.append(hash_value)
			else:
				lanes[idx] = hash_value
		commit["lane"] = idx
		max_used = maxi(max_used, idx)
		var parents: Array = commit.get("parents", [])
		var connections: Array = []
		if parents.is_empty():
			# Root commit: the lane ends here.
			lanes[idx] = ""
		else:
			var first := String(parents[0])
			var first_lane := lanes.find(first)
			if first_lane != -1 and first_lane != idx:
				# First parent already flows on another lane (a branch
				# merging back): this lane ends, the edge bends across.
				lanes[idx] = ""
				connections.append({"to_lane": first_lane})
				max_used = maxi(max_used, first_lane)
			else:
				lanes[idx] = first
				connections.append({"to_lane": idx})
			for i in range(1, parents.size()):
				var parent_hash := String(parents[i])
				var parent_lane := lanes.find(parent_hash)
				if parent_lane == -1:
					parent_lane = lanes.find("")
					if parent_lane == -1:
						parent_lane = lanes.size()
						lanes.append("")
					lanes[parent_lane] = parent_hash
				connections.append({"to_lane": parent_lane})
				max_used = maxi(max_used, parent_lane)
		commit["connections"] = connections
	return max_used + 1
