# Commit graph canvas (Phase 1 MVP: plan sections III.A core, IV rendering;
# Phase 2: right-click context requests; Phase 4: Ctrl+click comparison,
# find-match highlight, author avatars, display settings).
#
# A Control with manual _draw() (the plan's recommended Option 1): one row
# per commit, branch lanes as colored verticals in the left gutter, node
# circles (diamonds for merges, ring for HEAD), then optional avatar, ref
# chips, short hash, subject, and dim author/date text. Viewport culling is
# future work; the default page size (200 rows) draws comfortably.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/graph_renderer.gd").
@tool
extends Control

signal commit_selected(commit)
signal commit_context_requested(commit)
signal commit_compare_requested(first, second)

const RendererGraphUtils = preload("res://addons/gdit_graph/workpanel/graph_utils.gd")
const RendererAvatars = preload("res://addons/gdit_graph/workpanel/avatar_manager.gd")

const ROW_H = 28.0
const LANE_W = 14.0
const PAD_L = 8.0
const NODE_R = 5.0
const LINE_W = 2.0

const PALETTE = [
	Color(0.45, 0.75, 1.0),
	Color(0.55, 0.9, 0.55),
	Color(1.0, 0.75, 0.35),
	Color(1.0, 0.5, 0.55),
	Color(0.75, 0.6, 1.0),
	Color(0.45, 0.9, 0.85),
	Color(1.0, 0.95, 0.5),
	Color(1.0, 0.6, 0.35),
]
const BRANCH_COLOR = Color(0.45, 0.85, 0.45)
const TAG_COLOR = Color(0.95, 0.8, 0.3)
const HEAD_RING_COLOR = Color(0.35, 0.65, 1.0)

var commits = []
var selected = -1
var compare_selected = -1
var head_hash = ""
var lane_count = 1
# Find-widget highlight: indices into commits + which one is current.
var search_hits = []
var search_current = -1
# Display settings (Phase 4 settings dialog; applied via apply_settings).
var show_avatars = true
var show_author = true
var show_date = true
var date_mode = "iso"
var fetch_avatars = false
var avatar_textures = {}


func set_commits(list: Array) -> void:
	commits = list
	lane_count = 1
	for c in commits:
		var commit: Dictionary = c
		lane_count = maxi(lane_count, int(commit.get("lane", 0)) + 1)
		for conn in commit.get("connections", []):
			lane_count = maxi(lane_count, int((conn as Dictionary).get("to_lane", 0)) + 1)
	if selected >= commits.size():
		selected = commits.size() - 1
	if compare_selected >= commits.size():
		compare_selected = -1
	search_hits = []
	search_current = -1
	_update_min_size()
	queue_redraw()


func apply_settings(settings: Dictionary) -> void:
	show_avatars = bool(settings.get("show_avatars", true))
	show_author = bool(settings.get("show_author", true))
	show_date = bool(settings.get("show_date", true))
	date_mode = String(settings.get("date_format", "iso"))
	fetch_avatars = bool(settings.get("fetch_avatars", false))
	queue_redraw()


func set_avatar_texture(email: String, texture: Texture2D) -> void:
	var key := String(email).strip_edges().to_lower()
	if key.is_empty():
		return
	if texture == null:
		avatar_textures.erase(key)
	else:
		avatar_textures[key] = texture
	queue_redraw()


func clear_avatar_textures() -> void:
	avatar_textures = {}
	queue_redraw()


func set_head(hash_value: String) -> void:
	head_hash = String(hash_value)
	queue_redraw()


func index_of_hash(hash_value: String) -> int:
	for i in range(commits.size()):
		if String((commits[i] as Dictionary).get("hash", "")) == hash_value:
			return i
	return -1


# Programmatic selection (keyboard navigation, find navigation). Selects
# the row, redraws, and returns the commit dict ({} when out of range).
# Does not emit — callers emit commit_selected themselves when details
# should follow.
func select_index(idx: int) -> Dictionary:
	if idx < 0 or idx >= commits.size():
		return {}
	selected = idx
	queue_redraw()
	return commits[idx]


func selected_commit() -> Dictionary:
	if selected >= 0 and selected < commits.size():
		return commits[selected]
	return {}


func compare_commit() -> Dictionary:
	if compare_selected >= 0 and compare_selected < commits.size():
		return commits[compare_selected]
	return {}


func clear_compare() -> void:
	compare_selected = -1
	queue_redraw()


func set_search_hits(hits: Array, current: int = -1) -> void:
	search_hits = hits
	search_current = current
	queue_redraw()


func clear_search() -> void:
	search_hits = []
	search_current = -1
	queue_redraw()


func row_y(idx: int) -> float:
	return float(idx) * ROW_H


func lane_x(lane: int) -> float:
	return PAD_L + float(lane) * LANE_W + LANE_W * 0.5


func text_x() -> float:
	return PAD_L + float(lane_count) * LANE_W + 8.0


func lane_color(lane: int) -> Color:
	return PALETTE[absi(lane) % PALETTE.size()]


func _update_min_size() -> void:
	custom_minimum_size = Vector2(0, float(maxi(commits.size(), 1)) * ROW_H)


func _font() -> Font:
	return get_theme_default_font()


func _font_size() -> int:
	return get_theme_default_font_size()


func _base_color() -> Color:
	if has_theme_color("font_color", "Label"):
		return get_theme_color("font_color", "Label")
	return Color(0.92, 0.92, 0.92)


func _dim_color() -> Color:
	if has_theme_color("font_disabled_color", "Label"):
		return get_theme_color("font_disabled_color", "Label")
	return Color(0.6, 0.6, 0.6)


func _draw() -> void:
	var font := _font()
	var font_size := _font_size()
	if commits.is_empty():
		var ty := (ROW_H + font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
		draw_string(font, Vector2(PAD_L, ty), "No commits loaded.", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, _dim_color())
		return
	for i in range(commits.size()):
		_draw_row(i, font, font_size)


func _draw_row(i: int, font: Font, font_size: int) -> void:
	var commit: Dictionary = commits[i]
	var y0 := float(i) * ROW_H
	var cy := y0 + ROW_H * 0.5
	var base := _base_color()
	var dim := _dim_color()
	if i == selected:
		draw_rect(Rect2(0, y0, size.x, ROW_H), Color(1, 1, 1, 0.08))
	if i == compare_selected:
		draw_rect(Rect2(0, y0, size.x, ROW_H), Color(0.35, 0.65, 1.0, 0.16))
	if search_hits.has(i):
		if i == search_current:
			draw_rect(Rect2(0, y0, size.x, ROW_H), Color(1.0, 0.85, 0.3, 0.22))
		else:
			draw_rect(Rect2(0, y0, size.x, ROW_H), Color(1.0, 0.85, 0.3, 0.08))
	var lane := int(commit.get("lane", 0))
	var col := lane_color(lane)
	var x := lane_x(lane)
	# Lane vertical: full row when the lane continues, top-half stub for a
	# root commit whose lane ends here.
	var parents: Array = commit.get("parents", [])
	if parents.is_empty():
		draw_line(Vector2(x, y0), Vector2(x, cy), col, LINE_W)
	else:
		draw_line(Vector2(x, y0), Vector2(x, y0 + ROW_H), col, LINE_W)
	# Edges bending into the next row (merges / lane switches).
	for conn in commit.get("connections", []):
		var to_lane := int((conn as Dictionary).get("to_lane", lane))
		if to_lane == lane:
			continue
		draw_line(Vector2(x, cy), Vector2(lane_x(to_lane), cy + ROW_H * 0.5), lane_color(to_lane), LINE_W)
	# Node: diamond for merges, circle otherwise.
	if parents.size() > 1:
		var r := NODE_R + 2.0
		draw_colored_polygon(
			PackedVector2Array([Vector2(x, cy - r), Vector2(x + r, cy), Vector2(x, cy + r), Vector2(x - r, cy)]),
			col
		)
	else:
		draw_circle(Vector2(x, cy), NODE_R, col)
	if String(commit.get("hash", "")) == head_hash and not head_hash.is_empty():
		draw_arc(Vector2(x, cy), NODE_R + 4.0, 0.0, TAU, 20, HEAD_RING_COLOR, 2.0)
	if i == selected:
		draw_arc(Vector2(x, cy), NODE_R + 4.0, 0.0, TAU, 20, Color(1, 1, 1, 0.7), 1.5)
	_draw_row_text(commit, font, font_size, base, dim, cy)


func _draw_row_text(commit: Dictionary, font: Font, font_size: int, base: Color, dim: Color, cy: float) -> void:
	var baseline := cy + (font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
	var x := text_x()
	var refs: Dictionary = commit.get("refs", {})
	# Author avatar: generated color + initials offline; a fetched Gravatar
	# texture replaces the circle when the panel has downloaded one.
	if show_avatars:
		x = _draw_avatar(commit, font, font_size, x, cy)
	# Ref chips: current branch, other branches, tags.
	if String(refs.get("current", "")) != "":
		x = _draw_chip(font, font_size, x, baseline, "[" + String(refs.get("current", "")) + "]", BRANCH_COLOR)
	for branch_name in refs.get("branches", []):
		if String(branch_name) != String(refs.get("current", "")):
			x = _draw_chip(font, font_size, x, baseline, String(branch_name), BRANCH_COLOR)
	for tag_name in refs.get("tags", []):
		x = _draw_chip(font, font_size, x, baseline, String(tag_name), TAG_COLOR)
	# Short hash (dim), subject, then dim author/date suffix.
	var short_hash := String(commit.get("short", ""))
	if not short_hash.is_empty():
		draw_string(font, Vector2(x, baseline), short_hash, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, dim)
		x += font.get_string_size(short_hash, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 8.0
	var suffix := ""
	if show_author:
		suffix = String(commit.get("author", ""))
	if show_date and String(commit.get("date", "")) != "":
		var date_text := RendererGraphUtils.format_graph_date(String(commit.get("date", "")), date_mode)
		suffix += ("  " + date_text) if not suffix.is_empty() else date_text
	var suffix_w := 0.0
	if not suffix.is_empty():
		suffix_w = font.get_string_size(suffix, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 8.0
	var subject := String(commit.get("subject", ""))
	subject = _trim_to_width(font, font_size, subject, maxf(size.x - x - 8.0 - suffix_w, 24.0))
	draw_string(font, Vector2(x, baseline), subject, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, base)
	x += font.get_string_size(subject, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 8.0
	if not suffix.is_empty():
		draw_string(font, Vector2(x, baseline), suffix, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, dim)


func _draw_chip(font: Font, font_size: int, x: float, baseline: float, text: String, color: Color) -> float:
	draw_string(font, Vector2(x, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
	return x + font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 6.0


# Avatar disc at the row-text start. A cached Gravatar texture wins; else a
# deterministic color disc with the author's initials (offline, stable per
# author). Returns the x offset past the avatar.
func _draw_avatar(commit: Dictionary, font: Font, font_size: int, x: float, cy: float) -> float:
	var r := 8.0
	var cx := x + r
	var email := String(commit.get("email", "")).strip_edges().to_lower()
	var author := String(commit.get("author", ""))
	var tex: Texture2D = avatar_textures.get(email, null) if not email.is_empty() else null
	if tex != null:
		var tex_size := tex.get_size()
		if tex_size.x > 0.0 and tex_size.y > 0.0:
			var scale_factor := (r * 2.0) / maxf(tex_size.x, tex_size.y)
			var draw_size := tex_size * scale_factor
			draw_set_transform(Vector2(cx - draw_size.x * 0.5, cy - draw_size.y * 0.5), 0.0, Vector2(scale_factor, scale_factor))
			draw_texture(tex, Vector2.ZERO)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			return x + r * 2.0 + 6.0
	draw_circle(Vector2(cx, cy), r, RendererAvatars.color_for(author, email))
	var initials := RendererAvatars.initials_for(author)
	var fs := maxi(font_size - 3, 8)
	var tw := font.get_string_size(initials, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var ty := cy + (font.get_ascent(fs) - font.get_descent(fs)) * 0.5 - 1.0
	draw_string(font, Vector2(cx - tw.x * 0.5, ty), initials, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.08, 0.09, 0.12))
	return x + r * 2.0 + 6.0


func _trim_to_width(font: Font, font_size: int, text: String, avail: float) -> String:
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= avail:
		return text
	var trimmed := text
	var guard := 0
	while trimmed.length() > 1 and guard < 400:
		trimmed = trimmed.left(trimmed.length() - 1)
		if font.get_string_size(trimmed + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= avail:
			return trimmed + "…"
		guard += 1
	return trimmed.left(1)


func _tooltip_for(commit: Dictionary) -> String:
	var refs: Dictionary = commit.get("refs", {})
	var lines := PackedStringArray()
	lines.append(String(commit.get("hash", "")))
	lines.append(String(commit.get("subject", "")))
	lines.append("%s  %s" % [String(commit.get("author", "")), String(commit.get("date", ""))])
	var ref_bits := PackedStringArray()
	for branch_name in refs.get("branches", []):
		ref_bits.append(String(branch_name))
	for tag_name in refs.get("tags", []):
		ref_bits.append("tag: " + String(tag_name))
	if not ref_bits.is_empty():
		lines.append(", ".join(ref_bits))
	if int((commit.get("parents", []) as Array).size()) > 1:
		lines.append("Merge commit")
	return "\n".join(lines)


func _row_at(pos: Vector2) -> int:
	var idx := int(floor(pos.y / ROW_H))
	if idx < 0 or idx >= commits.size():
		return -1
	return idx


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hovered := _row_at((event as InputEventMouseMotion).position)
		if hovered == -1:
			tooltip_text = ""
		else:
			tooltip_text = _tooltip_for(commits[hovered])
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			var idx := _row_at(mb.position)
			if idx != -1:
				# Ctrl+click pairs the row with the current selection for
				# the Phase 4 comparison view; a second Ctrl+click repairs.
				if mb.ctrl_pressed and selected != -1 and idx != selected:
					compare_selected = idx
					queue_redraw()
					commit_compare_requested.emit(commits[selected], commits[idx])
					accept_event()
					return
				selected = idx
				compare_selected = -1
				queue_redraw()
				commit_selected.emit(commits[idx])
				accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			# Right-click selects the row (so details follow) and asks the
			# panel for the Phase 2 context menu. Positioning uses the
			# screen-space cursor (see branch_menu), not the event pos.
			var ridx := _row_at(mb.position)
			if ridx != -1:
				selected = ridx
				queue_redraw()
				commit_selected.emit(commits[ridx])
				commit_context_requested.emit(commits[ridx])
				accept_event()
