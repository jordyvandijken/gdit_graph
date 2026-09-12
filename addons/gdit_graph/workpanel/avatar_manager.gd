# Commit author avatars (Phase 4: plan sections III.A, V.22).
#
# Offline-first: every author gets a deterministic color + initials avatar
# rendered by graph_renderer.gd with zero network. Optional Gravatar
# fetching (settings toggle, default off) downloads the image once and
# caches the PNG under user:// so later loads are instant and the graph
# never stalls on HTTP. No threads here — the panel owns the HTTPRequest
# and drives it; this file only builds URLs/paths and hashes ids.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/avatar_manager.gd").
extends RefCounted

const CACHE_DIR = "user://gdit_graph_avatars"
const FETCH_SIZE = 64

# Small palette for generated avatars; the email hash picks the slot so an
# author keeps one stable color across sessions.
const AVATAR_COLORS = [
	Color(0.45, 0.75, 1.0),
	Color(0.55, 0.9, 0.55),
	Color(1.0, 0.75, 0.35),
	Color(1.0, 0.5, 0.55),
	Color(0.75, 0.6, 1.0),
	Color(0.45, 0.9, 0.85),
	Color(1.0, 0.95, 0.5),
	Color(1.0, 0.6, 0.35),
]


static func _norm_id(author: String, email: String) -> String:
	var mail := String(email).strip_edges().to_lower()
	if not mail.is_empty():
		return mail
	return String(author).strip_edges().to_lower()


static func color_for(author: String, email: String = "") -> Color:
	var id := _norm_id(author, email)
	if id.is_empty():
		return Color(0.5, 0.5, 0.5)
	var h := hash(id)
	return AVATAR_COLORS[absi(h) % AVATAR_COLORS.size()]


static func initials_for(author: String) -> String:
	var parts: PackedStringArray = String(author).strip_edges().split(" ", false)
	if parts.is_empty():
		return "?"
	if parts.size() == 1:
		return String(parts[0]).left(1).to_upper()
	return (String(parts[0]).left(1) + String(parts[1]).left(1)).to_upper()


static func gravatar_url(email: String, size: int = FETCH_SIZE) -> String:
	var mail := String(email).strip_edges().to_lower()
	if mail.is_empty():
		return ""
	# Gravatar hashes the trimmed lower-case address with MD5.
	var digest := mail.md5_text()
	return "https://www.gravatar.com/avatar/%s?s=%d&d=identicon" % [digest, maxi(size, 16)]


static func _safe_filename(email: String) -> String:
	var mail := String(email).strip_edges().to_lower()
	if mail.is_empty():
		return ""
	var out := ""
	for ch in mail:
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
		else:
			out += "_"
	return out.left(64)


static func cache_path_for(email: String) -> String:
	var safe := _safe_filename(email)
	if safe.is_empty():
		return ""
	return CACHE_DIR.path_join(safe + ".png")


static func load_cached_texture(email: String) -> Texture2D:
	var path := cache_path_for(email)
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)


static func save_cached_png(email: String, data: PackedByteArray) -> bool:
	if String(email).strip_edges().is_empty() or data.is_empty():
		return false
	var dir := DirAccess.open("user://")
	if dir != null and not dir.dir_exists("gdit_graph_avatars"):
		if dir.make_dir("gdit_graph_avatars") != OK:
			return false
	var img := Image.new()
	if img.load_png_from_buffer(data) != OK:
		return false
	return img.save_png(cache_path_for(email)) == OK
