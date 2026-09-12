# Repository configuration export/import (Phase 4: plan section V.24).
#
# Serializes the graph settings plus a few panel preferences (branch
# filter, details collapse) to a JSON file so a team can share one graph
# setup. Default location is the repo-root `.gdit_graph.json` (one click
# in the overflow menu); custom paths go through the same helpers.
# Pure file/JSON work — no git, no UI.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/export_config.gd").
extends RefCounted

const EXPORT_FILENAME = ".gdit_graph.json"
const EXPORT_VERSION = 1
const EXPORT_APP = "gdit_graph"


static func default_export_path(repo_path: String) -> String:
	return String(repo_path).rstrip("/").rstrip("\\").path_join(EXPORT_FILENAME)


static func build_payload(settings: Dictionary, extra: Dictionary = {}) -> Dictionary:
	return {
		"app": EXPORT_APP,
		"version": EXPORT_VERSION,
		"settings": (settings as Dictionary).duplicate(true),
		"extra": (extra as Dictionary).duplicate(true),
	}


static func export_to_path(settings: Dictionary, extra: Dictionary, path: String) -> Dictionary:
	var target := String(path).strip_edges()
	if target.is_empty():
		return {"ok": false, "error": "Empty export path."}
	var payload := build_payload(settings, extra)
	var writer := FileAccess.open(target, FileAccess.WRITE)
	if writer == null:
		return {"ok": false, "error": "Cannot write %s" % target}
	writer.store_string(JSON.stringify(payload, "\t"))
	writer.close()
	return {"ok": true, "path": target}


static func export_to_repo(settings: Dictionary, extra: Dictionary, repo_path: String) -> Dictionary:
	return export_to_path(settings, extra, default_export_path(repo_path))


static func import_from_path(path: String) -> Dictionary:
	var target := String(path).strip_edges()
	if target.is_empty():
		return {"ok": false, "error": "Empty import path."}
	if not FileAccess.file_exists(target):
		return {"ok": false, "error": "File not found: %s" % target}
	var reader := FileAccess.open(target, FileAccess.READ)
	if reader == null:
		return {"ok": false, "error": "Cannot read %s" % target}
	var parsed = JSON.parse_string(reader.get_as_text())
	reader.close()
	if not (parsed is Dictionary):
		return {"ok": false, "error": "Not a gdit_graph config file."}
	var data: Dictionary = parsed
	if String(data.get("app", "")) != EXPORT_APP:
		return {"ok": false, "error": "Not a gdit_graph config file."}
	var settings: Dictionary = {}
	if data.get("settings") is Dictionary:
		settings = (data["settings"] as Dictionary).duplicate(true)
	var extra: Dictionary = {}
	if data.get("extra") is Dictionary:
		extra = (data["extra"] as Dictionary).duplicate(true)
	return {"ok": true, "settings": settings, "extra": extra, "path": target}


static func import_from_repo(repo_path: String) -> Dictionary:
	return import_from_path(default_export_path(repo_path))
