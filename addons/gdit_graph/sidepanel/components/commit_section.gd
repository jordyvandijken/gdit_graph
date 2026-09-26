# Commit message + Commit button + options menu (sidepanel top, VSCode-like).
#
# Replaces the hand-built CommitBox: message TextEdit (Ctrl+Enter to commit,
# Ctrl+Down for history — handled by the panel), full-width accent Commit
# button, and the ▾ options menu (Commit, Commit & Push, Commit & Stage,
# Commit (Amend)). The accent styling moved here from the panel's
# _style_commit_button(); the panel keeps behavior (enablement, menu
# routing, history) via the exposed node refs.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/sidepanel/components/commit_section.gd").
@tool
extends VBoxContainer

signal commit_pressed
signal options_pressed

var message = null
var commit_button = null
var options_button = null
var options_menu = null


func _ready() -> void:
	message = get_node_or_null("CommitMessage")
	commit_button = get_node_or_null("CommitRow/CommitButton")
	options_button = get_node_or_null("CommitRow/CommitOptionsButton")
	options_menu = get_node_or_null("CommitRow/CommitOptionsButton/CommitOptionsMenu")
	_style_commit_button()
	if commit_button != null:
		commit_button.pressed.connect(func() -> void: commit_pressed.emit())
	if options_button != null:
		options_button.pressed.connect(func() -> void: options_pressed.emit())


func _style_commit_button() -> void:
	if commit_button == null:
		return
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("0e639c")
	normal.set_corner_radius_all(3)
	normal.content_margin_top = 6.0
	normal.content_margin_bottom = 6.0
	commit_button.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color("1177bb")
	commit_button.add_theme_stylebox_override("hover", hover)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color("0b4f7e")
	commit_button.add_theme_stylebox_override("pressed", pressed)
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(1, 1, 1, 0.08)
	commit_button.add_theme_stylebox_override("disabled", disabled)
	commit_button.add_theme_color_override("font_color", Color.WHITE)
	commit_button.add_theme_color_override("font_hover_color", Color.WHITE)
	commit_button.add_theme_color_override("font_pressed_color", Color.WHITE)
	commit_button.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.35))
