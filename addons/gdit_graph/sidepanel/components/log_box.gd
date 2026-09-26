# Collapsible debug-log viewer for the sidepanel (⋯ menu → Debug log).
#
# Replaces the hand-built LogBox: title row with a Clear button over a
# read-only TextEdit fed from the panel's ring buffer. Hidden by default;
# the panel toggles visibility and pushes text via the exposed node ref.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/sidepanel/components/log_box.gd").
@tool
extends VBoxContainer

signal clear_pressed

var log_text = null


func _ready() -> void:
	log_text = get_node_or_null("LogText")
	var clear_btn = get_node_or_null("LogHeader/LogClearButton")
	if clear_btn != null:
		clear_btn.pressed.connect(func() -> void: clear_pressed.emit())


func set_log(text: String) -> void:
	if log_text != null:
		log_text.text = text
