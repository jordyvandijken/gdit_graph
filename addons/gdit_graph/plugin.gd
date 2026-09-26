@tool
extends EditorPlugin

const GraphThemeUtils = preload("res://addons/gdit_graph/workpanel/graph_utils.gd")
const GitExecutorScript = preload("res://addons/gdit_graph/git_executor.gd")
const GitWorkerScript = preload("res://addons/gdit_graph/git_worker.gd")
const GitManagerScript = preload("res://addons/gdit_graph/git_manager.gd")

const TAB_ICON_SVG_PATH = "res://addons/gdit_graph/icons/git-icon.svg"
# Phase 5 tab icon themes (plan item 30): the stock white glyph, a cool
# accent, the current branch color, or a neutral mono gray.
const TAB_ICON_ACCENT = Color(0.35, 0.65, 1.0)
const TAB_ICON_MONO = Color(0.75, 0.75, 0.75)

# Untyped on purpose (AGENTS.md #242/#244/#245): this is the long-lived
# @tool entry script, and a reparse that changes a field's declared type
# disagrees with the type the previous shape stored. GitManagerScript is
# preloaded (git_manager.gd has no class_name, per repo convention).
var panel = null
var git_manager = null
var graph_panel = null
var graph_manager = null
var graph_main_frame = null

# Shared git backend + command worker (DIP composition root): both managers
# run git through this one executor and this one serial worker thread, so
# commands from the dock and the graph tab cannot interleave, and neither
# panel can spawn or join a thread of its own.
var _shared_executor = null
var _shared_worker = null


func _enter_tree() -> void:
	_shared_executor = GitExecutorScript.new()
	_shared_worker = GitWorkerScript.new()
	_shared_worker.set_executor(_shared_executor)
	_shared_worker.set_repo_path(ProjectSettings.globalize_path("res://"))
	git_manager = GitManagerScript.new()
	# Worker BEFORE repo path: set_repo_path() refreshes the env snapshot,
	# which enqueues work, so injecting later would leave a throwaway worker
	# (and a live thread) behind.
	git_manager.set_worker(_shared_worker)
	git_manager.set_executor(_shared_executor)
	git_manager.set_repo_path(ProjectSettings.globalize_path("res://"))
	panel = preload("res://addons/gdit_graph/sidepanel/version_control_panel.tscn").instantiate()
	panel.name = "Git"
	if panel.has_method("set_git_manager"):
		panel.set_git_manager(git_manager)
	else:
		panel.set("git_manager", git_manager)
	add_control_to_dock(DOCK_SLOT_LEFT_BR, panel)
	panel.visible = true
	# Git Graph main-screen tab (top row, like Asset Store / Tasks): this
	# single EditorPlugin provides both the "Git" dock and the
	# "Git Graph" main screen (one plugin.cfg). The tab content lives in a
	# MarginContainer under the editor main screen (kanban_tasks pattern);
	# the graph panel owns no threads, the GraphManager below does.
	graph_manager = preload("res://addons/gdit_graph/workpanel/graph_manager.gd").new()
	graph_manager.set_worker(_shared_worker)
	graph_manager.set_executor(_shared_executor)
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
	# The managers only detached from the worker; its owner stops the thread.
	if _shared_worker:
		_shared_worker.stop()
		_shared_worker = null
	_shared_executor = null
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


# Phase 5 tab icon theming: recolor the white git glyph per the
# `gdit_graph/tab_icon_theme` setting. The editor queries this when the
# plugin enables (and on theme changes), so a theme switch applies on the
# next enable — no live refresh API exists for main-screen icons.
func _get_plugin_icon() -> Texture2D:
	var tint := _tab_icon_color()
	if tint == Color(1, 1, 1):
		return load(TAB_ICON_SVG_PATH) as Texture2D
	var recolored := _tinted_tab_icon(tint)
	if recolored != null:
		return recolored
	return load(TAB_ICON_SVG_PATH) as Texture2D


func _tab_icon_color() -> Color:
	var theme := "default"
	if ProjectSettings.has_setting("gdit_graph/tab_icon_theme"):
		theme = String(ProjectSettings.get_setting("gdit_graph/tab_icon_theme", "default")).to_lower()
	match theme:
		"accent":
			return TAB_ICON_ACCENT
		"mono":
			return TAB_ICON_MONO
		"branch":
			var branch := ""
			if graph_manager != null and graph_manager.has_method("get_branch"):
				branch = String(graph_manager.get_branch())
			if branch.is_empty() or branch == "-":
				return Color(1, 1, 1)
			return GraphThemeUtils.branch_color_for(branch)
	return Color(1, 1, 1)


# The stock SVG glyph is white-on-transparent; swapping its fill keeps the
# silhouette and alpha intact. Falls back to null (caller uses stock).
func _tinted_tab_icon(tint: Color) -> Texture2D:
	if not FileAccess.file_exists(TAB_ICON_SVG_PATH):
		return null
	var reader := FileAccess.open(TAB_ICON_SVG_PATH, FileAccess.READ)
	if reader == null:
		return null
	var svg := reader.get_as_text()
	reader.close()
	if svg.is_empty():
		return null
	var hex := "#%02x%02x%02x" % [clampi(int(tint.r * 255.0), 0, 255), clampi(int(tint.g * 255.0), 0, 255), clampi(int(tint.b * 255.0), 0, 255)]
	# The glyph path carries fill="#FFF"; the background carrier groups
	# carry their own fills, so only the white glyph is recolored.
	svg = svg.replace("#FFF", hex).replace("#fff", hex).replace("#FFFFFF", hex).replace("#ffffff", hex)
	var img := Image.new()
	if img.load_svg_from_string(svg, 32.0) != OK:
		return null
	return ImageTexture.create_from_image(img)
