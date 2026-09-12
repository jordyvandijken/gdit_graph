# Graph settings dialog (Phase 4: plan sections III.I, V.19).
#
# Static factories returning a configured ConfirmationDialog, following the
# graph_dialogs.gd pattern: the panel owns the instance (creates once,
# connects `confirmed`, reads via read_settings). Only options the panel
# actually implements are exposed — every toggle below is wired in
# graph_panel.gd, so the dialog can never promise a dead switch.
# Persisted in ProjectSettings under `gdit_graph/*` (plan's suggested route);
# export_config.gd snapshots the same dict for team sharing.
#
# No @tool needed (pure construction) and no class_name (repo convention):
# load via preload("res://addons/gdit_graph/workpanel/settings_dialog.gd").
extends RefCounted

const PREFIX = "gdit_graph/"
const KEY_LOAD_COUNT = "gdit_graph/initial_load_count"
const KEY_AUTO_LOAD = "gdit_graph/auto_load_more"
const KEY_SHOW_AVATARS = "gdit_graph/show_avatars"
const KEY_FETCH_AVATARS = "gdit_graph/fetch_avatars"
const KEY_DATE_MODE = "gdit_graph/date_format"
const KEY_MARKDOWN = "gdit_graph/render_markdown"
const KEY_EMOJI = "gdit_graph/render_emoji"
const KEY_SHOW_AUTHOR = "gdit_graph/show_author"
const KEY_SHOW_DATE = "gdit_graph/show_date"

const DATE_MODES = ["iso", "short", "relative"]

const DEFAULTS = {
	"initial_load_count": 200,
	"auto_load_more": false,
	"show_avatars": true,
	"fetch_avatars": false,
	"date_format": "iso",
	"render_markdown": true,
	"render_emoji": true,
	"show_author": true,
	"show_date": true,
}


static func load_settings() -> Dictionary:
	var out: Dictionary = (DEFAULTS as Dictionary).duplicate()
	for key in [KEY_LOAD_COUNT, KEY_AUTO_LOAD, KEY_SHOW_AVATARS, KEY_FETCH_AVATARS, KEY_DATE_MODE, KEY_MARKDOWN, KEY_EMOJI, KEY_SHOW_AUTHOR, KEY_SHOW_DATE]:
		if ProjectSettings.has_setting(key):
			match key:
				KEY_LOAD_COUNT:
					out["initial_load_count"] = clampi(int(ProjectSettings.get_setting(key, 200)), 50, 1000)
				KEY_DATE_MODE:
					var mode := String(ProjectSettings.get_setting(key, "iso")).to_lower()
					out["date_format"] = mode if mode in DATE_MODES else "iso"
				KEY_AUTO_LOAD:
					out["auto_load_more"] = bool(ProjectSettings.get_setting(key, false))
				KEY_SHOW_AVATARS:
					out["show_avatars"] = bool(ProjectSettings.get_setting(key, true))
				KEY_FETCH_AVATARS:
					out["fetch_avatars"] = bool(ProjectSettings.get_setting(key, false))
				KEY_MARKDOWN:
					out["render_markdown"] = bool(ProjectSettings.get_setting(key, true))
				KEY_EMOJI:
					out["render_emoji"] = bool(ProjectSettings.get_setting(key, true))
				KEY_SHOW_AUTHOR:
					out["show_author"] = bool(ProjectSettings.get_setting(key, true))
				KEY_SHOW_DATE:
					out["show_date"] = bool(ProjectSettings.get_setting(key, true))
	return out


static func save_settings(settings: Dictionary) -> void:
	ProjectSettings.set_setting(KEY_LOAD_COUNT, clampi(int(settings.get("initial_load_count", 200)), 50, 1000))
	ProjectSettings.set_setting(KEY_AUTO_LOAD, bool(settings.get("auto_load_more", false)))
	ProjectSettings.set_setting(KEY_SHOW_AVATARS, bool(settings.get("show_avatars", true)))
	ProjectSettings.set_setting(KEY_FETCH_AVATARS, bool(settings.get("fetch_avatars", false)))
	var mode := String(settings.get("date_format", "iso")).to_lower()
	ProjectSettings.set_setting(KEY_DATE_MODE, mode if mode in DATE_MODES else "iso")
	ProjectSettings.set_setting(KEY_MARKDOWN, bool(settings.get("render_markdown", true)))
	ProjectSettings.set_setting(KEY_EMOJI, bool(settings.get("render_emoji", true)))
	ProjectSettings.set_setting(KEY_SHOW_AUTHOR, bool(settings.get("show_author", true)))
	ProjectSettings.set_setting(KEY_SHOW_DATE, bool(settings.get("show_date", true)))


static func apply_settings(settings: Dictionary) -> Dictionary:
	var clean: Dictionary = (DEFAULTS as Dictionary).duplicate()
	for key in clean.keys():
		if settings.has(key):
			clean[key] = settings[key]
	clean["initial_load_count"] = clampi(int(clean.get("initial_load_count", 200)), 50, 1000)
	var mode := String(clean.get("date_format", "iso")).to_lower()
	clean["date_format"] = mode if mode in DATE_MODES else "iso"
	return clean


static func _add_section(box: VBoxContainer, title: String) -> void:
	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 13)
	box.add_child(label)


static func _add_check(box: VBoxContainer, node_name: String, text: String, pressed: bool, tip: String = "") -> CheckBox:
	var toggle := CheckBox.new()
	toggle.name = node_name
	toggle.text = text
	toggle.button_pressed = pressed
	if not tip.is_empty():
		toggle.tooltip_text = tip
	box.add_child(toggle)
	return toggle


static func make_settings_dialog(current: Dictionary) -> ConfirmationDialog:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Git Graph Settings"
	dialog.ok_button_text = "Save"
	var box := VBoxContainer.new()
	box.name = "DialogBox"
	box.custom_minimum_size = Vector2(380, 0)
	box.add_theme_constant_override("separation", 6)
	dialog.add_child(box)
	_add_section(box, "Loading")
	var load_row := HBoxContainer.new()
	load_row.name = "SettingLoadRow"
	var load_label := Label.new()
	load_label.text = "Initial commits per page"
	load_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	load_row.add_child(load_label)
	var load_spin := SpinBox.new()
	load_spin.name = "SettingLoadCount"
	load_spin.min_value = 50
	load_spin.max_value = 1000
	load_spin.step = 50
	load_spin.value = clampi(int(current.get("initial_load_count", 200)), 50, 1000)
	load_spin.tooltip_text = "Commits fetched per page (also used by Load more)"
	load_row.add_child(load_spin)
	box.add_child(load_row)
	_add_check(box, "SettingAutoLoad", "Load more automatically at the bottom", bool(current.get("auto_load_more", false)), "Fetch the next page when scrolled to the bottom")
	_add_section(box, "Graph rows")
	_add_check(box, "SettingAvatars", "Show author avatars", bool(current.get("show_avatars", true)), "Deterministic color + initials, generated offline")
	_add_check(box, "SettingFetchAvatars", "Fetch Gravatar images", bool(current.get("fetch_avatars", false)), "Downloads author icons once, caches under user:// (needs author emails)")
	_add_check(box, "SettingAuthor", "Show author column text", bool(current.get("show_author", true)))
	_add_check(box, "SettingDate", "Show date column text", bool(current.get("show_date", true)))
	var date_row := HBoxContainer.new()
	date_row.name = "SettingDateRow"
	var date_label := Label.new()
	date_label.text = "Date format"
	date_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	date_row.add_child(date_label)
	var date_opt := OptionButton.new()
	date_opt.name = "SettingDateMode"
	for m in DATE_MODES:
		date_opt.add_item(m)
	date_opt.selected = maxi(DATE_MODES.find(String(current.get("date_format", "iso")).to_lower()), 0)
	date_opt.tooltip_text = "iso: raw git date · short: YYYY-MM-DD · relative: 3h ago"
	date_row.add_child(date_opt)
	box.add_child(date_row)
	_add_section(box, "Commit messages")
	_add_check(box, "SettingMarkdown", "Render markdown in bodies", bool(current.get("render_markdown", true)), "Bold, code, headers, lists, quotes, links")
	_add_check(box, "SettingEmoji", "Replace :emoji: shortcodes", bool(current.get("render_emoji", true)), "e.g. :rocket: becomes an emoji")
	return dialog


static func read_settings(dialog: ConfirmationDialog) -> Dictionary:
	var box: VBoxContainer = dialog.get_node_or_null("DialogBox") as VBoxContainer
	var out: Dictionary = (DEFAULTS as Dictionary).duplicate()
	if box == null:
		return out
	var spin: SpinBox = box.get_node_or_null("SettingLoadRow/SettingLoadCount") as SpinBox
	if spin == null:
		spin = box.get_node_or_null("SettingLoadCount") as SpinBox
	if spin != null:
		out["initial_load_count"] = clampi(int(spin.value), 50, 1000)
	var date_opt: OptionButton = box.get_node_or_null("SettingDateRow/SettingDateMode") as OptionButton
	if date_opt == null:
		date_opt = box.get_node_or_null("SettingDateMode") as OptionButton
	if date_opt != null and date_opt.item_count > 0:
		out["date_format"] = date_opt.get_item_text(date_opt.selected).to_lower()
	for pair in [
		["SettingAutoLoad", "auto_load_more"],
		["SettingAvatars", "show_avatars"],
		["SettingFetchAvatars", "fetch_avatars"],
		["SettingMarkdown", "render_markdown"],
		["SettingEmoji", "render_emoji"],
		["SettingAuthor", "show_author"],
		["SettingDate", "show_date"],
	]:
		var toggle: CheckBox = box.get_node_or_null(String(pair[0])) as CheckBox
		if toggle != null:
			out[String(pair[1])] = toggle.button_pressed
	return apply_settings(out)
