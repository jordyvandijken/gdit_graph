# Graph tab data helpers (Phase 1 MVP).
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
extends RefCounted


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
