# Commit graph canvas (Phase 1 MVP: plan sections III.A core, IV rendering;
# Phase 2: right-click context requests; Phase 4: Ctrl+click comparison,
# find-match highlight, author avatars, display settings;
# Phase 5 polish: column visibility, resizable lanes, graph style options,
# accessibility mode; inline detail: reserves a vertical gap under the
# selected row where the panel positions its detail Control, with the branch
# lanes drawn continuing through the gap on the left).
#
# A Control with manual _draw() (the plan's recommended Option 1): one row
# per commit, branch lanes as colored verticals in the left gutter, node
# shapes (per node_shape setting, ring for HEAD), then optional avatar, ref
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
signal lane_width_changed(width)

const RendererGraphUtils = preload("res://addons/gdit_graph/workpanel/graph_utils.gd")
const RendererAvatars = preload("res://addons/gdit_graph/workpanel/avatar_manager.gd")

const ROW_H = 28.0
const HEADER_H = 26.0
const LANE_W_DEFAULT = 14.0
const LANE_W_MIN = 8.0
const LANE_W_MAX = 30.0
const PAD_L = 8.0
const NODE_R = 5.0
const LINE_W = 2.0
const RESIZE_GRAB = 6.0
# VS Code-style table columns (Graph | Description | Date | Author | Commit).
# Description flexes; the meta columns anchor to the right edge so the
# in-canvas header and every row share one geometry. Hidden columns collapse
# to zero width via the show_date / show_author / show_hash settings.
const COL_DATE_W = 110.0
const COL_PAD = 8.0
# Content-sized column caps: Commit always fits a full short hash
# (COMMIT_MAX_CHARS), Author shrinks to its content up to AUTHOR_MAX_CHARS.
const COMMIT_MAX_CHARS = 8
const AUTHOR_MAX_CHARS = 15

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
const SCHEME_MONO = [
	Color(0.62, 0.72, 0.9),
	Color(0.62, 0.72, 0.9),
	Color(0.62, 0.72, 0.9),
	Color(0.62, 0.72, 0.9),
	Color(0.62, 0.72, 0.9),
	Color(0.62, 0.72, 0.9),
	Color(0.62, 0.72, 0.9),
	Color(0.62, 0.72, 0.9),
]
const SCHEME_WARM = [
	Color(1.0, 0.62, 0.3),
	Color(1.0, 0.75, 0.35),
	Color(1.0, 0.5, 0.55),
	Color(0.95, 0.4, 0.35),
	Color(1.0, 0.85, 0.45),
	Color(0.9, 0.55, 0.7),
	Color(1.0, 0.68, 0.5),
	Color(0.98, 0.8, 0.3),
]
const SCHEME_COOL = [
	Color(0.45, 0.75, 1.0),
	Color(0.45, 0.9, 0.85),
	Color(0.55, 0.65, 1.0),
	Color(0.4, 0.85, 0.6),
	Color(0.6, 0.85, 1.0),
	Color(0.5, 0.7, 0.95),
	Color(0.65, 0.95, 0.9),
	Color(0.55, 0.8, 1.0),
]
const SCHEME_HIGH_CONTRAST = [
	Color(0.3, 0.7, 1.0),
	Color(0.35, 1.0, 0.45),
	Color(1.0, 0.85, 0.2),
	Color(1.0, 0.35, 0.45),
	Color(0.75, 0.5, 1.0),
	Color(0.2, 1.0, 0.9),
	Color(1.0, 1.0, 1.0),
	Color(1.0, 0.6, 0.15),
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
# Phase 5 polish settings.
var show_hash = true
var show_refs = true
var lane_width = LANE_W_DEFAULT
var line_style = "solid"
var node_shape = "auto"
var color_scheme = "default"
var accessibility_mode = false
# Inline commit detail gap: the panel positions its detail Control between
# the selected row and the next. detail_index is the commit index the gap
# sits under (-1 = closed); detail_height is the gap height in pixels.
var detail_index = -1
var detail_height = 0.0
# Column-resize drag state (Phase 5 item 26).
var _resizing = false
var _hover_resize = false
# Last computed table geometry (see _columns): reused by the resize hover
# test so mouse motion never re-measures every row's text.
var _last_cols = {}


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
	if detail_index >= commits.size():
		detail_index = -1
		detail_height = 0.0
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
	show_hash = bool(settings.get("show_hash", true))
	show_refs = bool(settings.get("show_refs", true))
	set_lane_width(float(settings.get("lane_width", LANE_W_DEFAULT)))
	line_style = String(settings.get("line_style", "solid")).to_lower()
	node_shape = String(settings.get("node_shape", "auto")).to_lower()
	color_scheme = String(settings.get("color_scheme", "default")).to_lower()
	accessibility_mode = bool(settings.get("accessibility_mode", false))
	queue_redraw()


# Phase 5 column resize: clamped setter shared by settings apply and the
# drag handle (which emits lane_width_changed on release for persistence).
func set_lane_width(width: float) -> void:
	var clamped := clampf(float(width), LANE_W_MIN, LANE_W_MAX)
	if is_equal_approx(clamped, float(lane_width)):
		lane_width = clamped
		return
	lane_width = clamped
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


# --- Inline commit detail gap ---
#
# The detail panel is a separate Control (child of this canvas, so it
# scrolls with the rows). These helpers let the panel reserve the gap,
# position the panel, and keep the branch lanes visible through it.

func is_detail_visible() -> bool:
	return detail_index >= 0 and detail_index < commits.size() and detail_height > 0.0


func set_detail(index: int, height: float) -> void:
	detail_index = index
	detail_height = maxf(float(height), 0.0)
	if detail_index < 0 or detail_index >= commits.size() or detail_height <= 0.0:
		detail_index = -1
		detail_height = 0.0
	_update_min_size()
	queue_redraw()


func clear_detail() -> void:
	if detail_index == -1 and detail_height <= 0.0:
		return
	detail_index = -1
	detail_height = 0.0
	_update_min_size()
	queue_redraw()


func row_height() -> float:
	return ROW_H


func lane_area_width() -> float:
	return text_x()


# Left offset where the inline detail card should start: the measured
# Description start (same edge the resize handle uses), so the card lines
# up with the row text and the lanes stay visible to its left.
func detail_gutter_width() -> float:
	if not _last_cols.is_empty():
		return maxf(float(_last_cols.get("desc_x", text_x())), 0.0)
	return text_x()


func table_width() -> float:
	return size.x


func content_height() -> float:
	var h := HEADER_H + float(maxi(commits.size(), 0)) * ROW_H
	if is_detail_visible():
		h += detail_height
	return h


func detail_y() -> float:
	if not is_detail_visible():
		return -1.0
	return HEADER_H + float(detail_index + 1) * ROW_H


func detail_bottom() -> float:
	if not is_detail_visible():
		return -1.0
	return detail_y() + detail_height


# Lane table after processing commit idx (same walk as
# GraphUtils.assign_lanes, replayed so the gap knows which lanes stay
# open through it and can keep drawing them under the detail panel).
func _lanes_after(idx: int) -> Array:
	var lanes: Array = []
	if commits.is_empty():
		return lanes
	var upto := clampi(idx, 0, commits.size() - 1)
	for i in range(upto + 1):
		var commit: Dictionary = commits[i]
		var hash_value := String(commit.get("hash", ""))
		var li := lanes.find(hash_value)
		if li == -1:
			li = lanes.find("")
			if li == -1:
				li = lanes.size()
				lanes.append(hash_value)
			else:
				lanes[li] = hash_value
		var parents: Array = commit.get("parents", [])
		if parents.is_empty():
			lanes[li] = ""
		else:
			var first := String(parents[0])
			var fl := lanes.find(first)
			if fl != -1 and fl != li:
				lanes[li] = ""
			else:
				lanes[li] = first
			for k in range(1, parents.size()):
				var ph := String(parents[k])
				var pl := lanes.find(ph)
				if pl == -1:
					pl = lanes.find("")
					if pl == -1:
						pl = lanes.size()
						lanes.append("")
					lanes[pl] = ph
	return lanes


func set_search_hits(hits: Array, current: int = -1) -> void:
	search_hits = hits
	search_current = current
	queue_redraw()


func clear_search() -> void:
	search_hits = []
	search_current = -1
	queue_redraw()


func row_y(idx: int) -> float:
	var y := HEADER_H + float(idx) * ROW_H
	if is_detail_visible() and idx > detail_index:
		y += detail_height
	return y


func lane_x(lane: int) -> float:
	return PAD_L + float(lane) * float(lane_width) + float(lane_width) * 0.5


func text_x() -> float:
	return PAD_L + float(lane_count) * float(lane_width) + 8.0


func _active_palette() -> Array:
	match String(color_scheme):
		"mono":
			return SCHEME_MONO
		"warm":
			return SCHEME_WARM
		"cool":
			return SCHEME_COOL
		"high_contrast":
			return SCHEME_HIGH_CONTRAST
	return PALETTE


func lane_color(lane: int) -> Color:
	var pal := _active_palette()
	return pal[absi(lane) % pal.size()]


func _lane_line_width() -> float:
	return LINE_W + (1.0 if accessibility_mode else 0.0)


# Phase 5 graph style: solid / dashed / dotted lane segments.
func _draw_styled_line(from: Vector2, to: Vector2, col: Color, width: float) -> void:
	var style := String(line_style)
	if style == "dotted":
		var dist := from.distance_to(to)
		if dist <= 0.01:
			return
		var dir := (to - from) / dist
		var step := 6.0
		var d := 0.0
		while d <= dist:
			draw_circle(from + dir * d, width * 0.55, col)
			d += step
		return
	if style == "dashed":
		var dist := from.distance_to(to)
		if dist <= 0.01:
			return
		var dir := (to - from) / dist
		var dash := 6.0
		var gap := 4.0
		var d := 0.0
		while d < dist:
			var seg_end: float = minf(d + dash, dist)
			draw_line(from + dir * d, from + dir * seg_end, col, width)
			d += dash + gap
		return
	draw_line(from, to, col, width)


# Phase 5 graph style: node glyph. "auto" keeps the Phase 1 language
# (diamonds for merges, circles otherwise); the rest force one shape.
func _draw_node_shape(pos: Vector2, r: float, col: Color, is_merge: bool) -> void:
	var shape := String(node_shape)
	var want_diamond := is_merge if shape == "auto" else shape == "diamond"
	if shape == "square":
		draw_rect(Rect2(pos - Vector2(r, r), Vector2(r * 2.0, r * 2.0)), col)
		return
	if want_diamond:
		var rr := r + 2.0
		draw_colored_polygon(
			PackedVector2Array([Vector2(pos.x, pos.y - rr), Vector2(pos.x + rr, pos.y), Vector2(pos.x, pos.y + rr), Vector2(pos.x - rr, pos.y)]),
			col
		)
		return
	draw_circle(pos, r, col)


func _is_resize_handle(pos: Vector2) -> bool:
	# Gutter edge moved to the measured Description start (see _columns);
	# reuse the last drawn geometry so hover never re-measures text.
	var edge := text_x()
	if not _last_cols.is_empty():
		edge = float(_last_cols.get("desc_x", edge))
	return absf(pos.x - edge) <= RESIZE_GRAB


func _update_min_size() -> void:
	custom_minimum_size = Vector2(0, maxf(content_height(), HEADER_H + ROW_H))


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
	var cols := _columns(font, font_size)
	_last_cols = cols
	_draw_header(font, font_size, cols)
	if commits.is_empty():
		var ty := HEADER_H + (ROW_H + font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
		draw_string(font, Vector2(PAD_L, ty), "No commits loaded.", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, _dim_color())
		return
	for i in range(commits.size()):
		_draw_row(i, font, font_size, cols)
	_draw_detail_gap()
	_draw_column_separators(cols)
	# Column-resize affordance (Phase 5 item 26): a faint grip at the
	# lane/text boundary while hovering or dragging it.
	if _hover_resize or _resizing:
		var gx := float(cols["desc_x"]) - 4.0
		var grip := Color(1, 1, 1, 0.35 if _resizing else 0.18)
		draw_line(Vector2(gx, HEADER_H), Vector2(gx, content_height()), grip, 1.0)


# Lane continuations through the inline detail gap. The detail Control is
# a child of this canvas, so these lines draw underneath it: the gutter
# half stays visible through the panel's transparent left spacer while the
# card half is covered by the detail content on the right.
func _draw_detail_gap() -> void:
	if not is_detail_visible():
		return
	var top := detail_y()
	var bottom := detail_bottom()
	var edge := Color(1, 1, 1, 0.12)
	draw_line(Vector2(0, top), Vector2(size.x, top), edge, 1.0)
	draw_line(Vector2(0, bottom), Vector2(size.x, bottom), edge, 1.0)
	var lanes := _lanes_after(detail_index)
	var lw := _lane_line_width()
	for l in range(lanes.size()):
		if String(lanes[l]).is_empty():
			continue
		_draw_styled_line(Vector2(lane_x(l), top), Vector2(lane_x(l), bottom), lane_color(l), lw)


# Table geometry shared by the header and every row: the flexible
# Description column starts at the lane gutter, the Date / Author / Commit
# columns anchor to the right edge. Drawn inside one canvas so header and
# rows can never drift apart (no cross-control sync needed). Computed once
# per _draw and passed down (never per row) so long pages stay cheap.
func _columns(font: Font, font_size: int) -> Dictionary:
	# Graph column: wide enough for the lanes AND the "Graph" header text,
	# so the header is never cut off on few-lane pages.
	var gutter := text_x()
	var graph_min := PAD_L + font.get_string_size("Graph", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + COL_PAD
	var desc_x := maxf(gutter, graph_min)
	# Commit column: fits the header plus every short hash in full
	# (hashes are capped at COMMIT_MAX_CHARS when drawn, so measure capped).
	var commit_content := font.get_string_size("Commit", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	if show_hash:
		for c in commits:
			var h := String((c as Dictionary).get("short", "")).left(COMMIT_MAX_CHARS)
			commit_content = maxf(commit_content, font.get_string_size(h, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	var commit_w := (commit_content + COL_PAD * 2.0) if show_hash else 0.0
	# Author column: shrinks to its content (never narrower than the
	# "Author" header), capped at AUTHOR_MAX_CHARS so one long name cannot
	# eat the Description column.
	var author_cap := font.get_string_size("M".repeat(AUTHOR_MAX_CHARS), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var author_content := font.get_string_size("Author", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	if show_author:
		for c in commits:
			var a := String((c as Dictionary).get("author", ""))
			author_content = maxf(author_content, font.get_string_size(a, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	var author_w := (minf(author_content, author_cap) + COL_PAD * 2.0) if show_author else 0.0
	var date_w := COL_DATE_W if show_date else 0.0
	var commit_x := size.x - commit_w
	var author_x := commit_x - author_w
	var date_x := author_x - date_w
	return {
		"desc_x": desc_x,
		"date_x": date_x, "date_w": date_w,
		"author_x": author_x, "author_w": author_w,
		"commit_x": commit_x, "commit_w": commit_w,
	}


func _draw_header(font: Font, font_size: int, cols: Dictionary) -> void:
	var dim := _dim_color()
	var baseline := (HEADER_H + font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
	draw_string(font, Vector2(PAD_L, baseline), "Graph", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, dim)
	draw_string(font, Vector2(float(cols["desc_x"]), baseline), "Description", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, dim)
	if float(cols["date_w"]) > 0.0:
		draw_string(font, Vector2(float(cols["date_x"]) + COL_PAD, baseline), "Date", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, dim)
	if float(cols["author_w"]) > 0.0:
		draw_string(font, Vector2(float(cols["author_x"]) + COL_PAD, baseline), "Author", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, dim)
	if float(cols["commit_w"]) > 0.0:
		draw_string(font, Vector2(float(cols["commit_x"]) + COL_PAD, baseline), "Commit", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, dim)
	draw_line(Vector2(0, HEADER_H), Vector2(size.x, HEADER_H), Color(1, 1, 1, 0.12), 1.0)


func _draw_column_separators(cols: Dictionary) -> void:
	var top := HEADER_H
	var bottom := content_height()
	var sep := Color(1, 1, 1, 0.07)
	if float(cols["date_w"]) > 0.0:
		draw_line(Vector2(float(cols["date_x"]), top), Vector2(float(cols["date_x"]), bottom), sep, 1.0)
	if float(cols["author_w"]) > 0.0:
		draw_line(Vector2(float(cols["author_x"]), top), Vector2(float(cols["author_x"]), bottom), sep, 1.0)
	if float(cols["commit_w"]) > 0.0:
		draw_line(Vector2(float(cols["commit_x"]), top), Vector2(float(cols["commit_x"]), bottom), sep, 1.0)


func _draw_row(i: int, font: Font, font_size: int, cols: Dictionary) -> void:
	var commit: Dictionary = commits[i]
	var y0 := row_y(i)
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
	var lw := _lane_line_width()
	# Lane vertical: full row when the lane continues, top-half stub for a
	# root commit whose lane ends here.
	var parents: Array = commit.get("parents", [])
	if parents.is_empty():
		_draw_styled_line(Vector2(x, y0), Vector2(x, cy), col, lw)
	else:
		_draw_styled_line(Vector2(x, y0), Vector2(x, y0 + ROW_H), col, lw)
	# Edges bending into the next row (merges / lane switches). When the
	# inline detail gap sits under this row, the edge spans the gap so it
	# still reaches the shifted next row (it stays in the lane gutter, left
	# of the detail content).
	for conn in commit.get("connections", []):
		var to_lane := int((conn as Dictionary).get("to_lane", lane))
		if to_lane == lane:
			continue
		var end_y := cy + ROW_H * 0.5
		if i == detail_index and is_detail_visible():
			if i + 1 < commits.size():
				end_y = row_y(i + 1) + ROW_H * 0.5
			else:
				end_y = detail_bottom()
		_draw_styled_line(Vector2(x, cy), Vector2(lane_x(to_lane), end_y), lane_color(to_lane), lw)
	# Node glyph per the node_shape setting (+ white outline in
	# accessibility mode so shape never relies on color alone).
	# The uncommitted-changes pseudo-row is not a commit: a hollow ring
	# instead of a filled node.
	if bool(commit.get("uncommitted", false)):
		draw_arc(Vector2(x, cy), NODE_R + 1.0, 0.0, TAU, 20, Color(1, 1, 1, 0.9), 2.0)
	else:
		_draw_node_shape(Vector2(x, cy), NODE_R, col, parents.size() > 1)
		if accessibility_mode:
			draw_arc(Vector2(x, cy), NODE_R + 2.0, 0.0, TAU, 20, Color(1, 1, 1, 0.85), 1.5)
	if String(commit.get("hash", "")) == head_hash and not head_hash.is_empty():
		draw_arc(Vector2(x, cy), NODE_R + 4.0, 0.0, TAU, 20, HEAD_RING_COLOR, 2.0)
	if i == selected:
		draw_arc(Vector2(x, cy), NODE_R + 4.0, 0.0, TAU, 20, Color(1, 1, 1, 0.7), 1.5)
	_draw_row_text(commit, font, font_size, base, dim, cy, cols)


func _draw_row_text(commit: Dictionary, font: Font, font_size: int, base: Color, dim: Color, cy: float, cols: Dictionary) -> void:
	var baseline := cy + (font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
	var is_uncommitted := bool(commit.get("uncommitted", false))
	# --- Description column: avatar, ref chips, subject (trimmed to the
	# column, never bleeding into Date / Author / Commit).
	var x := float(cols["desc_x"])
	var desc_right := float(cols["date_x"]) - COL_PAD
	if desc_right < x + 24.0:
		desc_right = x + 24.0
	if is_uncommitted:
		x = _draw_uncommitted_glyph(font, font_size, x, cy)
	else:
		# Author avatar: generated color + initials offline; a fetched Gravatar
		# texture replaces the circle when the panel has downloaded one.
		if show_avatars:
			x = _draw_avatar(commit, font, font_size, x, cy)
		# Ref chips: current branch, other branches, tags (show_refs toggle).
		if show_refs:
			x = _draw_ref_chips(commit, font, font_size, x, baseline)
	var subject := String(commit.get("subject", ""))
	subject = _trim_to_width(font, font_size, subject, maxf(desc_right - x, 24.0))
	draw_string(font, Vector2(x, baseline), subject, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, base)
	# --- Date / Author / Commit columns, each clipped to its own cell.
	# The uncommitted row carries today's date but no author/hash ("*").
	if is_uncommitted:
		if show_date and float(cols["date_w"]) > 0.0 and String(commit.get("date", "")) != "":
			_draw_cell(font, font_size, baseline, float(cols["date_x"]), float(cols["date_w"]), RendererGraphUtils.format_graph_date(String(commit.get("date", "")), date_mode), dim)
		_draw_cell(font, font_size, baseline, float(cols["author_x"]), float(cols["author_w"]), "*", dim)
		_draw_cell(font, font_size, baseline, float(cols["commit_x"]), float(cols["commit_w"]), "*", dim)
		return
	if show_date and float(cols["date_w"]) > 0.0 and String(commit.get("date", "")) != "":
		_draw_cell(font, font_size, baseline, float(cols["date_x"]), float(cols["date_w"]), RendererGraphUtils.format_graph_date(String(commit.get("date", "")), date_mode), dim)
	if show_author and float(cols["author_w"]) > 0.0:
		_draw_cell(font, font_size, baseline, float(cols["author_x"]), float(cols["author_w"]), String(commit.get("author", "")).left(AUTHOR_MAX_CHARS), dim)
	if show_hash and float(cols["commit_w"]) > 0.0:
		_draw_cell(font, font_size, baseline, float(cols["commit_x"]), float(cols["commit_w"]), String(commit.get("short", "")).left(COMMIT_MAX_CHARS), dim)


func _draw_ref_chips(commit: Dictionary, font: Font, font_size: int, x: float, baseline: float) -> float:
	var refs: Dictionary = commit.get("refs", {})
	if String(refs.get("current", "")) != "":
		x = _draw_chip(font, font_size, x, baseline, "[" + String(refs.get("current", "")) + "]", BRANCH_COLOR)
	for branch_name in refs.get("branches", []):
		if String(branch_name) != String(refs.get("current", "")):
			x = _draw_chip(font, font_size, x, baseline, String(branch_name), BRANCH_COLOR)
	for tag_name in refs.get("tags", []):
		x = _draw_chip(font, font_size, x, baseline, String(tag_name), TAG_COLOR)
	# Accessibility tags: text cues that never rely on color alone.
	if accessibility_mode:
		var tags := PackedStringArray()
		if int((commit.get("parents", []) as Array).size()) > 1:
			tags.append("[merge]")
		if String(commit.get("hash", "")) == head_hash and not head_hash.is_empty():
			tags.append("[HEAD]")
		for tag_text in tags:
			x = _draw_chip(font, font_size, x, baseline, tag_text, Color(1, 1, 1, 0.9))
	return x


func _draw_cell(font: Font, font_size: int, baseline: float, col_x: float, col_w: float, text: String, color: Color) -> void:
	if col_w <= 0.0 or String(text).is_empty():
		return
	var shaped := _trim_to_width(font, font_size, String(text), maxf(col_w - COL_PAD * 2.0, 8.0))
	draw_string(font, Vector2(col_x + COL_PAD, baseline), shaped, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


# Glyph for the uncommitted-changes row: a hollow disc with "*" (no author,
# so no avatar color/initials apply).
func _draw_uncommitted_glyph(font: Font, font_size: int, x: float, cy: float) -> float:
	var r := 8.0
	var cx := x + r
	draw_arc(Vector2(cx, cy), r, 0.0, TAU, 20, Color(1, 1, 1, 0.7), 1.5)
	var fs := maxi(font_size - 3, 8)
	var tw := font.get_string_size("*", HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var ty := cy + (font.get_ascent(fs) - font.get_descent(fs)) * 0.5 - 1.0
	draw_string(font, Vector2(cx - tw.x * 0.5, ty), "*", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.85, 0.85, 0.85))
	return x + r * 2.0 + 6.0


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
	if bool(commit.get("uncommitted", false)):
		return "Uncommitted Changes (*)\nWorking-tree changes — stage and commit from the Source Control panel."
	var refs: Dictionary = commit.get("refs", {})
	var lines := PackedStringArray()
	lines.append(String(commit.get("hash", "")))
	lines.append(String(commit.get("subject", "")))
	lines.append("%s  %s" % [String(commit.get("author", "")), String(commit.get("date", ""))])
	if accessibility_mode:
		lines.append("Lane %d" % int(commit.get("lane", 0)))
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
	# Row 0 is the column header: never selectable. Returns -2 when the
	# position lands inside the inline detail gap (not a commit row).
	if pos.y < HEADER_H:
		return -1
	if is_detail_visible():
		var dy := detail_y()
		if pos.y >= dy and pos.y < dy + detail_height:
			return -2
		var y_adj := pos.y
		if pos.y >= dy + detail_height:
			y_adj -= detail_height
		var gap_idx := int(floor((y_adj - HEADER_H) / ROW_H))
		if gap_idx < 0 or gap_idx >= commits.size():
			return -1
		return gap_idx
	var idx := int(floor((pos.y - HEADER_H) / ROW_H))
	if idx < 0 or idx >= commits.size():
		return -1
	return idx


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		# Column resize drag (Phase 5 item 26) takes over motion events.
		if _resizing:
			var lanes := float(maxi(lane_count, 1))
			set_lane_width((mm.position.x - PAD_L - 8.0) / lanes)
			accept_event()
			return
		var hovered := _row_at(mm.position)
		if hovered < 0:
			tooltip_text = ""
		else:
			tooltip_text = _tooltip_for(commits[hovered])
		var hover := _is_resize_handle(mm.position)
		if hover != _hover_resize:
			_hover_resize = hover
			queue_redraw()
		mouse_default_cursor_shape = Control.CURSOR_HSIZE if hover else Control.CURSOR_ARROW
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and _resizing:
			_resizing = false
			lane_width_changed.emit(float(lane_width))
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			# Grab the lane/text boundary first — it wins over row select.
			if _is_resize_handle(mb.position):
				_resizing = true
				_hover_resize = true
				queue_redraw()
				accept_event()
				return
			var idx := _row_at(mb.position)
			if idx == -2:
				# Inside the inline detail gap: the detail Control owns
				# this area (the transparent gutter spacer lets the event
				# through). Swallow it so the row selection does not move.
				accept_event()
				return
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
			if ridx >= 0:
				var already: bool = ridx == selected
				selected = ridx
				queue_redraw()
				# When the row is already selected its details are
				# already open, so skip the emission: re-emitting would
				# toggle the inline panel shut right as the menu opens.
				if not already:
					commit_selected.emit(commits[ridx])
				commit_context_requested.emit(commits[ridx])
				accept_event()
