# Header bar for the sidepanel: "Source Control" title + quick actions.
#
# Replaces the hand-built HeaderBar: title label plus the pull / fetch /
# push / refresh / ⋯ toolbar buttons and the ⋯ overflow menu shell. The menu
# ITEMS stay populated by the panel (ids route to the panel's git handlers
# and their checked/disabled states are dynamic per popup).
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/sidepanel/components/header_bar.gd").
@tool
extends HBoxContainer

signal pull_pressed
signal fetch_pressed
signal push_pressed
signal refresh_pressed
signal actions_pressed

var title_label = null
var pull_button = null
var fetch_button = null
var push_button = null
var refresh_button = null
var actions_button = null
var actions_menu = null


func _ready() -> void:
	title_label = get_node_or_null("HeaderTitle")
	pull_button = get_node_or_null("HeaderPullButton")
	fetch_button = get_node_or_null("HeaderFetchButton")
	push_button = get_node_or_null("HeaderPushButton")
	refresh_button = get_node_or_null("RefreshButton")
	actions_button = get_node_or_null("GitActionsButton")
	actions_menu = get_node_or_null("GitActionsButton/GitActionsMenu")
	_connect_button(pull_button, "pull_pressed")
	_connect_button(fetch_button, "fetch_pressed")
	_connect_button(push_button, "push_pressed")
	_connect_button(refresh_button, "refresh_pressed")
	_connect_button(actions_button, "actions_pressed")


func _connect_button(button, signal_name: String) -> void:
	if button != null:
		button.pressed.connect(func() -> void: emit_signal(signal_name))


func set_remote_enabled(enabled: bool) -> void:
	if pull_button != null:
		pull_button.disabled = not enabled
	if fetch_button != null:
		fetch_button.disabled = not enabled
	if push_button != null:
		push_button.disabled = not enabled
