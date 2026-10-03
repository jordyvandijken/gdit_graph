# Remote URL helpers for the sidepanel remotes dialog.
#
# Pure data functions (no git calls, no UI): host presets for the popular
# git hosting providers, remote-name / URL validation, and parsing of
# `git remote -v` output. Mirrors the shape of
# version_control_panel_utils.gd so the panel stays thin.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/sidepanel/remote_url_utils.gd").
extends RefCounted


# Host preset ids, in the order the dialog's host picker shows them.
# "custom" is always last: a free-form URL with no builder.
static func host_ids() -> PackedStringArray:
	return PackedStringArray(["github", "gitlab", "bitbucket", "custom"])


static func host_display_name(host_id: String) -> String:
	match String(host_id):
		"github":
			return "GitHub"
		"gitlab":
			return "GitLab"
		"bitbucket":
			return "Bitbucket"
	return "Custom URL"


# Where the "create an empty repository" button points per host. Repo
# creation itself happens on the host's website (no API tokens or CLI
# auth in the plugin); the user then pastes the resulting URL back here.
static func new_repo_page(host_id: String) -> String:
	match String(host_id):
		"github":
			return "https://github.com/new"
		"gitlab":
			return "https://gitlab.com/projects/new"
		"bitbucket":
			return "https://bitbucket.org/repo/create"
	return ""


# Build a clone URL from a preset host, protocol ("https"/"ssh"), and the
# owner + repo slugs typed in the dialog. Returns "" when the inputs are
# incomplete (the dialog then keeps the URL field untouched) or when the
# host is "custom" (the URL field is the only input there).
static func build_url(host_id: String, protocol: String, owner: String, repo: String) -> String:
	var host := String(host_id)
	if host == "custom":
		return ""
	var clean_owner := String(owner).strip_edges().trim_suffix("/")
	var clean_repo := String(repo).strip_edges().trim_suffix("/")
	if clean_owner.is_empty() or clean_repo.is_empty():
		return ""
	if clean_repo.ends_with(".git"):
		clean_repo = clean_repo.left(clean_repo.length() - 4)
	var path := "%s/%s" % [clean_owner, clean_repo]
	var proto := String(protocol).to_lower()
	if proto == "ssh":
		match host:
			"github":
				return "git@github.com:%s.git" % path
			"gitlab":
				return "git@gitlab.com:%s.git" % path
			"bitbucket":
				return "git@bitbucket.org:%s.git" % path
		return ""
	match host:
		"github":
			return "https://github.com/%s.git" % path
		"gitlab":
			return "https://gitlab.com/%s.git" % path
		"bitbucket":
			return "https://bitbucket.org/%s.git" % path
	return ""


# Inverse of build_url(): split a remote URL into {host, owner, repo}.
# Handles HTTPS ("https://github.com/owner/repo.git"), SSH scp-like
# ("git@github.com:owner/repo.git"), and ssh:// URLs for the three
# presets; anything else reports host "custom" with empty owner/repo.
# The .git suffix is stripped and never part of repo.
static func parse_host_parts(raw_url: String) -> Dictionary:
	var cleaned := String(raw_url).strip_edges()
	var result := {"host": "custom", "owner": "", "repo": ""}
	if cleaned.is_empty():
		return result
	var path := ""
	if cleaned.begins_with("git@github.com:"):
		result["host"] = "github"
		path = cleaned.substr(len("git@github.com:"))
	elif cleaned.begins_with("git@gitlab.com:"):
		result["host"] = "gitlab"
		path = cleaned.substr(len("git@gitlab.com:"))
	elif cleaned.begins_with("git@bitbucket.org:"):
		result["host"] = "bitbucket"
		path = cleaned.substr(len("git@bitbucket.org:"))
	else:
		var without_scheme := cleaned
		if "://" in cleaned:
			var parts := cleaned.split("://", true, 1)
			if parts.size() == 2:
				var host_and_path := String(parts[1])
				# ssh://git@github.com/owner/repo.git — drop user@.
				if "@" in host_and_path:
					host_and_path = String(host_and_path.split("@", true, 1)[1])
				if host_and_path.begins_with("github.com/"):
					result["host"] = "github"
					path = host_and_path.substr(len("github.com/"))
				elif host_and_path.begins_with("gitlab.com/"):
					result["host"] = "gitlab"
					path = host_and_path.substr(len("gitlab.com/"))
				elif host_and_path.begins_with("bitbucket.org/"):
					result["host"] = "bitbucket"
					path = host_and_path.substr(len("bitbucket.org/"))
				else:
					return result
			else:
				return result
		else:
			return result
	path = path.strip_edges().trim_suffix("/")
	if path.ends_with(".git"):
		path = path.left(path.length() - 4)
	var slugs := path.split("/", true, 1)
	if slugs.size() == 2 and not String(slugs[0]).is_empty() and not String(slugs[1]).is_empty() and "/" not in String(slugs[1]):
		result["owner"] = String(slugs[0])
		result["repo"] = String(slugs[1])
	else:
		# Recognized host but unexpected shape (subgroups, ports): keep
		# the host for tailored guidance, leave owner/repo empty.
		result["owner"] = ""
		result["repo"] = ""
	return result


# Validate a remote name. Git passes it as a separate argv element (no
# shell quoting involved), but whitespace/control characters still make
# confusing or broken config entries, so they are refused up front.
static func validate_remote_name(raw: String) -> Dictionary:
	var cleaned := String(raw).strip_edges()
	if cleaned.is_empty():
		return {"ok": false, "clean": "", "error": "Remote name is empty (e.g. \"origin\")."}
	for i in range(cleaned.length()):
		var code := cleaned.unicode_at(i)
		if code <= 32 or code == 127:
			return {"ok": false, "clean": "", "error": "Remote name must not contain whitespace."}
	# git check-ref-format rules that apply to remote names: no slash
	# sequences that break config parsing, no leading/trailing dots or
	# slashes, no "..", no "@{" (reflog syntax).
	if cleaned.begins_with("/") or cleaned.ends_with("/") or cleaned.begins_with(".") or cleaned.ends_with("."):
		return {"ok": false, "clean": "", "error": "Remote name must not start or end with \"/\" or \".\"."}
	if ".." in cleaned or "@{" in cleaned or "//" in cleaned:
		return {"ok": false, "clean": "", "error": "Remote name contains an illegal sequence (\"..\", \"//\" or \"@{\")."}
	return {"ok": true, "clean": cleaned, "error": ""}


# Validate a remote URL. Accepts https://, http://, ssh://, git@ scp-like,
# and local paths — anything without whitespace/control characters that
# has at least a host/path shape. Returns the cleaned URL.
static func validate_remote_url(raw: String) -> Dictionary:
	var cleaned := String(raw).strip_edges()
	if cleaned.is_empty():
		return {"ok": false, "clean": "", "error": "Remote URL is empty."}
	for i in range(cleaned.length()):
		var code := cleaned.unicode_at(i)
		if code <= 32 or code == 127:
			return {"ok": false, "clean": "", "error": "Remote URL must not contain whitespace."}
	var has_scheme := cleaned.contains("://")
	var looks_scp := cleaned.contains("@") and cleaned.contains(":")
	var looks_path := cleaned.contains("/") or cleaned.contains("\\")
	if not (has_scheme or looks_scp or looks_path):
		return {"ok": false, "clean": "", "error": "That does not look like a git URL (expected https://, git@host:..., or a path)."}
	return {"ok": true, "clean": cleaned, "error": ""}


# Parse `git remote -v` output into [{ name, fetch_url, push_url }]. Lines
# look like "origin\t<url> (fetch)". Each remote appears twice (fetch +
# push); the pair is merged into one entry, like GraphUtils.parse_remotes
# (kept local so the sidepanel does not preload the workpanel).
static func parse_remote_verbose(text: String) -> Array:
	var remotes: Array = []
	for line in String(text).split("\n"):
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
