# .gitignore editor dialog for the sidepanel (⋯ menu → Edit .gitignore).
#
# Replaces the hand-built PopupPanel: title, multi-line TextEdit, and a
# Save/Cancel row. File IO stays in the panel; this component only owns the
# layout and forwards the button intents.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/sidepanel/components/ignore_dialog.gd").
@tool
extends PopupPanel

signal save_pressed
signal cancel_pressed

var ignore_text = null


func _ready() -> void:
	ignore_text = get_node_or_null("IgnoreBox/IgnoreText")
	var save_btn = get_node_or_null("IgnoreBox/IgnoreRow/IgnoreSaveButton")
	if save_btn != null:
		save_btn.pressed.connect(func() -> void: save_pressed.emit())
	var cancel_btn = get_node_or_null("IgnoreBox/IgnoreRow/IgnoreCancelButton")
	if cancel_btn != null:
		cancel_btn.pressed.connect(func() -> void: cancel_pressed.emit())
