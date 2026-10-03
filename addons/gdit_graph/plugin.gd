@tool
extends EditorPlugin

const GraphThemeUtils = preload("res://addons/gdit_graph/workpanel/graph_utils.gd")
const GitExecutorScript = preload("res://addons/gdit_graph/git_executor.gd")
const GitWorkerScript = preload("res://addons/gdit_graph/git_worker.gd")
const GitManagerScript = preload("res://addons/gdit_graph/git_manager.gd")
const GraphManagerScript = preload("res://addons/gdit_graph/workpanel/graph_manager.gd")

const SIDEPANEL_SCENE_PATH := "res://addons/gdit_graph/sidepanel/version_control_panel.tscn"
const GRAPH_PANEL_SCENE_PATH := "res://addons/gdit_graph/workpanel/graph_panel.tscn"

# A live script reload (merge, branch switch, `git checkout` touching these
# files) can leave the preload chain git_manager.gd -> graph_manager.gd ->
# graph_panel.gd unparseable for a frame: the derived script recompiles while
# its base is still detached, so the inherited members are unresolved and the
# whole chain fails. A node whose script failed to parse keeps a PLACEHOLDER
# script instance - has_method() still answers true on it, and every call
# raises "Attempt to call a method on a placeholder instance". So a panel is
# built only once its script really compiled (see _script_compiled), and a
# missing panel schedules a bounded retry: the reload settles within a frame
# or two and the tab builds itself instead of needing a manual plugin reload.
const PANEL_RETRY_LIMIT := 5
const PANEL_RETRY_DELAY := 0.4

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
var _panel_retry_count = 0

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
	_panel_retry_count = 0
	_build_panels()
	_make_visible(false)


# Both managers run git through the one shared executor/worker pair created in
# _enter_tree, so neither panel owns a thread. Built here (not in _enter_tree)
# so a retry can fill in whatever the first pass had to skip.
func _ensure_managers() -> void:
	if git_manager == null and _script_compiled(GitManagerScript):
		git_manager = GitManagerScript.new()
		# Worker BEFORE repo path: set_repo_path() refreshes the env snapshot,
		# which enqueues work, so injecting later would leave a throwaway worker
		# (and a live thread) behind.
		git_manager.set_worker(_shared_worker)
		git_manager.set_executor(_shared_executor)
		git_manager.set_repo_path(ProjectSettings.globalize_path("res://"))
	if graph_manager == null and _script_compiled(GraphManagerScript):
		graph_manager = GraphManagerScript.new()
		graph_manager.set_worker(_shared_worker)
		graph_manager.set_executor(_shared_executor)
		graph_manager.set_repo_path(ProjectSettings.globalize_path("res://"))


# Idempotent: every builder no-ops once its piece exists, so a retry only fills
# in what the failed pass left out.
func _build_panels() -> void:
	_ensure_managers()
	_build_side_dock()
	_build_graph_tab()
	if panel == null or graph_panel == null:
		_schedule_panel_retry()


func _build_side_dock() -> void:
	if panel != null or git_manager == null:
		return
	var instance = _instantiate_panel(SIDEPANEL_SCENE_PATH)
	if instance == null:
		return
	instance.name = "Git"
	instance.set_git_manager(git_manager)
	panel = instance
	add_control_to_dock(DOCK_SLOT_LEFT_BR, panel)
	panel.visible = true


# Git Graph main-screen tab (top row, like Asset Store / Tasks): this single
# EditorPlugin provides both the "Git" dock and the "Git Graph" main screen
# (one plugin.cfg). The tab content lives in a MarginContainer under the editor
# main screen (kanban_tasks pattern); the graph panel owns no threads, the
# GraphManager does.
func _build_graph_tab() -> void:
	if graph_main_frame != null or graph_manager == null:
		return
	var instance = _instantiate_panel(GRAPH_PANEL_SCENE_PATH)
	if instance == null:
		return
	instance.set_git_manager(graph_manager)
	graph_panel = instance
	graph_main_frame = MarginContainer.new()
	graph_main_frame.add_theme_constant_override("margin_top", 5)
	graph_main_frame.add_theme_constant_override("margin_left", 5)
	graph_main_frame.add_theme_constant_override("margin_bottom", 5)
	graph_main_frame.add_theme_constant_override("margin_right", 5)
	graph_main_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Created hidden: the editor only reveals it via _make_visible(true) when
	# the tab is picked, and a deferred build has no later _make_visible call.
	graph_main_frame.visible = false
	get_editor_interface().get_editor_main_screen().add_child(graph_main_frame)
	graph_main_frame.add_child(graph_panel)
	# A side-panel commit runs on git_manager, not graph_manager, so the
	# graph tab would never hear about it: bridge the base manager's
	# operation_complete to a graph refresh so the new commit appears
	# without a manual refresh. (There is no commit_complete signal: it
	# carried a decorated "git commit" line no consumer could use, so the
	# action tag on operation_complete is the contract.)
	if git_manager != null and git_manager.has_signal("operation_complete") and graph_panel.has_method("refresh"):
		if not git_manager.operation_complete.is_connected(_on_side_operation_complete):
			git_manager.operation_complete.connect(_on_side_operation_complete)


# Instantiates a panel scene, or returns null when its root script did not
# compile: the node would come back with a placeholder script instance, and
# every method call on it would raise at the call site. Frees the unusable
# instance instead of parenting it. CACHE_MODE_REPLACE re-links the scene's
# ext_resources from disk, so a scene cached during the failed reload (script
# reference dropped) is repaired instead of staying broken for the retries.
func _instantiate_panel(scene_path: String):
	var scene := ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	if scene == null:
		push_error("Git Graph: could not load panel scene %s." % scene_path)
		return null
	var instance = scene.instantiate()
	if not _instance_ready(instance):
		instance.free()
		# First attempt only: the retries that follow are the same failure
		# repeating, and _schedule_panel_retry reports the give-up case.
		if _panel_retry_count == 0:
			push_error("Git Graph: %s did not load its script (parse error above); panel deferred." % scene_path)
		return null
	return instance


# "Did this script compile?" - and neither of the obvious answers works:
# Script.can_instantiate() is false for a healthy non-@tool script in the
# editor (git_manager.gd measured false while working fine), and
# has_method() is true on a placeholder left behind by a failed live reload.
# An unparsed GDScript has no base type; a parsed one always names one
# (measured: "" vs "VBoxContainer" vs "RefCounted").
func _script_compiled(script: Script) -> bool:
	return script != null and not script.get_instance_base_type().is_empty()


func _instance_ready(instance) -> bool:
	return _script_compiled(instance.get_script() as Script)


func _schedule_panel_retry() -> void:
	if _panel_retry_count >= PANEL_RETRY_LIMIT:
		push_error("Git Graph: panel scripts still do not compile after %d retries - fix the parse error in the Errors panel, then re-enable the plugin." % PANEL_RETRY_LIMIT)
		return
	_panel_retry_count += 1
	_retry_build_panels()


func _retry_build_panels() -> void:
	await get_tree().create_timer(PANEL_RETRY_DELAY).timeout
	if not is_inside_tree() or _panel_retry_count >= PANEL_RETRY_LIMIT:
		return
	if panel != null and graph_main_frame != null:
		return
	_build_panels()


func _on_side_operation_complete(result: Dictionary) -> void:
	if String(result.get("action", "")) != "commit" or int(result.get("exit_code", 1)) != 0:
		return
	if graph_panel != null and is_instance_valid(graph_panel) and graph_panel.has_method("refresh"):
		graph_panel.call("refresh")


func _exit_tree() -> void:
	_panel_retry_count = PANEL_RETRY_LIMIT
	if git_manager:
		if git_manager.has_signal("operation_complete") and git_manager.operation_complete.is_connected(_on_side_operation_complete):
			git_manager.operation_complete.disconnect(_on_side_operation_complete)
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
