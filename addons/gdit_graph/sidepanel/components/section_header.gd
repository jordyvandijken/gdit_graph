# Collapsible section header row for the sidepanel (Staged / Changes).
#
# Replaces the two hand-built HBoxContainers (staged_header, changes_header):
# toggle glyph + expanding title + action button + pill count badge.
# Toggle and badge are instances of the shared toolbar_button / badge scenes;
# the action button is a plain Button (text action, e.g. "Stage All").
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/sidepanel/components/section_header.gd").
@tool
extends HBoxContainer

signal toggle_pressed
signal action_pressed

var toggle_button = null
var title_label = null
var action_button = null
var badge = null


func _ready() -> void:
	toggle_button = get_node_or_null("Toggle")
	title_label = get_node_or_null("Title")
	action_button = get_node_or_null("Action")
	badge = get_node_or_null("Badge")
	if toggle_button != null:
		toggle_button.pressed.connect(func() -> void: toggle_pressed.emit())
	if action_button != null:
		action_button.pressed.connect(func() -> void: action_pressed.emit())


# Configure one instance (staged vs changes) after instantiate().
func setup(title_text: String, action_text: String) -> void:
	if title_label != null:
		title_label.text = title_text
	if action_button != null:
		action_button.text = action_text


func set_action_disabled(disabled: bool) -> void:
	if action_button != null:
		action_button.disabled = disabled


func set_count(n: int) -> void:
	if badge != null and badge.has_method("set_count"):
		badge.set_count(n)
	elif badge != null:
		badge.text = "%d" % n


func set_collapsed(collapsed: bool) -> void:
	if toggle_button != null:
		toggle_button.text = "▸" if collapsed else "▾"
