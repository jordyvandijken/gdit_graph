# Shared flat toolbar glyph button (sidepanel + graph tab).
#
# Replaces the duplicated `_make_toolbar_button()` factories that built a
# flat, focus-less Button with a glyph + tooltip in code. Structure lives in
# toolbar_button.tscn; this script only enforces the shared defaults and
# offers setup() so callers can configure instances after instantiate().
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/components/toolbar_button.gd").
@tool
extends Button


func _ready() -> void:
	_apply_defaults()


func _apply_defaults() -> void:
	flat = true
	focus_mode = Control.FOCUS_NONE


# Mirrors the old factory signature: glyph text + tooltip.
func setup(glyph: String, tip: String) -> void:
	_apply_defaults()
	text = glyph
	tooltip_text = tip
