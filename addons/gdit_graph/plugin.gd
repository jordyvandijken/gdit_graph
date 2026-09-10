@tool
extends EditorPlugin

var panel: Control
var git_manager: GitManager


func _enter_tree() -> void:
	git_manager = GitManager.new()
	git_manager.set_repo_path(ProjectSettings.globalize_path("res://"))
	panel = preload("res://addons/gdit_graph/gdit_graph_panel.tscn").instantiate()
	panel.name = "Version Control"
	if panel.has_method("set_git_manager"):
		panel.set_git_manager(git_manager)
	else:
		panel.set("git_manager", git_manager)
	add_control_to_dock(0, panel)
	panel.visible = true


func _exit_tree() -> void:
	if git_manager:
		git_manager.shutdown()
		git_manager = null
	if panel:
		remove_control_from_docks(panel)
		panel.queue_free()
		panel = null
