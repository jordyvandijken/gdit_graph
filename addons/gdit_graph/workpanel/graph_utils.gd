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
# { hash, short, parents (Array[String]), author, date, subject,
#   refs: { head (bool), current (String), branches (Array[String]),
#           tags (Array[String]) },
#   lane (int, via assign_lanes), connections (Array, via assign_lanes) }.
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
		# the 7th field and the record is skipped below. Split the raw
		# record with maxsplit so short/tag-less lines still yield 7
		# fields, padding a missing trailing refs field with "".
		var fields: PackedStringArray = raw_record.split(fs, true, 6)
		while fields.size() < 7:
			fields.append("")
		if fields.size() != 7:
			continue
		for f in range(fields.size()):
			fields[f] = String(fields[f]).strip_edges()
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
			"author": String(fields[3]),
			"date": String(fields[4]),
			"subject": String(fields[5]),
			"refs": parse_ref_field(String(fields[6])),
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
static func message_to_bbcode(text: String) -> String:
	var escaped := String(text).replace("[", "[lb]")
	var url_re := RegEx.new()
	if url_re.compile("https?://[^\\s\\])]+") != OK:
		return escaped
	return url_re.sub(escaped, "[url]$0[/url]", true)


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
