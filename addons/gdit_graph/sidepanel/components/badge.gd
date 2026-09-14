# Pill count badge for the sidepanel section headers (Staged / Changes).
#
# Replaces the `_make_badge()` factory that built a Label with a pill
# StyleBoxFlat in code. Structure lives in badge.tscn; this script applies
# the pill style and exposes set_count() so the panel stays data-driven.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/sidepanel/components/badge.gd").
@tool
extends Label


func _ready() -> void:
	_apply_pill()


func _apply_pill() -> void:
	var pill := StyleBoxFlat.new()
	pill.bg_color = Color(1, 1, 1, 0.14)
	pill.set_corner_radius_all(9)
	pill.content_margin_left = 8.0
	pill.content_margin_right = 8.0
	pill.content_margin_top = 1.0
	pill.content_margin_bottom = 1.0
	add_theme_stylebox_override("normal", pill)


func set_count(n: int) -> void:
	text = "%d" % n
