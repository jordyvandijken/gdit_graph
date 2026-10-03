# Shared editor helpers used by both panels.
#
# Opening a repo-relative file in the editor and refreshing open tabs plus
# the filesystem after git rewrites files on disk are needed by the side
# panel and the graph tab alike. This file owns the EditorInterface
# mechanics; panels keep their own status/log reporting around the calls
# (pass a log Callable to mirror step notes into a panel debug log).
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/editor_utils.gd").
extends RefCounted


# Open a repo-relative path in the editor: loadable resources open in their
# editor, anything else is revealed in the FileSystem dock.
static func open_file_in_editor(repo_path: String) -> void:
	if String(repo_path).is_empty() or not Engine.is_editor_hint():
		return
	var res_path := "res://" + String(repo_path)
	if ResourceLoader.exists(res_path):
		var res := ResourceLoader.load(res_path)
		if res != null:
			EditorInterface.edit_resource(res)
			return
	EditorInterface.get_file_system_dock().navigate_to_path(res_path)


# Git operations (discard/pull/checkout/merge/reset) rewrite files on disk,
# but open editor tabs keep stale in-memory text until a rescan. Reload the
# tabs AND rescan so the new content shows immediately. When `log` is a
# valid Callable it receives a short note for each step, otherwise the
# refresh runs silently.
static func reload_editor_after_disk_change(log: Callable = Callable()) -> void:
	if not Engine.is_editor_hint():
		if log.is_valid():
			log.call("editor refresh skipped: not in editor.")
		return
	var se := EditorInterface.get_script_editor()
	if se != null:
		if log.is_valid():
			log.call("editor refresh: reloading open script tabs from disk.")
		se.reload_open_files()
	else:
		if log.is_valid():
			log.call("editor refresh: no script editor.")
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		if log.is_valid():
			log.call("editor refresh: no filesystem for scan.")
		return
	if fs.is_scanning():
		if log.is_valid():
			log.call("editor refresh: scan skipped (already scanning).")
		return
	if log.is_valid():
		log.call("editor refresh: calling EditorFileSystem.scan().")
	fs.scan()


# Shared pull/fetch/push pre-flight (DRY): null manager, non-repo, and
# missing-remote checks with status reporting through the panel's own
# `set_status(text, is_error)` callable. True means proceed. Both panels
# used to carry a byte-identical copy of this.
static func guard_remote_op(manager, set_status: Callable) -> bool:
	if manager == null:
		return false
	if not manager.is_repo():
		return false
	if not manager.has_remote():
		if set_status.is_valid():
			set_status.call("Error: no git remote configured. Add one via Remotes to publish.", true)
		return false
	return true
