@tool
extends EditorPlugin

var panel: Control
var git_manager: GitManager
var graph_panel
var graph_manager
var graph_main_frame


func _enter_tree() -> void:
	git_manager = GitManager.new()
	git_manager.set_repo_path(ProjectSettings.globalize_path("res://"))
	panel = preload("res://addons/gdit_graph/sidepanel/gdit_graph_panel.tscn").instantiate()
	panel.name = "Git"
	if panel.has_method("set_git_manager"):
		panel.set_git_manager(git_manager)
	else:
		panel.set("git_manager", git_manager)
	add_control_to_dock(0, panel)
	panel.visible = true
	# Git Graph main-screen tab (top row, like Asset Store / Tasks): this
	# single EditorPlugin provides both the "Git" dock and the
	# "Git Graph" main screen (one plugin.cfg). The tab content lives in a
	# MarginContainer under the editor main screen (kanban_tasks pattern);
	# the graph panel owns no threads, the GraphManager below does.
	graph_manager = preload("res://addons/gdit_graph/workpanel/graph_manager.gd").new()
	graph_manager.set_repo_path(ProjectSettings.globalize_path("res://"))
	graph_panel = preload("res://addons/gdit_graph/workpanel/graph_panel.tscn").instantiate()
	if graph_panel.has_method("set_git_manager"):
		graph_panel.set_git_manager(graph_manager)
	else:
		graph_panel.set("git_manager", graph_manager)
	graph_main_frame = MarginContainer.new()
	graph_main_frame.add_theme_constant_override("margin_top", 5)
	graph_main_frame.add_theme_constant_override("margin_left", 5)
	graph_main_frame.add_theme_constant_override("margin_bottom", 5)
	graph_main_frame.add_theme_constant_override("margin_right", 5)
	graph_main_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	get_editor_interface().get_editor_main_screen().add_child(graph_main_frame)
	graph_main_frame.add_child(graph_panel)
	_make_visible(false)


func _exit_tree() -> void:
	if git_manager:
		git_manager.shutdown()
		git_manager = null
	if panel:
		remove_control_from_docks(panel)
		panel.queue_free()
		panel = null
	if graph_manager:
		graph_manager.shutdown()
		graph_manager = null
	if graph_main_frame:
		graph_main_frame.queue_free()
		graph_main_frame = null
	graph_panel = null


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if graph_main_frame:
		graph_main_frame.visible = visible


func _get_plugin_name() -> String:
	return "Git Graph"


func _get_plugin_icon() -> Texture2D:
	return preload("res://addons/gdit_graph/icons/git-icon.svg")
