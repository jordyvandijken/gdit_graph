# Inline unified-diff viewer (Phase 2: plan section V.10).
#
# A RichTextLabel that colorizes `git show <hash> -- <path>` output line by
# line: dim file/hunk headers, green additions, red deletions, cyan hunk
# markers. Pure view — the panel fetches diff text via GraphManager and
# pushes it here with set_diff(). Read-only with text selection enabled.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/commit_diff.gd").
@tool
extends RichTextLabel

# Extra line cap inside the widget: the manager already truncates by
# characters, this keeps BBCode parsing bounded for pathological inputs
# (e.g. minified single-line files exploded by --word-diff-less output).
const MAX_LINES = 2000

const ADD_COLOR = Color(0.45, 0.85, 0.45)
const DEL_COLOR = Color(1.0, 0.5, 0.55)
const HUNK_COLOR = Color(0.45, 0.75, 1.0)

var _dim = Color(0.6, 0.6, 0.6)


func _ready() -> void:
	bbcode_enabled = true
	scroll_active = true
	selection_enabled = true
	if has_theme_color("font_disabled_color", "Label"):
		_dim = get_theme_color("font_disabled_color", "Label")
	show_message("Select a file to view its diff.")


func _line_color_kind(line: String) -> String:
	if line.begins_with("@@"):
		return "hunk"
	if line.begins_with("+++ ") or line.begins_with("--- "):
		return "dim"
	if line.begins_with("diff --git") or line.begins_with("index "):
		return "dim"
	if line.begins_with("Binary files ") or line.begins_with("GIT binary patch"):
		return "hunk"
	if line.begins_with("+"):
		return "add"
	if line.begins_with("-"):
		return "del"
	if line.begins_with("\\ "):
		return "dim"
	return ""


func _kind_color(kind: String) -> Color:
	match kind:
		"add":
			return ADD_COLOR
		"del":
			return DEL_COLOR
		"hunk":
			return HUNK_COLOR
	return _dim


func set_loading() -> void:
	show_message("Loading diff...")


func show_message(msg: String) -> void:
	text = "[color=#%s]%s[/color]" % [_dim.to_html(false), String(msg).replace("[", "[lb]")]


func set_diff(diff_text: String, _truncated: bool = false) -> void:
	var raw := String(diff_text)
	if raw.strip_edges().is_empty():
		show_message("No diff available for this file (unchanged vs parent or binary).")
		return
	# The manager already appends its own truncation note to the text when
	# it caps characters, so the widget only needs its line cap here.
	var lines: PackedStringArray = raw.split("\n")
	var chunks := PackedStringArray()
	var count := 0
	for raw_line in lines:
		if count >= MAX_LINES:
			chunks.append("[color=#%s]... (%d more lines, diff too large to render)[/color]" % [_dim.to_html(false), lines.size() - count])
			break
		var line: String = String(raw_line).trim_suffix("\r")
		var escaped := line.replace("[", "[lb]")
		var kind := _line_color_kind(line)
		if kind.is_empty():
			chunks.append(escaped)
		else:
			chunks.append("[color=#%s]%s[/color]" % [_kind_color(kind).to_html(false), escaped])
		count += 1
	text = "\n".join(chunks)
