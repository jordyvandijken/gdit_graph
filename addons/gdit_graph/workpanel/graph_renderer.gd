# Commit graph canvas (Phase 1 MVP: plan sections III.A core, IV rendering;
# Phase 2: right-click context requests; Phase 4: Ctrl+click comparison,
# find-match highlight, author avatars, display settings;
# Phase 5 polish: column visibility, resizable lanes, graph style options,
# accessibility mode; inline detail: reserves a vertical gap under the
# selected row where the panel positions its detail Control, with the branch
# lanes drawn continuing through the gap on the left).
#
# A Control with manual _draw() (the plan's recommended Option 1): one row
# per commit, branch lanes as colored verticals in the left gutter, upstream
# r=4 nodes (open circle for HEAD, ring + dot for stashes), then the
# description (head dot, grey ref pills with branch-colour icons, subject —
# bold on the HEAD row), and the date / author (+18px avatar) / hash cells
# in the row text colour (50% opacity when muted). Only visible rows draw
# (viewport culling via the host ScrollContainer).
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/graph_renderer.gd").
@tool
extends Control

signal commit_selected(commit)
signal commit_context_requested(commit)
signal commit_compare_requested(first, second)
signal commit_chip_activated(commit, ref, kind)
signal lane_width_changed(width)
signal column_widths_changed(date_w, author_w, commit_w)

const RendererGraphUtils = preload("res://addons/gdit_graph/workpanel/graph_utils.gd")
const RendererAvatars = preload("res://addons/gdit_graph/workpanel/avatar_manager.gd")

# Upstream grid metrics (web graph config + table CSS): grid 16x24,
# 13px rows, 12px ref labels. Lanes are points (not slots): lane N sits at
# PAD_L + N * lane_width, matching `p.x * grid.x + grid.offsetX`.
const ROW_H = 24.0
const HEADER_H = 30.0
const LANE_W_DEFAULT = 16.0
const LANE_W_MIN = 8.0
const LANE_W_MAX = 30.0
const PAD_L = 16.0
const NODE_R = 4.0
const LINE_W = 2.0
const RESIZE_GRAB = 6.0
const ROW_FONT_SIZE = 13
const CHIP_FONT_SIZE = 12
# Upstream .gitRef pill: 18px tall, 5px radius, 18px colour icon box, 5px
# text padding, 5px between pills. Grey translucent bg + grey border; the
# branch colour lives only in the icon box (and the active pill border).
const CHIP_H = 18.0
const CHIP_RADIUS = 5.0
const CHIP_ICON_BOX = 18.0
const CHIP_TEXT_PAD = 5.0
const CHIP_SPACING = 5.0
# Upstream .commitHeadDot: 6px dot + 2px ring in the branch colour at the
# description start of the HEAD row.
const HEAD_DOT_R = 4.0
const HEAD_DOT_ADV = 15.0
# Upstream row avatar: 18px image ahead of the author name.
const AVATAR_SIZE = 18.0
const AVATAR_GAP = 4.0
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
	Color(0.0, 0.52, 0.85),
	Color(0.85, 0.0, 0.56),
	Color(0.0, 0.85, 0.04),
	Color(0.85, 0.52, 0.0),
	Color(0.64, 0.0, 0.85),
	Color(1.0, 0.0, 0.0),
	Color(0.0, 0.85, 0.8),
	Color(0.88, 0.22, 0.91),
	Color(0.52, 0.85, 0.0),
	Color(0.86, 0.36, 0.14),
	Color(0.44, 0.14, 0.84),
	Color(1.0, 0.8, 0.0),
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
# Upstream .gitRef colours: translucent grey pill + grey border for every
# label kind (branch / remote / tag / stash); the row's branch colour tints
# only the icon box (and the active pill's border). The hit test reuses
# _chip_width so drawn and clickable rects always agree.
const CHIP_BG = Color(0.5, 0.5, 0.5, 0.15)
const CHIP_BORDER = Color(0.5, 0.5, 0.5, 0.75)

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
var date_mode = "datetime"
var fetch_avatars = false
var avatar_textures = {}
# Phase 5 polish settings.
var show_hash = true
var show_refs = true
var lane_width = LANE_W_DEFAULT
var line_style = "solid"
var graph_style = "rounded"
var node_shape = "auto"
var color_scheme = "default"
var accessibility_mode = false
var uncommitted_style = "open_uncommitted"
# Upstream muted rows (dim text for merges / non-ancestors of HEAD).
# Aligned with commits; recomputed by _refresh_muted() on every
# set_commits/set_head, so nothing else writes it.
var muted_rows = []
var mute_merges = true
var mute_non_ancestors = false
# Inline commit detail gap: the panel positions its detail Control between
# the selected row and the next. detail_index is the commit index the gap
# sits under (-1 = closed); detail_height is the gap height in pixels.
var detail_index = -1
var detail_height = 0.0
# Column-resize drag state (upstream: every column resizes; Phase 5 item
# 26 started with the lane gutter). _resize_col is "" when idle, else one
# of "lanes" | "date" | "author" | "commit".
var _resizing = false
var _resize_col = ""
var _hover_resize = false
var _hover_col = ""
# Manual per-column widths, 0 = auto (content-measured). Persisted via the
# column_widths_changed signal.
var date_col_w = 0.0
var author_col_w = 0.0
var commit_col_w = 0.0
const COL_W_MIN = 50.0
const COL_DATE_W_MAX = 300.0
const COL_AUTHOR_W_MAX = 250.0
const COL_COMMIT_W_MAX = 200.0
# Last computed table geometry (see _columns): reused by the resize hover
# test so mouse motion never re-measures every row's text.
var _last_cols = {}
# Shared pill background for ref chips (mutated per chip, drawn
# immediately): creating one StyleBoxFlat per chip per _draw would churn.
var _chip_style = null
# Shared avatar background, same reuse pattern as the chip style.
var _avatar_style = null
# Performance caches (all invalidated in set_commits; content widths also
# key off visibility flags + font): _hash_index maps commit hash -> row
# index so index_of_hash is O(1); _commits_rev/_content_key guard the
# measured author/commit column widths so _columns never re-measures every
# row's text per _draw; _gap_key/_cached_gap_lanes memoize the detail-gap
# lanes so _lanes_after is not replayed per frame; _chip_cache memoizes
# per-commit ref chips; _edge_cache memoizes tessellated rounded-edge
# point lists keyed by pixel shape.
var _hash_index = {}
var _commits_rev = 0
var _content_key = ""
var _cached_commit_content_w = 0.0
var _cached_author_content_w = 0.0
var _gap_key = ""
var _cached_gap_lanes = []
var _chip_cache = {}
var _edge_cache = {}
# Scroll/interaction perf caches: _trim_cache memoizes trimmed strings per
# (text, font size, pixel width) so scrolling redraws pay dict lookups;
# _cached_scroll avoids a get_parent() + cast per _draw; _cols_cache/_cols_key
# memoize table geometry (recomputed only when size/flags/widths change);
# _head_ancestors/_head_ancestors_key memoize HEAD reachability for tooltips;
# _last_tooltip_row skips rebuilding the tooltip when the hovered row did
# not change between mouse-motion events.
var _trim_cache = {}
var _cached_scroll = null
var _cols_cache = {}
var _cols_key = ""
var _head_ancestors = null
var _head_ancestors_key = ""
var _last_tooltip_row = -999


# Hot-reload migration (repo rule #242/#244/#245): when the editor reparses
# this @tool script, long-lived instances keep old field storage, so member
# vars added later read back as Nil until the plugin restarts. Normalize
# them to their defaults on every entry point instead of trusting the
# declared initializers.
func _ensure_migrated() -> void:
	if commits == null:
		commits = []
	if graph_style == null:
		graph_style = "rounded"
	if line_style == null:
		line_style = "solid"
	if node_shape == null:
		node_shape = "auto"
	if color_scheme == null:
		color_scheme = "default"
	if uncommitted_style == null:
		uncommitted_style = "open_uncommitted"
	if date_mode == null:
		date_mode = "datetime"
	if mute_merges == null:
		mute_merges = true
	if mute_non_ancestors == null:
		mute_non_ancestors = false
	if muted_rows == null:
		muted_rows = []
	if date_col_w == null:
		date_col_w = 0.0
	if author_col_w == null:
		author_col_w = 0.0
	if commit_col_w == null:
		commit_col_w = 0.0
	if _resize_col == null:
		_resize_col = ""
	if _hover_col == null:
		_hover_col = ""
	if _reach_cache_key == null:
		_reach_cache_key = ""
	if search_hits == null:
		search_hits = []
	if avatar_textures == null:
		avatar_textures = {}
	# Members added after the first hot-reload pass, and the float members a
	# Nil read would silently coerce to 0.0 (collapsing every lane onto
	# PAD_L and every column to zero width).
	if lane_width == null:
		lane_width = 12.0
	if _last_cols == null:
		_last_cols = {}
	if lane_count == null:
		lane_count = 1
	if show_refs == null:
		show_refs = true
	if show_author == null:
		show_author = true
	if show_hash == null:
		show_hash = true
	if show_date == null:
		show_date = true
	if accessibility_mode == null:
		accessibility_mode = false
	if detail_height == null:
		detail_height = 0.0
	if _hash_index == null:
		_hash_index = {}
	if _commits_rev == null:
		_commits_rev = 0
	if _content_key == null:
		_content_key = ""
	if _gap_key == null:
		_gap_key = ""
	if _cached_gap_lanes == null:
		_cached_gap_lanes = []
	if _chip_cache == null:
		_chip_cache = {}
	if _edge_cache == null:
		_edge_cache = {}
	if _trim_cache == null:
		_trim_cache = {}
	if _cols_cache == null:
		_cols_cache = {}
	if _cols_key == null:
		_cols_key = ""
	if _head_ancestors_key == null:
		_head_ancestors_key = ""
	if _last_tooltip_row == null:
		_last_tooltip_row = -999


func set_commits(list: Array) -> void:
	_ensure_migrated()
	commits = list
	_commits_rev = int(_commits_rev) + 1
	lane_count = 1
	_hash_index = {}
	for i in range(commits.size()):
		var commit: Dictionary = commits[i]
		lane_count = maxi(lane_count, int(commit.get("lane", 0)) + 1)
		for conn in commit.get("connections", []):
			lane_count = maxi(lane_count, int((conn as Dictionary).get("to_lane", 0)) + 1)
		# Hash -> row map for O(1) index_of_hash (first wins; hashes are
		# unique, the uncommitted "*" row included).
		var h := String(commit.get("hash", ""))
		if not h.is_empty() and not _hash_index.has(h):
			_hash_index[h] = i
	if selected >= commits.size():
		selected = commits.size() - 1
	if compare_selected >= commits.size():
		compare_selected = -1
	if detail_index >= commits.size():
		detail_index = -1
		detail_height = 0.0
	search_hits = []
	search_current = -1
	_reach_cache_key = ""
	# Commit identity changed: drop memoized ref chips, edge tessellations,
	# trimmed strings, column geometry and gap lanes (column content widths
	# re-key on _commits_rev lazily). HEAD reachability is re-derived lazily.
	_chip_cache = {}
	_edge_cache = {}
	_trim_cache = {}
	_cols_cache = {}
	_cols_key = ""
	_cached_gap_lanes = []
	_gap_key = ""
	_head_ancestors = null
	_head_ancestors_key = ""
	_last_tooltip_row = -999
	_refresh_muted()
	_update_min_size()
	queue_redraw()


func apply_settings(settings: Dictionary) -> void:
	_ensure_migrated()
	show_avatars = bool(settings.get("show_avatars", true))
	show_author = bool(settings.get("show_author", true))
	show_date = bool(settings.get("show_date", true))
	date_mode = String(settings.get("date_format", "datetime")).to_lower()
	fetch_avatars = bool(settings.get("fetch_avatars", false))
	show_hash = bool(settings.get("show_hash", true))
	show_refs = bool(settings.get("show_refs", true))
	set_lane_width(float(settings.get("lane_width", LANE_W_DEFAULT)))
	line_style = String(settings.get("line_style", "solid")).to_lower()
	graph_style = String(settings.get("graph_style", "rounded")).to_lower()
	if graph_style != "angular" and graph_style != "rounded":
		graph_style = "rounded"
	node_shape = String(settings.get("node_shape", "auto")).to_lower()
	color_scheme = String(settings.get("color_scheme", "default")).to_lower()
	accessibility_mode = bool(settings.get("accessibility_mode", false))
	uncommitted_style = String(settings.get("uncommitted_style", "open_uncommitted")).to_lower()
	if uncommitted_style != "open_head":
		uncommitted_style = "open_uncommitted"
	mute_merges = bool(settings.get("mute_merges", true))
	mute_non_ancestors = bool(settings.get("mute_non_ancestors", false))
	date_col_w = maxf(float(settings.get("date_col_w", 0.0)), 0.0)
	author_col_w = maxf(float(settings.get("author_col_w", 0.0)), 0.0)
	commit_col_w = maxf(float(settings.get("commit_col_w", 0.0)), 0.0)
	# Line style / lane geometry feed the memoized edge tessellations;
	# visibility + widths feed trimmed strings and column geometry.
	_edge_cache = {}
	_trim_cache = {}
	_cols_cache = {}
	_cols_key = ""
	_last_tooltip_row = -999
	_refresh_muted()
	queue_redraw()

func set_column_widths(date_w: float, author_w: float, commit_w: float) -> void:
	date_col_w = maxf(float(date_w), 0.0)
	author_col_w = maxf(float(author_w), 0.0)
	commit_col_w = maxf(float(commit_w), 0.0)
	_ensure_migrated()
	_trim_cache = {}
	_cols_cache = {}
	_cols_key = ""
	queue_redraw()


# Phase 5 column resize: clamped setter shared by settings apply and the
# drag handle (which emits lane_width_changed on release for persistence).
func set_lane_width(width: float) -> void:
	var clamped := clampf(float(width), LANE_W_MIN, LANE_W_MAX)
	if is_equal_approx(clamped, float(lane_width)):
		lane_width = clamped
		return
	lane_width = clamped
	# Lane x positions feed the memoized edge tessellations, column
	# geometry and trimmed description widths.
	_ensure_migrated()
	_edge_cache = {}
	_trim_cache = {}
	_cols_cache = {}
	_cols_key = ""
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

func set_head(hash_value: String) -> void:
	_ensure_migrated()
	head_hash = String(hash_value)
	_head_ancestors = null
	_head_ancestors_key = ""
	_last_tooltip_row = -999
	_refresh_muted()
	queue_redraw()


func index_of_hash(hash_value: String) -> int:
	_ensure_migrated()
	var key := String(hash_value)
	# O(1) map built in set_commits; validated because commit dicts can be
	# mutated in place between rebuilds, with a linear fallback.
	if not key.is_empty() and _hash_index.has(key):
		var idx := int(_hash_index[key])
		if idx >= 0 and idx < commits.size() and String((commits[idx] as Dictionary).get("hash", "")) == key:
			return idx
	for i in range(commits.size()):
		if String((commits[i] as Dictionary).get("hash", "")) == key:
			return i
	return -1


# Programmatic selection (keyboard navigation, find navigation). Selects
# the row, redraws, and returns the commit dict ({} when out of range).
# Does not emit — callers emit commit_selected themselves when details
# should follow.
func select_index(idx: int) -> Dictionary:
	_ensure_migrated()
	if idx < 0 or idx >= commits.size():
		return {}
	selected = idx
	queue_redraw()
	return commits[idx]


func selected_commit() -> Dictionary:
	if selected >= 0 and selected < commits.size():
		return commits[selected]
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
	_ensure_migrated()
	detail_index = index
	detail_height = maxf(float(height), 0.0)
	if detail_index < 0 or detail_index >= commits.size() or detail_height <= 0.0:
		detail_index = -1
		detail_height = 0.0
	_update_min_size()
	queue_redraw()


func clear_detail() -> void:
	_ensure_migrated()
	if detail_index == -1 and detail_height <= 0.0:
		return
	detail_index = -1
	detail_height = 0.0
	_update_min_size()
	queue_redraw()


func row_height() -> float:
	return ROW_H

# Left offset where the inline detail card should start: the measured
# Description start (same edge the resize handle uses), so the card lines
# up with the row text and the lanes stay visible to its left.
func detail_gutter_width() -> float:
	if not _last_cols.is_empty():
		return maxf(float(_last_cols.get("desc_x", text_x())), 0.0)
	return text_x()

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
	# O(1) lane lookup mirroring GraphUtils.assign_lanes: hash -> slot.
	var lane_pos := {}
	var upto := clampi(idx, 0, commits.size() - 1)
	for i in range(upto + 1):
		var commit: Dictionary = commits[i]
		var hash_value := String(commit.get("hash", ""))
		var li := int(lane_pos.get(hash_value, -1)) if not hash_value.is_empty() else -1
		if li == -1:
			li = lanes.find("")
			if li == -1:
				li = lanes.size()
				lanes.append(hash_value)
			else:
				lanes[li] = hash_value
			if not hash_value.is_empty():
				lane_pos[hash_value] = li
		var parents: Array = commit.get("parents", [])
		if parents.is_empty():
			lanes[li] = ""
			lane_pos.erase(hash_value)
		else:
			var first := String(parents[0])
			var fl := int(lane_pos.get(first, -1)) if not first.is_empty() else -1
			if fl != -1 and fl != li:
				lanes[li] = ""
				lane_pos.erase(hash_value)
			else:
				lanes[li] = first
				if hash_value != first:
					lane_pos.erase(hash_value)
					if not first.is_empty():
						lane_pos[first] = li
			for k in range(1, parents.size()):
				var ph := String(parents[k])
				var pl := int(lane_pos.get(ph, -1)) if not ph.is_empty() else -1
				if pl == -1:
					pl = lanes.find("")
					if pl == -1:
						pl = lanes.size()
						lanes.append("")
					lanes[pl] = ph
					if not ph.is_empty():
						lane_pos[ph] = pl
	return lanes


func set_search_hits(hits: Array, current: int = -1) -> void:
	_ensure_migrated()
	search_hits = hits
	search_current = current
	queue_redraw()


func clear_search() -> void:
	_ensure_migrated()
	search_hits = []
	search_current = -1
	queue_redraw()


func row_y(idx: int) -> float:
	_ensure_migrated()
	var y := HEADER_H + float(idx) * ROW_H
	if is_detail_visible() and idx > detail_index:
		y += detail_height
	return y


func lane_x(lane: int) -> float:
	return PAD_L + float(lane) * float(lane_width)


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


# Golden-ratio spillover: colour indices past the curated base map to
# maximally-distinct hues (any index yields a unique colour, so branch
# colours never wrap onto a live branch). `mono` is exempt and stays a
# single colour by design.
const GOLDEN_RATIO = 0.61803398875


func _palette_color(idx: int) -> Color:
	var pal := _active_palette()
	var i := absi(idx)
	if i < pal.size():
		return pal[i]
	if String(color_scheme) == "mono":
		return SCHEME_MONO[0]
	# Spillover hue walks the wheel in golden-ratio steps with a per-scheme
	# offset so extras do not reduplicate the base hues; saturation/value
	# stay vivid yet readable on both dark and light themes (light themes
	# get a darker value so pastels stay legible).
	var hue := fmod(float(i) * GOLDEN_RATIO + 0.08, 1.0)
	var sat := 0.72
	var val := 0.92
	match String(color_scheme):
		"warm":
			sat = 0.78
			val = 0.96
		"cool":
			sat = 0.62
			val = 0.95
		"high_contrast":
			sat = 0.95
			val = 1.0
	if not _is_dark_theme():
		val = minf(val * 0.78, 0.72)
	return Color.from_hsv(hue, sat, val)


func lane_color(lane: int) -> Color:
	return _palette_color(lane)


# Which halves of the own-lane vertical a row draws: [top, bottom].
# The uncommitted row hangs above the log, so it stubs downward toward the
# tip; the first data row has nothing above it, so it never draws upward;
# ending lanes (roots, merge-backs) stub upward only. Anything else would
# dangle a stub where no branch connects.
func _own_lane_halves(idx: int, commit: Dictionary) -> Array:
	if bool(commit.get("uncommitted", false)):
		return [false, true]
	var first_data := 0
	if not commits.is_empty() and bool((commits[0] as Dictionary).get("uncommitted", false)):
		first_data = 1
	var continues := (commit.get("parents", []) as Array).size() > 0 and not bool(commit.get("lane_ends", false))
	if idx == first_data:
		return [false, continues]
	var ends := (commit.get("parents", []) as Array).is_empty() or bool(commit.get("lane_ends", false))
	if ends:
		return [true, false]
	return [true, true]


# Upstream position-vs-colour split: the commit's branch colour index lives
# in `color` (see GraphUtils.assign_lanes); fall back to the lane slot for
# commits laid out before the upgrade. Indices are unbounded (one per
# branch); _palette_color maps any index to a distinct hue.
func commit_color(commit: Dictionary) -> Color:
	var idx := int(commit.get("color", commit.get("lane", 0)))
	return _palette_color(idx)


func is_row_muted(idx: int) -> bool:
	return idx >= 0 and idx < muted_rows.size() and bool(muted_rows[idx])

func _refresh_muted() -> void:
	_ensure_migrated()
	var mm: bool = true if mute_merges == null else bool(mute_merges)
	var mn: bool = false if mute_non_ancestors == null else bool(mute_non_ancestors)
	muted_rows = RendererGraphUtils.get_muted_commits(commits, head_hash, mm, mn)


func _lane_line_width() -> float:
	return LINE_W + (1.0 if accessibility_mode else 0.0)


# Shadow underlay for lane linework (upstream SVG `shadow` path, width 4
# in the editor background): a wider pass so crossing lanes stay readable
# on any theme.
func _draw_shadow_polyline(points: PackedVector2Array, width: float) -> void:
	if points.size() < 2:
		return
	draw_polyline(points, _graph_shadow(), width + 2.0, true)


# Graph bends: `rounded` is a cubic Bezier that commits to the target lane
# early (near-vertical by the row bottom, straight run into the endpoint);
# `angular` bends are upstream-style elbows (`d = 0.38 * row height`).
# `locked_first` picks which end owns the angular bend, straight from the
# upstream `lastPoint.x < curPoint.x` rule.
func _edge_points(from: Vector2, to: Vector2, locked_first: bool) -> PackedVector2Array:
	if is_equal_approx(from.x, to.x):
		return PackedVector2Array([from, to])
	if String(graph_style) == "angular":
		var d := ROW_H * 0.38
		if locked_first:
			return PackedVector2Array([from, Vector2(to.x, to.y - d), to])
		return PackedVector2Array([from, Vector2(from.x, from.y + d), to])
	# Rounded elbow-first bend: the horizontal travel completes inside a
	# short elbow (about a row and a half) right out of the node, then the
	# edge runs vertically into the target. Across tall detail gaps this
	# keeps the swoosh short instead of dragging a diagonal for hundreds
	# of pixels; adjacent rows keep the smooth single-curve shape.
	var dy := to.y - from.y
	if dy <= 1.0:
		return PackedVector2Array([from, to])
	# Memoize the tessellation by relative shape (perf): the curve depends
	# only on (dx, dy), so identical bends on different rows share one
	# tessellation instead of re-running the Bezier walk per edge per
	# _draw. Relative points are stored and translated by `from` on hits,
	# keeping the cache tiny (a handful of lane deltas x row gaps) and
	# immune to absolute row positions. set_commits and lane/style changes
	# clear the cache when geometry can move.
	_ensure_migrated()
	var dx := to.x - from.x
	var ekey := "r|%d|%d" % [int(round(dx)), int(round(dy))]
	if _edge_cache.has(ekey):
		var rel: PackedVector2Array = _edge_cache[ekey]
		var moved := PackedVector2Array()
		moved.resize(rel.size())
		for i in range(rel.size()):
			moved[i] = from + rel[i]
		return moved
	var elbow_h := minf(dy, ROW_H * 1.5)
	var elbow_end := Vector2(to.x, from.y + elbow_h)
	var d1 := minf(elbow_h * 0.25, 10.0)
	var d2 := elbow_h * 0.5
	var p1 := Vector2(to.x, from.y + d1)
	var p2 := Vector2(to.x, from.y + elbow_h - d2)
	var pts := PackedVector2Array()
	var steps := clampi(int(elbow_h / 2.0), 12, 24)
	for s in range(steps + 1):
		var t := float(s) / float(steps)
		var mt := 1.0 - t
		pts.append(
			mt * mt * mt * from + 3.0 * mt * mt * t * p1 + 3.0 * mt * t * t * p2 + t * t * t * elbow_end
		)
	# Straight vertical run down to the target (no-op duplicate when the
	# elbow already spans the whole hop, e.g. adjacent rows).
	if not pts[pts.size() - 1].is_equal_approx(to):
		pts.append(to)
	if _edge_cache.size() > 512:
		_edge_cache.clear()
	var stored := PackedVector2Array()
	stored.resize(pts.size())
	for i in range(pts.size()):
		stored[i] = pts[i] - from
	_edge_cache[ekey] = stored
	return pts


# Straight-segment equivalent of _draw_styled_polyline (see the size == 2
# fast path): identical dash/dot language for a single span, without the
# multi-segment distance-cursor walk.
func _draw_styled_segment(a: Vector2, b: Vector2, col: Color, width: float, style: String) -> void:
	var dist := a.distance_to(b)
	if dist <= 0.01:
		return
	var dir := (b - a) / dist
	if style == "dotted":
		var d := 0.0
		while d <= dist:
			draw_circle(a + dir * d, width * 0.55, col)
			d += 6.0
		return
	if style == "dashed":
		var d2 := 0.0
		while d2 < dist:
			var seg_end := minf(d2 + 6.0, dist)
			draw_line(a + dir * d2, a + dir * seg_end, col, width, true)
			d2 = seg_end + 4.0
		return
	draw_line(a, b, col, width, true)


# Styled polyline honouring the solid / dashed / dotted line setting along
# an already-tessellated point list.
func _draw_styled_polyline(points: PackedVector2Array, col: Color, width: float) -> void:
	if points.size() < 2:
		return
	var style := String(line_style)
	# Straight-segment fast path (lane verticals): the same dash/dot
	# language without the multi-segment cursor bookkeeping below.
	if points.size() == 2:
		_draw_styled_segment(points[0], points[1], col, width, style)
		return
	if style == "dotted":
		var step := 6.0
		# One distance cursor across the whole polyline, like the dashed
		# branch below: the dot phase has to carry across the tessellated
		# curve segments, or every segment restarts its phase at 0 and the
		# "dotted" style renders solid (a dot is drawn at each segment's
		# own start point).
		var pos := 0.0
		for s in range(points.size() - 1):
			var a := points[s]
			var b := points[s + 1]
			var dist := a.distance_to(b)
			if dist <= 0.01:
				continue
			var dir := (b - a) / dist
			var d := 0.0
			while d < dist:
				var phase := fmod(pos + d, step)
				if phase < step * 0.5:
					draw_circle(a + dir * d, width * 0.55, col)
				d += step - phase
			pos += dist
		return
	if style == "dashed":
		# Walk the whole polyline with one distance cursor so dashes stay
		# aligned across tessellated curve segments and long spans never
		# truncate after the first gap.
		var dash := 6.0
		var gap := 4.0
		var pattern := dash + gap
		var pos := 0.0
		for s in range(points.size() - 1):
			var a := points[s]
			var b := points[s + 1]
			var dist := a.distance_to(b)
			if dist <= 0.01:
				continue
			var dir := (b - a) / dist
			var d := 0.0
			while d < dist:
				var phase := fmod(pos + d, pattern)
				if phase < dash:
					var seg_end := minf(d + (dash - phase), dist)
					draw_line(a + dir * d, a + dir * seg_end, col, width, true)
					d = seg_end
				else:
					d = minf(d + (pattern - phase), dist)
			pos += dist
		return
	draw_polyline(points, col, width, true)


# Curved edge with shadow (upstream Branch.drawPath): shadow first, then the
# branch colour. Verticals stay straight; bends follow graph_style.
func _draw_edge(from: Vector2, to: Vector2, col: Color, width: float, locked_first: bool) -> void:
	var pts := _edge_points(from, to, locked_first)
	_draw_shadow_polyline(pts, width)
	_draw_styled_polyline(pts, col, width)


# Lane verticals (upstream: part of the branch path, same shadow treatment).
func _draw_lane_span(from: Vector2, to: Vector2, col: Color, width: float) -> void:
	var pts := PackedVector2Array([from, to])
	_draw_shadow_polyline(pts, width)
	_draw_styled_polyline(pts, col, width)


# Node glyph. Upstream draws uniform filled circles (`r=4`); HEAD/current is
# an open circle, stashes add an inner dot. "auto" now matches upstream
# (circles for merges too); "diamond" keeps the old merge language opt-in.
func _draw_node_shape(pos: Vector2, r: float, col: Color, is_merge: bool) -> void:
	var shape := String(node_shape)
	if shape == "square":
		draw_rect(Rect2(pos - Vector2(r, r), Vector2(r * 2.0, r * 2.0)), col)
		return
	if shape == "diamond":
		var rr := r + 2.0
		draw_colored_polygon(
			PackedVector2Array([Vector2(pos.x, pos.y - rr), Vector2(pos.x + rr, pos.y), Vector2(pos.x, pos.y + rr), Vector2(pos.x - rr, pos.y)]),
			col
		)
		return
	# "auto" and "circle" both draw upstream-style filled circles, merges
	# included (upstream has no diamond language; muted text + lane colour
	# carry the merge information instead).
	draw_circle(pos, r, col)


# Visible local-y band [top, bottom] from the hosting ScrollContainer
# (overscanned by one row). Falls back to the full content when the
# renderer is not inside a scroll view yet. The ScrollContainer reference
# is cached so every _draw does not pay get_parent() + cast + validity
# checks (the renderer is never reparented at runtime; a freed container
# re-resolves via the validity check).
func _visible_band() -> Vector2:
	var full := content_height()
	var sc: ScrollContainer = null
	var cached = _cached_scroll
	# The renderer is never reparented at runtime (it lives under the
	# panel's ScrollContainer for its whole lifetime), so a valid cached
	# reference stays correct; a fresh lookup only happens once and after
	# hot-reloads that clear the field via _ensure_migrated.
	if cached != null and is_instance_valid(cached) and cached is ScrollContainer:
		sc = cached
	else:
		sc = get_parent() as ScrollContainer
		_cached_scroll = sc
	if sc == null or not is_instance_valid(sc):
		return Vector2(0.0, full)
	# Before first layout the viewport reports no size: draw everything
	# rather than culling down to a couple of rows that never recover
	# (resize alone does not always re-run _draw).
	if sc.size.y <= 0.0:
		return Vector2(0.0, full)
	var top := float(sc.scroll_vertical) - ROW_H
	var bottom := float(sc.scroll_vertical) + maxf(sc.size.y, ROW_H) + ROW_H
	return Vector2(minf(maxf(top, 0.0), full), maxf(minf(bottom, full), 0.0))


# Which column edge the pointer grabs (upstream: every column resizes).
# Returns "lanes" | "date" | "author" | "commit" or "". Reuses the last
# drawn geometry so hover never re-measures text.
func _resize_target_at(pos: Vector2) -> String:
	if _last_cols.is_empty():
		var edge := text_x()
		return "lanes" if absf(pos.x - edge) <= RESIZE_GRAB else ""
	var desc_edge := float(_last_cols.get("desc_x", text_x()))
	if absf(pos.x - desc_edge) <= RESIZE_GRAB:
		return "lanes"
	if float(_last_cols.get("commit_w", 0.0)) > 0.0 and absf(pos.x - float(_last_cols.get("commit_x", 0.0))) <= RESIZE_GRAB:
		return "commit"
	if float(_last_cols.get("author_w", 0.0)) > 0.0 and absf(pos.x - float(_last_cols.get("author_x", 0.0))) <= RESIZE_GRAB:
		return "author"
	if float(_last_cols.get("date_w", 0.0)) > 0.0 and absf(pos.x - float(_last_cols.get("date_x", 0.0))) <= RESIZE_GRAB:
		return "date"
	return ""


func _resize_edge_x(col: String) -> float:
	if _last_cols.is_empty():
		return text_x()
	match String(col):
		"commit":
			return float(_last_cols.get("commit_x", text_x()))
		"author":
			return float(_last_cols.get("author_x", text_x()))
		"date":
			return float(_last_cols.get("date_x", text_x()))
	return float(_last_cols.get("desc_x", text_x()))

func _update_min_size() -> void:
	custom_minimum_size = Vector2(0, maxf(content_height(), HEADER_H + ROW_H))


func _font() -> Font:
	return get_theme_default_font()


func _font_size() -> int:
	return ROW_FONT_SIZE


func _base_color() -> Color:
	if has_theme_color("font_color", "Label"):
		return get_theme_color("font_color", "Label")
	return Color(0.92, 0.92, 0.92)


func _dim_color() -> Color:
	if has_theme_color("font_disabled_color", "Label"):
		return get_theme_color("font_disabled_color", "Label")
	return Color(0.6, 0.6, 0.6)


func _chip_font_size() -> int:
	return CHIP_FONT_SIZE


# Light editor text on a dark background (the common case) or the reverse.
func _is_dark_theme() -> bool:
	return _base_color().get_luminance() > 0.5


# Upstream `path.shadow` uses the editor background so lanes separate
# cleanly on any theme; approximate it from the theme direction since the
# canvas has no background stylebox to sample.
func _graph_shadow() -> Color:
	if _is_dark_theme():
		return Color(0, 0, 0, 0.4)
	return Color(1, 1, 1, 0.7)


# Opaque canvas-colour counterpart of the shadow, for glyphs drawn on top
# of the branch-colour icon boxes (upstream `fill: editor-background`).
func _icon_glyph_color() -> Color:
	if _is_dark_theme():
		return Color(0.1, 0.1, 0.12)
	return Color(0.95, 0.95, 0.95)


# Upstream `.mute` renders row text at 50% opacity rather than swapping to
# the dim colour, so it stays correct on light and dark themes alike.
func _muted_col(col: Color) -> Color:
	var faded := col
	faded.a *= 0.5
	return faded


# Faux-bold for the HEAD / uncommitted subject (upstream bolds the current
# row; the canvas has no bold font handle, so overprint with a sub-pixel
# offset like code-review markers elsewhere do).
func _draw_string_bold(font: Font, pos: Vector2, text: String, font_size: int, color: Color) -> void:
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
	draw_string(font, pos + Vector2(0.75, 0.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _draw() -> void:
	_ensure_migrated()
	var font := _font()
	var font_size := _font_size()
	var cols := _columns(font, font_size)
	_last_cols = cols
	_draw_header(font, font_size, cols)
	if commits.is_empty():
		var ty := HEADER_H + (ROW_H + font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
		draw_string(font, Vector2(PAD_L, ty), "No commits loaded.", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, _dim_color())
		return
	# Viewport culling (plan VII): skip rows fully outside the scroll view.
	# Header, separators and the detail gap still span the full height.
	var band := _visible_band()
	for i in range(commits.size()):
		var ry := row_y(i)
		if ry + ROW_H < band.x or ry > band.y:
			continue
		_draw_row(i, font, font_size, cols)
	_draw_detail_gap()
	_draw_column_separators(cols)
	# Column-resize affordance (upstream: every column edge): a faint grip
	# at the hovered/dragged edge while interacting with it.
	if _hover_resize or _resizing:
		var active := String(_resize_col) if _resizing else String(_hover_col)
		var gx := _resize_edge_x(active) - 4.0
		if active.is_empty():
			gx = float(cols["desc_x"]) - 4.0
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
	var lw := _lane_line_width()
	for entry in _gap_lanes():
		var info: Dictionary = entry
		var l := int(info.get("lane", 0))
		_draw_lane_span(Vector2(lane_x(l), top), Vector2(lane_x(l), bottom), lane_color(int(info.get("color", l))), lw)


# Lanes ([{lane, color}]) to continue through the inline detail gap. The
# detail row's own lane is excluded when it ends there (roots and
# merge-backs, via lane_ends): its branch stops at the node, so only the
# bend (if any) crosses the gap — otherwise a dead straight line doubles
# it for the whole height of the open details.
func _gap_lanes() -> Array:
	var out: Array = []
	if not is_detail_visible():
		return out
	# Memoized per (commits revision, gap position, gap height): the
	# _lanes_after fallback below replays lane assignment in O(detail_index)
	# and used to run on every _draw while details were open.
	_ensure_migrated()
	var key := "%d|%d|%d" % [int(_commits_rev), int(detail_index), int(round(float(detail_height)))]
	if key == String(_gap_key) and _cached_gap_lanes != null:
		return _cached_gap_lanes
	var gap_commit: Dictionary = commits[detail_index]
	if gap_commit.has("through"):
		var own_lane := int(gap_commit.get("lane", -1))
		var own_ended := bool(gap_commit.get("lane_ends", false)) or (gap_commit.get("parents", []) as Array).is_empty()
		var through: Array = gap_commit.get("through", [])
		var through_colors: Array = gap_commit.get("through_colors", [])
		for l in range(through.size()):
			if String(through[l]).is_empty():
				continue
			if l == own_lane and own_ended:
				continue
			out.append({"lane": l, "color": int(through_colors[l]) if l < through_colors.size() else l})
		_cached_gap_lanes = out
		_gap_key = key
		return out
	# Fallback replay already frees ended lanes (roots + merge-backs), so no
	# own-lane exclusion is needed on this path.
	var lanes := _lanes_after(detail_index)
	for l in range(lanes.size()):
		if String(lanes[l]).is_empty():
			continue
		out.append({"lane": l, "color": l})
	_cached_gap_lanes = out
	_gap_key = key
	return out


# Table geometry shared by the header and every row: the flexible
# Description column starts at the lane gutter, the Date / Author / Commit
# columns anchor to the right edge. Drawn inside one canvas so header and
# rows can never drift apart (no cross-control sync needed). Memoized per
# (width, lanes, visibility, manual widths, content revision, font): during
# scrolling nothing in the key changes, so repeats pay one dict lookup
# instead of re-measuring header strings every frame.
func _columns(font: Font, font_size: int) -> Dictionary:
	_ensure_migrated()
	var cache_key := "%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d" % [
		int(size.x), int(lane_count), int(round(float(lane_width) * 10.0)),
		int(show_hash), int(show_author), int(show_date),
		int(round(float(date_col_w))), int(round(float(author_col_w))), int(round(float(commit_col_w))),
		int(_commits_rev), int(font.get_instance_id()), int(font_size),
	]
	if cache_key == String(_cols_key) and _cols_cache != null and not (_cols_cache as Dictionary).is_empty():
		return _cols_cache
	# Graph column: wide enough for the lanes AND the "Graph" header text,
	# so the header is never cut off on few-lane pages.
	var gutter := text_x()
	var graph_min := PAD_L + font.get_string_size("Graph", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + COL_PAD
	var desc_x := maxf(gutter, graph_min)
	# Commit column: fits the header plus every short hash in full
	# (hashes are capped at COMMIT_MAX_CHARS when drawn, so measure capped).
	# The per-row measurement is cached (see _ensure_content_widths): it ran
	# O(n) font queries on every _draw before.
	var commit_content := font.get_string_size("Commit", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	if show_hash:
		_ensure_content_widths(font, font_size)
		commit_content = maxf(commit_content, _cached_commit_content_w)
	var commit_w := (commit_content + COL_PAD * 2.0) if show_hash else 0.0
	# Author column: shrinks to its content (never narrower than the
	# "Author" header), capped at AUTHOR_MAX_CHARS so one long name cannot
	# eat the Description column.
	var author_cap := font.get_string_size("M".repeat(AUTHOR_MAX_CHARS), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var author_content := font.get_string_size("Author", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	if show_author:
		_ensure_content_widths(font, font_size)
		author_content = maxf(author_content, _cached_author_content_w)
	var author_w := (minf(author_content, author_cap) + COL_PAD * 2.0) if show_author else 0.0
	var date_w := COL_DATE_W if show_date else 0.0
	# Manual per-column widths (upstream: every column resizes). Overrides
	# clamp so a drag can never collapse or overflow the table.
	if show_hash and commit_col_w > 0.0:
		commit_w = clampf(commit_col_w, COL_W_MIN, COL_COMMIT_W_MAX)
	if show_author and author_col_w > 0.0:
		author_w = clampf(author_col_w, COL_W_MIN, COL_AUTHOR_W_MAX)
	if show_date and date_col_w > 0.0:
		date_w = clampf(date_col_w, COL_W_MIN, COL_DATE_W_MAX)
	var commit_x := size.x - commit_w
	var author_x := commit_x - author_w
	var date_x := author_x - date_w
	var out := {
		"desc_x": desc_x,
		"date_x": date_x, "date_w": date_w,
		"author_x": author_x, "author_w": author_w,
		"commit_x": commit_x, "commit_w": commit_w,
	}
	_cols_cache = out
	_cols_key = cache_key
	return out


# Cached content measurement for _columns (perf): the widest short hash and
# author name across all commits. Recomputed only when the commit list
# revision, visibility flags, or font change — never per _draw.
func _ensure_content_widths(font: Font, font_size: int) -> void:
	_ensure_migrated()
	var key := "%d|%d|%d|%d|%d" % [int(_commits_rev), int(show_hash), int(show_author), int(font.get_instance_id()), int(font_size)]
	if key == String(_content_key):
		return
	var commit_w := 0.0
	if show_hash:
		for c in commits:
			var h := String((c as Dictionary).get("short", "")).left(COMMIT_MAX_CHARS)
			commit_w = maxf(commit_w, font.get_string_size(h, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	var author_w := 0.0
	if show_author:
		for c in commits:
			var a := String((c as Dictionary).get("author", ""))
			author_w = maxf(author_w, font.get_string_size(a, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	_cached_commit_content_w = commit_w
	_cached_author_content_w = author_w
	_content_key = key


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
		draw_rect(Rect2(0, y0, size.x, ROW_H), Color(0.5, 0.5, 0.5, 0.25))
	if i == compare_selected:
		draw_rect(Rect2(0, y0, size.x, ROW_H), Color(0.35, 0.65, 1.0, 0.16))
	if search_hits.has(i):
		if i == search_current:
			draw_rect(Rect2(0, y0, size.x, ROW_H), Color(1.0, 0.85, 0.3, 0.22))
		else:
			draw_rect(Rect2(0, y0, size.x, ROW_H), Color(1.0, 0.85, 0.3, 0.08))
	var lane := int(commit.get("lane", 0))
	var is_uncommitted_row := bool(commit.get("uncommitted", false))
	var is_stash_row := bool(commit.get("is_stash", false))
	# Uncommitted + stash rows render grey like upstream (#808080); normal
	# rows use their branch colour (upstream Branch/Vertex colours).
	var col := Color(0.5, 0.5, 0.5)
	if not is_uncommitted_row and not is_stash_row:
		col = commit_color(commit)
	var x := lane_x(lane)
	var lw := _lane_line_width()
	var is_head := String(commit.get("hash", "")) == head_hash and not head_hash.is_empty()
	# Lane vertical: full row when the lane continues, top-half stub for a
	# root commit whose lane ends here. The open_head uncommitted style
	# draws a dotted connector (upstream OpenCircleAtTheCheckedOutCommit).
	var parents: Array = commit.get("parents", [])
	var saved_line_style := String(line_style)
	if is_uncommitted_row and String(uncommitted_style) == "open_head":
		line_style = "dotted"
	# Through-lanes first (underneath): every other lane occupied during
	# this row keeps a continuous vertical, so branches reserved for parents
	# further down never vanish mid-graph. The row's own lane is drawn
	# after, with the root stub treatment when its lane ends here.
	var through: Array = commit.get("through", [])
	var through_colors: Array = commit.get("through_colors", [])
	for l in range(through.size()):
		if l == lane or String(through[l]).is_empty():
			continue
		var tc := int(through_colors[l]) if l < through_colors.size() else l
		_draw_lane_span(Vector2(lane_x(l), y0), Vector2(lane_x(l), y0 + ROW_H), lane_color(tc), lw)
	# Own-lane vertical halves (see _own_lane_halves): page edges and lane
	# ends leave one side empty so no stub dangles where nothing connects.
	var halves := _own_lane_halves(i, commit)
	if halves[0] and halves[1]:
		_draw_lane_span(Vector2(x, y0), Vector2(x, y0 + ROW_H), col, lw)
	elif halves[0]:
		_draw_lane_span(Vector2(x, y0), Vector2(x, cy), col, lw)
	elif halves[1]:
		_draw_lane_span(Vector2(x, cy), Vector2(x, y0 + ROW_H), col, lw)
	line_style = saved_line_style
	# Edges bending into the next row (merges / lane switches) as upstream
	# curves (rounded Bezier) or elbows (angular), owned by this commit's
	# branch colour. When the inline detail gap sits under this row, the
	# edge spans the gap so it still reaches the shifted next row (it stays
	# in the lane gutter, left of the detail content).
	for conn in commit.get("connections", []):
		var conn_dict: Dictionary = conn
		var to_lane := int(conn_dict.get("to_lane", lane))
		if to_lane == lane:
			continue
		var end_y := cy + ROW_H * 0.5
		if i == detail_index and is_detail_visible():
			if i + 1 < commits.size():
				end_y = row_y(i + 1) + ROW_H * 0.5
			else:
				end_y = detail_bottom()
		var locked := bool(conn_dict.get("locked_first", to_lane > lane))
		_draw_edge(Vector2(x, cy), Vector2(lane_x(to_lane), end_y), col, lw, locked)
	# Node glyph per the node_shape setting (+ white outline in
	# accessibility mode so shape never relies on color alone).
	# Upstream: filled r=4 nodes with a 1px background stroke separating
	# them from crossing lanes; HEAD/current is an open circle (r=4, width
	# 2) in the branch colour; stash rows are an outer ring + inner dot;
	# uncommitted follows the uncommitted_style.
	var shadow := _graph_shadow()
	if is_uncommitted_row:
		if String(uncommitted_style) == "open_head":
			draw_circle(Vector2(x, cy), NODE_R, Color(0.5, 0.5, 0.5))
		else:
			draw_arc(Vector2(x, cy), NODE_R, 0.0, TAU, 20, Color(0.5, 0.5, 0.5), 2.0, true)
	elif is_stash_row:
		draw_arc(Vector2(x, cy), NODE_R + 0.5, 0.0, TAU, 20, col, 2.0, true)
		draw_circle(Vector2(x, cy), 2.0, col)
	elif is_head:
		draw_arc(Vector2(x, cy), NODE_R, 0.0, TAU, 20, col, 2.0, true)
	else:
		# Background halo first (upstream `stroke: background` on nodes).
		draw_circle(Vector2(x, cy), NODE_R + 1.0, shadow)
		_draw_node_shape(Vector2(x, cy), NODE_R, col, parents.size() > 1)
		if accessibility_mode:
			draw_arc(Vector2(x, cy), NODE_R + 2.0, 0.0, TAU, 20, Color(1, 1, 1, 0.85), 1.5, true)
	if i == selected:
		draw_arc(Vector2(x, cy), NODE_R + 4.0, 0.0, TAU, 20, Color(1, 1, 1, 0.7), 1.5, true)
	_draw_row_text(commit, font, font_size, base, dim, cy, cols, i)


func _draw_row_text(commit: Dictionary, font: Font, font_size: int, base: Color, dim: Color, cy: float, cols: Dictionary, row_idx: int = -1) -> void:
	var baseline := cy + (font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
	var is_uncommitted := bool(commit.get("uncommitted", false))
	var is_stash := bool(commit.get("is_stash", false))
	var is_head := String(commit.get("hash", "")) == head_hash and not head_hash.is_empty()
	# Upstream `.mute`: row text at 50% opacity (all meta cells share it).
	var muted := row_idx >= 0 and is_row_muted(row_idx)
	var text_col := _muted_col(base) if muted else base
	# The row's branch colour tints the ref-label icons (upstream per-row
	# `--git-graph-color`); uncommitted/stash rows stay grey.
	var row_col := Color(0.5, 0.5, 0.5)
	if not is_uncommitted and not is_stash:
		row_col = commit_color(commit)
	# --- Description column: head dot, ref chips, subject (trimmed to the
	# column, never bleeding into Date / Author / Commit).
	var x := float(cols["desc_x"])
	var desc_right := float(cols["date_x"]) - COL_PAD
	if desc_right < x + 24.0:
		desc_right = x + 24.0
	if is_head and not is_uncommitted:
		_draw_head_dot(x + HEAD_DOT_ADV * 0.5, cy, row_col)
		x += HEAD_DOT_ADV
	if not is_uncommitted and show_refs:
		x = _draw_ref_chips(commit, font, x, baseline, cy, base, dim, row_col)
	var subject := String(commit.get("subject", ""))
	subject = _trim_to_width(font, font_size, subject, maxf(desc_right - x, 24.0))
	if is_uncommitted or is_head:
		_draw_string_bold(font, Vector2(x, baseline), subject, font_size, text_col)
	else:
		draw_string(font, Vector2(x, baseline), subject, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_col)
	# --- Date / Author / Commit columns, each clipped to its own cell.
	# The uncommitted row carries today's date but no author/hash ("*").
	if is_uncommitted:
		if show_date and float(cols["date_w"]) > 0.0 and String(commit.get("date", "")) != "":
			_draw_cell(font, font_size, baseline, float(cols["date_x"]), float(cols["date_w"]), RendererGraphUtils.format_graph_date(String(commit.get("date", "")), date_mode), text_col)
		_draw_cell(font, font_size, baseline, float(cols["author_x"]), float(cols["author_w"]), "*", text_col)
		_draw_cell(font, font_size, baseline, float(cols["commit_x"]), float(cols["commit_w"]), "*", text_col)
		return
	if show_date and float(cols["date_w"]) > 0.0 and String(commit.get("date", "")) != "":
		_draw_cell(font, font_size, baseline, float(cols["date_x"]), float(cols["date_w"]), RendererGraphUtils.format_graph_date(String(commit.get("date", "")), date_mode), text_col)
	if show_author and float(cols["author_w"]) > 0.0:
		_draw_author_cell(font, font_size, baseline, cy, float(cols["author_x"]), float(cols["author_w"]), commit, text_col)
	if show_hash and float(cols["commit_w"]) > 0.0:
		_draw_cell(font, font_size, baseline, float(cols["commit_x"]), float(cols["commit_w"]), String(commit.get("short", "")).left(COMMIT_MAX_CHARS), text_col)


# Upstream `.commitHeadDot`: open dot in the branch colour ahead of the
# HEAD row's description.
func _draw_head_dot(cx: float, cy: float, col: Color) -> void:
	draw_arc(Vector2(cx, cy), HEAD_DOT_R, 0.0, TAU, 16, col, 2.0, true)


# Upstream author cell: 18px avatar (fetched image, else generated colour
# + initials) ahead of the trimmed author name.
func _draw_author_cell(font: Font, font_size: int, baseline: float, cy: float, col_x: float, col_w: float, commit: Dictionary, text_col: Color) -> void:
	if col_w <= 0.0:
		return
	var x := col_x + COL_PAD
	var avail := col_w - COL_PAD * 2.0
	if show_avatars:
		_draw_author_avatar(commit, font, x, cy)
		x += AVATAR_SIZE + AVATAR_GAP
		avail -= AVATAR_SIZE + AVATAR_GAP
	var name := String(commit.get("author", "")).left(AUTHOR_MAX_CHARS)
	name = _trim_to_width(font, font_size, name, maxf(avail, 8.0))
	draw_string(font, Vector2(x, baseline), name, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_col)


# 18px author avatar: a cached Gravatar texture wins, else a deterministic
# colour rounded-rect with the author's initials (offline, stable).
func _draw_author_avatar(commit: Dictionary, font: Font, x: float, cy: float) -> void:
	var top := cy - AVATAR_SIZE * 0.5
	var email := String(commit.get("email", "")).strip_edges().to_lower()
	var author := String(commit.get("author", ""))
	var tex: Texture2D = avatar_textures.get(email, null) if not email.is_empty() else null
	if tex != null:
		draw_texture_rect(tex, Rect2(x, top, AVATAR_SIZE, AVATAR_SIZE), false)
		return
	if _avatar_style == null:
		_avatar_style = StyleBoxFlat.new()
		_avatar_style.set_corner_radius_all(4)
	_avatar_style.bg_color = RendererAvatars.color_for(author, email)
	draw_style_box(_avatar_style, Rect2(x, top, AVATAR_SIZE, AVATAR_SIZE))
	var initials := RendererAvatars.initials_for(author)
	var fs := 10
	var tw := font.get_string_size(initials, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	draw_string(
		font, Vector2(x + (AVATAR_SIZE - tw.x) * 0.5, cy + (font.get_ascent(fs) - font.get_descent(fs)) * 0.5 - 1.0),
		initials, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.08, 0.09, 0.12)
	)


# Memoized ref chips per commit hash (perf): chip layout is pure in the
# commit dict and dicts only change across set_commits, which clears this
# cache — so per-row _draw pays one dictionary lookup instead of rebuilding
# chip arrays (and re-running _claim_remotes) every frame. Accessibility
# note chips stay uncached: the caller appends them from the live setting.
func _cached_ref_chips(commit: Dictionary) -> Array:
	_ensure_migrated()
	var key := String(commit.get("hash", ""))
	if _chip_cache.has(key):
		return _chip_cache[key]
	var chips := _ref_chips(commit)
	_chip_cache[key] = chips
	return chips


# Ref chips for one commit in draw order: the stash selector first, then
# the current branch (active pill), other branches, bare remote-tracking
# branches, then tags. Remote-tracking names that match a local branch
# (`origin/main` for `main`) fold into that branch's pill as an italic
# suffix (upstream combineLocalAndRemoteBranchLabels, default on) instead
# of a second pill. Accessibility overlays are drawn by the caller and
# never enter this list (they are not clickable).
func _ref_chips(commit: Dictionary) -> Array:
	var refs: Dictionary = commit.get("refs", {})
	var current := String(refs.get("current", ""))
	var remote_names: Array = refs.get("remotes", [])
	var chips: Array = []
	var claimed := {}
	if bool(commit.get("is_stash", false)):
		var selector := String(commit.get("stash_selector", ""))
		var label := selector.substr(5) if selector.begins_with("stash") else selector
		if label.is_empty():
			label = "stash"
		chips.append({"text": label, "ref": selector, "kind": "stash", "current": false, "combined": []})
	if not current.is_empty():
		chips.append({"text": current, "ref": current, "kind": "branch", "current": true, "combined": _claim_remotes(current, remote_names, claimed)})
	for branch_name in refs.get("branches", []):
		var local_name := String(branch_name)
		if local_name == current:
			continue
		if local_name in remote_names:
			continue
		chips.append({"text": local_name, "ref": local_name, "kind": "branch", "current": false, "combined": _claim_remotes(local_name, remote_names, claimed)})
	for remote_name in remote_names:
		var bare := String(remote_name)
		if bare == current or claimed.has(bare):
			continue
		chips.append({"text": bare, "ref": bare, "kind": "branch", "current": false, "combined": []})
	for tag_name in refs.get("tags", []):
		chips.append({"text": String(tag_name), "ref": String(tag_name), "kind": "tag", "current": false, "combined": []})
	return chips


# Fold remote-tracking names belonging to a local branch into its pill.
func _claim_remotes(local: String, remotes: Array, claimed: Dictionary) -> Array:
	var out: Array = []
	if String(local).is_empty():
		return out
	for r in remotes:
		var remote_name := String(r)
		if claimed.has(remote_name) or remote_name == local:
			continue
		if remote_name.ends_with("/" + local):
			claimed[remote_name] = true
			out.append(remote_name)
	return out


func _chip_text_width(font: Font, chip: Dictionary) -> float:
	var fs := _chip_font_size()
	var w := font.get_string_size(String(chip.get("text", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	for remote_name in chip.get("combined", []):
		w += 9.0 + font.get_string_size(String(remote_name), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	return w


func _chip_width(font: Font, chip: Dictionary) -> float:
	if String(chip.get("kind", "branch")) == "note":
		return _chip_text_width(font, chip) + CHIP_TEXT_PAD * 2.0
	return CHIP_ICON_BOX + CHIP_TEXT_PAD + _chip_text_width(font, chip) + CHIP_TEXT_PAD


func _draw_ref_chips(commit: Dictionary, font: Font, x: float, baseline: float, cy: float, base: Color, dim: Color, row_col: Color) -> float:
	for chip in _cached_ref_chips(commit):
		x = _draw_chip(font, x, cy, baseline, chip, base, dim, row_col)
	# Accessibility tags: text cues that never rely on color alone.
	if accessibility_mode:
		var tags := PackedStringArray()
		if int((commit.get("parents", []) as Array).size()) > 1:
			tags.append("[merge]")
		if String(commit.get("hash", "")) == head_hash and not head_hash.is_empty():
			tags.append("[HEAD]")
		for tag_text in tags:
			x = _draw_chip(font, x, cy, baseline, {"text": tag_text, "kind": "note", "current": false, "combined": []}, base, dim, row_col)
	return x


# One upstream `.gitRef` pill: grey translucent body + grey border, 18px
# branch-colour icon box, 12px label. The checked-out branch gets the
# branch-colour border + bold label (upstream `.active`).
func _draw_chip(font: Font, x: float, cy: float, baseline: float, chip: Dictionary, base: Color, dim: Color, row_col: Color) -> float:
	var fs := _chip_font_size()
	var text := String(chip.get("text", ""))
	var kind := String(chip.get("kind", "branch"))
	var current := bool(chip.get("current", false))
	var w := _chip_width(font, chip)
	if _chip_style == null:
		_chip_style = StyleBoxFlat.new()
	_chip_style.set_corner_radius_all(int(CHIP_RADIUS))
	_chip_style.bg_color = CHIP_BG
	_chip_style.set_border_width_all(1)
	_chip_style.border_color = row_col if current else CHIP_BORDER
	draw_style_box(_chip_style, Rect2(x, cy - CHIP_H * 0.5, w, CHIP_H))
	var tx := x
	if kind != "note":
		draw_rect(Rect2(x, cy - CHIP_H * 0.5, CHIP_ICON_BOX, CHIP_H), row_col)
		_draw_chip_glyph(kind, x + CHIP_ICON_BOX * 0.5, cy, _icon_glyph_color())
		tx += CHIP_ICON_BOX + CHIP_TEXT_PAD
	else:
		tx += CHIP_TEXT_PAD
	if current:
		_draw_string_bold(font, Vector2(tx, baseline), text, fs, base)
	else:
		draw_string(font, Vector2(tx, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, base)
	tx += font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	# Combined remote suffixes: divider + dim names (upstream italic).
	for remote_name in chip.get("combined", []):
		var rx := tx + 4.0
		draw_line(Vector2(rx, cy - 5.0), Vector2(rx, cy + 5.0), CHIP_BORDER, 1.0)
		tx = rx + 5.0
		draw_string(font, Vector2(tx, baseline), String(remote_name), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, dim)
		tx += font.get_string_size(String(remote_name), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	return x + w + CHIP_SPACING


# Mini glyph centred in the 18px icon box: branch elbow, tag diamond, or
# stash crate, drawn in the canvas colour (upstream `fill: background`).
func _draw_chip_glyph(kind: String, cx: float, cy: float, color: Color) -> void:
	if kind == "tag":
		var r := 3.2
		draw_colored_polygon(
			PackedVector2Array([Vector2(cx, cy - r), Vector2(cx + r, cy), Vector2(cx, cy + r), Vector2(cx - r, cy)]),
			color
		)
	elif kind == "stash":
		draw_rect(Rect2(cx - 4.5, cy - 3.0, 9.0, 7.0), color, false, 1.5)
		draw_line(Vector2(cx - 4.5, cy - 1.0), Vector2(cx + 4.5, cy - 1.0), color, 1.5, true)
	else:
		draw_circle(Vector2(cx - 2.0, cy - 3.5), 2.0, color)
		draw_circle(Vector2(cx + 2.5, cy + 3.5), 2.0, color)
		draw_line(Vector2(cx - 2.0, cy - 3.5), Vector2(cx - 2.0, cy + 1.0), color, 1.5, true)
		draw_line(Vector2(cx - 2.0, cy + 1.0), Vector2(cx + 2.5, cy + 3.5), color, 1.5, true)


func _draw_cell(font: Font, font_size: int, baseline: float, col_x: float, col_w: float, text: String, color: Color) -> void:
	if col_w <= 0.0 or String(text).is_empty():
		return
	var shaped := _trim_to_width(font, font_size, String(text), maxf(col_w - COL_PAD * 2.0, 8.0))
	draw_string(font, Vector2(col_x + COL_PAD, baseline), shaped, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _trim_to_width(font: Font, font_size: int, text: String, avail: float) -> String:
	if text.is_empty():
		return text
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= avail:
		return text
	# Memoize per (text, font size, pixel width): scrolling redraws the same
	# rows at the same widths, so repeats pay one dictionary lookup instead
	# of re-measuring. Cleared in set_commits / apply_settings / resizes.
	_ensure_migrated()
	var cache_key := text + "\n" + str(font_size) + "\n" + str(int(avail))
	if _trim_cache.has(cache_key):
		return String(_trim_cache[cache_key])
	var ellipsis_w := font.get_string_size("…", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var budget := avail - ellipsis_w
	var result: String
	if budget <= 0.0:
		result = text.left(1)
	else:
		# Binary search the longest prefix fitting in budget: O(log n)
		# font queries instead of one per character.
		var lo := 0
		var hi := text.length()
		while lo + 1 < hi:
			var mid := (lo + hi) / 2
			var w := font.get_string_size(text.left(mid), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			if w <= budget:
				lo = mid
			else:
				hi = mid
		if lo <= 0:
			result = text.left(1)
		else:
			result = text.left(lo) + "…"
	if _trim_cache.size() > 2048:
		_trim_cache.clear()
	_trim_cache[cache_key] = result
	return result


func _tooltip_for(commit: Dictionary) -> String:
	if bool(commit.get("uncommitted", false)):
		return "Uncommitted Changes (*)\nWorking-tree changes — stage and commit from the Source Control panel."
	if bool(commit.get("is_stash", false)):
		var stash_lines := PackedStringArray()
		stash_lines.append("Stash: %s" % String(commit.get("subject", "")))
		stash_lines.append(String(commit.get("hash", "")))
		return "\n".join(stash_lines)
	var refs: Dictionary = commit.get("refs", {})
	var lines := PackedStringArray()
	lines.append("Commit %s" % RendererGraphUtils.commit_short(commit))
	lines.append(String(commit.get("subject", "")))
	lines.append("%s  %s" % [String(commit.get("author", "")), String(commit.get("date", ""))])
	# Upstream HEAD-inclusion line (web/graph.ts showTooltip): only when the
	# HEAD commit is part of the loaded page.
	if not String(head_hash).is_empty() and index_of_hash(head_hash) != -1:
		var reaches_head := _commit_reaches(commit, head_hash)
		lines.append("This commit is %sincluded in HEAD" % ["" if reaches_head else "not "])
	var branch_bits := PackedStringArray()
	for branch_name in refs.get("branches", []):
		branch_bits.append(String(branch_name))
	var tag_bits := PackedStringArray()
	for tag_name in refs.get("tags", []):
		tag_bits.append(String(tag_name))
	if not branch_bits.is_empty():
		lines.append("Branches: %s" % _limit_ref_list(branch_bits))
	if not tag_bits.is_empty():
		lines.append("Tags: %s" % _limit_ref_list(tag_bits))
	if not branch_bits.is_empty() or not tag_bits.is_empty():
		lines.append("Click a branch/tag chip to switch to it.")
	if int((commit.get("parents", []) as Array).size()) > 1:
		lines.append("Merge commit")
	if is_row_muted(index_of_hash(String(commit.get("hash", "")))):
		lines.append("Muted (see graph settings)")
	if accessibility_mode:
		lines.append("Lane %d" % int(commit.get("lane", 0)))
	return "\n".join(lines)


# Upstream tooltip caps ref lists at 10 (first 5 + ellipsis).
static func _limit_ref_list(items: PackedStringArray) -> String:
	if items.size() <= 10:
		return ", ".join(items)
	return ", ".join(items.slice(0, 5)) + ", …"


# Memoized HEAD-inclusion probe (tooltips fire per mouse-motion; the walk
# is bounded by the loaded page but must not re-run for the same row).
var _reach_cache_key = ""
# Untyped on purpose (repo rule for @tool fields): an inferred-typed member
# can disagree with its stored value after a hot reload and crash the script.
var _reach_cache_val = false


# True when `head_hash` is reachable by walking children links down from
# `commit` (i.e. the commit is an ancestor of HEAD on the loaded page).
func _commit_reaches(commit: Dictionary, target_hash: String) -> bool:
	var key := String(commit.get("hash", "")) + "\n" + String(target_hash)
	if key == String(_reach_cache_key):
		return bool(_reach_cache_val)
	var found := _commit_reaches_uncached(commit, target_hash)
	_reach_cache_key = key
	_reach_cache_val = found
	return found


# Memoized ancestor set for HEAD (tooltips fire per mouse-motion; the walk
# is bounded by the loaded page but must not re-run per hovered row).
# Re-derived lazily when the commit revision or HEAD changes.
func _ensure_head_ancestors() -> void:
	_ensure_migrated()
	var key := str(int(_commits_rev)) + "\n" + String(head_hash)
	if key == String(_head_ancestors_key) and _head_ancestors != null:
		return
	var ancestors := {}
	if not String(head_hash).is_empty() and commits != null and not (commits as Array).is_empty():
		var stack: Array = [String(head_hash)]
		while not stack.is_empty():
			var cur := String(stack.pop_back())
			if cur.is_empty() or ancestors.has(cur):
				continue
			ancestors[cur] = true
			# Reuse the O(1) hash map from set_commits instead of
			# rebuilding a lookup dict per tooltip.
			if not (_hash_index as Dictionary).has(cur):
				continue
			var idx := int((_hash_index as Dictionary)[cur])
			if idx < 0 or idx >= (commits as Array).size():
				continue
			if String(((commits as Array)[idx] as Dictionary).get("hash", "")) != cur:
				continue
			var parents: Array = (((commits as Array)[idx] as Dictionary).get("parents", []))
			for p in parents:
				stack.append(String(p))
	_head_ancestors = ancestors
	_head_ancestors_key = key


func _commit_reaches_uncached(commit: Dictionary, target_hash: String) -> bool:
	var start := String(commit.get("hash", ""))
	if start.is_empty() or String(target_hash).is_empty():
		return false
	if start == String(target_hash):
		return true
	# Fast path: HEAD reachability is one set lookup in the memoized
	# ancestor set (covers every tooltip call, which always targets HEAD).
	if String(target_hash) == String(head_hash):
		_ensure_head_ancestors()
		if _head_ancestors != null:
			return (_head_ancestors as Dictionary).has(start)
		return false
	if not (_hash_index as Dictionary).has(start) or not (_hash_index as Dictionary).has(String(target_hash)):
		return false
	# Walk up from the target through parents; reaching start means inclusion.
	var seen := {}
	var stack: Array = [String(target_hash)]
	while not stack.is_empty():
		var cur := String(stack.pop_back())
		if cur == start:
			return true
		if seen.has(cur):
			continue
		seen[cur] = true
		if not (_hash_index as Dictionary).has(cur):
			continue
		var cidx := int((_hash_index as Dictionary)[cur])
		if cidx < 0 or cidx >= (commits as Array).size():
			continue
		var parents: Array = ((((commits as Array)[cidx]) as Dictionary).get("parents", []))
		for p in parents:
			stack.append(String(p))
	return false


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


# Ref-chip hit test for click-to-switch. Replays the _draw_row_text chip
# layout (head dot, then _ref_chips) with the shared _chip_width, so the
# hit rects match the drawn pills. Returns {commit, ref, kind}
# ("branch" | "tag") or {} when no chip was hit. Stash and accessibility
# [merge]/[HEAD] chips are display-only and never hit.
func _chip_at(pos: Vector2) -> Dictionary:
	var idx := _row_at(pos)
	if idx < 0 or idx >= commits.size():
		return {}
	var commit: Dictionary = commits[idx]
	if bool(commit.get("uncommitted", false)):
		return {}
	if not show_refs:
		return {}
	var font := _font()
	var desc_x := text_x()
	if not _last_cols.is_empty():
		desc_x = float(_last_cols.get("desc_x", desc_x))
	var x := desc_x
	if String(commit.get("hash", "")) == head_hash and not head_hash.is_empty():
		x += HEAD_DOT_ADV
	for chip in _ref_chips(commit):
		var info: Dictionary = chip
		var kind := String(info.get("kind", "branch"))
		var w := _chip_width(font, info)
		if kind != "stash" and kind != "note" and pos.x >= x and pos.x <= x + w:
			return {"commit": commit, "ref": String(info.get("ref", "")), "kind": kind}
		x += w + CHIP_SPACING
	return {}


# Live-apply a column-edge drag. Lanes change lane_width; Date/Author/
# Commit change their manual width (right-anchored, so dragging the left
# edge grows/shrinks that column).
func _apply_resize_drag(mx: float) -> void:
	match String(_resize_col):
		"lanes":
			var lanes := float(maxi(lane_count, 1))
			set_lane_width((mx - PAD_L - 8.0) / lanes)
		"commit":
			commit_col_w = clampf(size.x - mx, COL_W_MIN, COL_COMMIT_W_MAX)
			queue_redraw()
		"author":
			if _last_cols.is_empty():
				return
			var commit_x := size.x - float(_last_cols.get("commit_w", 0.0))
			author_col_w = clampf(commit_x - mx, COL_W_MIN, COL_AUTHOR_W_MAX)
			queue_redraw()
		"date":
			if _last_cols.is_empty():
				return
			var author_x := size.x - float(_last_cols.get("commit_w", 0.0)) - float(_last_cols.get("author_w", 0.0))
			date_col_w = clampf(author_x - mx, COL_W_MIN, COL_DATE_W_MAX)
			queue_redraw()


func _gui_input(event: InputEvent) -> void:
	_ensure_migrated()
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		# Column resize drag takes over motion events.
		if _resizing:
			_apply_resize_drag(mm.position.x)
			accept_event()
			return
		# Tooltips rebuild strings + a HEAD-inclusion probe: only rebuild
		# when the hovered row actually changed between motion events.
		var hovered := _row_at(mm.position)
		# -2 is the inline-detail gap (not a commit row): no tooltip, and
		# no commits[-2] (the second-to-last row) leaking onto it. Only
		# rebuild the string when the hovered row actually changed.
		if hovered != int(_last_tooltip_row):
			_last_tooltip_row = hovered
			if hovered < 0 or hovered >= commits.size():
				tooltip_text = ""
			else:
				tooltip_text = _tooltip_for(commits[hovered])
		var hover_col := _resize_target_at(mm.position)
		var hover := not hover_col.is_empty()
		if hover != _hover_resize or hover_col != String(_hover_col):
			_hover_resize = hover
			_hover_col = hover_col
			queue_redraw()
		mouse_default_cursor_shape = Control.CURSOR_HSIZE if hover else Control.CURSOR_ARROW
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and _resizing:
			_resizing = false
			if String(_resize_col) == "lanes":
				lane_width_changed.emit(float(lane_width))
			else:
				column_widths_changed.emit(float(date_col_w), float(author_col_w), float(commit_col_w))
			_resize_col = ""
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			# Grab a column edge first — it wins over row select.
			var target := _resize_target_at(mb.position)
			if not target.is_empty():
				_resizing = true
				_resize_col = target
				_hover_resize = true
				_hover_col = target
				queue_redraw()
				accept_event()
				return
			# Chips are actions, not row selection: pressing one asks the
			# panel to switch to that ref (with confirmation) and never
			# opens the commit. The double-click press is swallowed too so
			# the prompt fires exactly once.
			var chip := _chip_at(mb.position)
			if not chip.is_empty():
				if not mb.double_click:
					commit_chip_activated.emit(chip["commit"], chip["ref"], chip["kind"])
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
