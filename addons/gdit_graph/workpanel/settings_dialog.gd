# Graph settings dialog (Phase 4: plan sections III.I, V.19;
# Phase 5 polish: column visibility, resizable lanes, graph style,
# accessibility, tab icon theme, branch globs, PR provider).
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
const KEY_SHOW_HASH = "gdit_graph/show_hash"
const KEY_SHOW_REFS = "gdit_graph/show_refs"
const KEY_SHOW_UNCOMMITTED = "gdit_graph/show_uncommitted"
const KEY_LANE_WIDTH = "gdit_graph/lane_width"
const KEY_LINE_STYLE = "gdit_graph/line_style"
const KEY_NODE_SHAPE = "gdit_graph/node_shape"
const KEY_COLOR_SCHEME = "gdit_graph/color_scheme"
const KEY_ACCESSIBILITY = "gdit_graph/accessibility_mode"
const KEY_TAB_ICON = "gdit_graph/tab_icon_theme"
const KEY_BRANCH_GLOB = "gdit_graph/branch_glob"
const KEY_PR_PROVIDER = "gdit_graph/pr_provider"
const KEY_PR_REMOTE = "gdit_graph/pr_remote"

const DATE_MODES = ["iso", "short", "relative"]
const LINE_STYLES = ["solid", "dashed", "dotted"]
const NODE_SHAPES = ["auto", "circle", "diamond", "square"]
const COLOR_SCHEMES = ["default", "mono", "warm", "cool", "high_contrast"]
const TAB_ICON_THEMES = ["default", "accent", "branch", "mono"]
const PR_PROVIDERS = ["auto", "none", "github", "gitlab", "bitbucket"]

const LANE_WIDTH_MIN = 8.0
const LANE_WIDTH_MAX = 30.0

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
	"show_hash": true,
	"show_refs": true,
	"show_uncommitted": true,
	"lane_width": 14.0,
	"line_style": "solid",
	"node_shape": "auto",
	"color_scheme": "default",
	"accessibility_mode": false,
	"tab_icon_theme": "default",
	"branch_glob": "",
	"pr_provider": "auto",
	"pr_remote": "origin",
}


static func _clean_option(raw: String, allowed: Array, fallback: String) -> String:
	var mode := String(raw).strip_edges().to_lower()
	return mode if mode in allowed else String(fallback)


static func load_settings() -> Dictionary:
	var out: Dictionary = (DEFAULTS as Dictionary).duplicate()
	for key in [KEY_LOAD_COUNT, KEY_AUTO_LOAD, KEY_SHOW_AVATARS, KEY_FETCH_AVATARS, KEY_DATE_MODE, KEY_MARKDOWN, KEY_EMOJI, KEY_SHOW_AUTHOR, KEY_SHOW_DATE, KEY_SHOW_HASH, KEY_SHOW_REFS, KEY_SHOW_UNCOMMITTED, KEY_LANE_WIDTH, KEY_LINE_STYLE, KEY_NODE_SHAPE, KEY_COLOR_SCHEME, KEY_ACCESSIBILITY, KEY_TAB_ICON, KEY_BRANCH_GLOB, KEY_PR_PROVIDER, KEY_PR_REMOTE]:
		if ProjectSettings.has_setting(key):
			match key:
				KEY_LOAD_COUNT:
					out["initial_load_count"] = clampi(int(ProjectSettings.get_setting(key, 200)), 50, 1000)
				KEY_DATE_MODE:
					out["date_format"] = _clean_option(String(ProjectSettings.get_setting(key, "iso")), DATE_MODES, "iso")
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
				KEY_SHOW_HASH:
					out["show_hash"] = bool(ProjectSettings.get_setting(key, true))
				KEY_SHOW_REFS:
					out["show_refs"] = bool(ProjectSettings.get_setting(key, true))
				KEY_SHOW_UNCOMMITTED:
					out["show_uncommitted"] = bool(ProjectSettings.get_setting(key, true))
				KEY_LANE_WIDTH:
					out["lane_width"] = clampf(float(ProjectSettings.get_setting(key, 14.0)), LANE_WIDTH_MIN, LANE_WIDTH_MAX)
				KEY_LINE_STYLE:
					out["line_style"] = _clean_option(String(ProjectSettings.get_setting(key, "solid")), LINE_STYLES, "solid")
				KEY_NODE_SHAPE:
					out["node_shape"] = _clean_option(String(ProjectSettings.get_setting(key, "auto")), NODE_SHAPES, "auto")
				KEY_COLOR_SCHEME:
					out["color_scheme"] = _clean_option(String(ProjectSettings.get_setting(key, "default")), COLOR_SCHEMES, "default")
				KEY_ACCESSIBILITY:
					out["accessibility_mode"] = bool(ProjectSettings.get_setting(key, false))
				KEY_TAB_ICON:
					out["tab_icon_theme"] = _clean_option(String(ProjectSettings.get_setting(key, "default")), TAB_ICON_THEMES, "default")
				KEY_BRANCH_GLOB:
					out["branch_glob"] = String(ProjectSettings.get_setting(key, ""))
				KEY_PR_PROVIDER:
					out["pr_provider"] = _clean_option(String(ProjectSettings.get_setting(key, "auto")), PR_PROVIDERS, "auto")
				KEY_PR_REMOTE:
					var remote := String(ProjectSettings.get_setting(key, "origin")).strip_edges()
					out["pr_remote"] = remote if not remote.is_empty() else "origin"
	return out


static func save_settings(settings: Dictionary) -> void:
	ProjectSettings.set_setting(KEY_LOAD_COUNT, clampi(int(settings.get("initial_load_count", 200)), 50, 1000))
	ProjectSettings.set_setting(KEY_AUTO_LOAD, bool(settings.get("auto_load_more", false)))
	ProjectSettings.set_setting(KEY_SHOW_AVATARS, bool(settings.get("show_avatars", true)))
	ProjectSettings.set_setting(KEY_FETCH_AVATARS, bool(settings.get("fetch_avatars", false)))
	ProjectSettings.set_setting(KEY_DATE_MODE, _clean_option(String(settings.get("date_format", "iso")), DATE_MODES, "iso"))
	ProjectSettings.set_setting(KEY_MARKDOWN, bool(settings.get("render_markdown", true)))
	ProjectSettings.set_setting(KEY_EMOJI, bool(settings.get("render_emoji", true)))
	ProjectSettings.set_setting(KEY_SHOW_AUTHOR, bool(settings.get("show_author", true)))
	ProjectSettings.set_setting(KEY_SHOW_DATE, bool(settings.get("show_date", true)))
	ProjectSettings.set_setting(KEY_SHOW_HASH, bool(settings.get("show_hash", true)))
	ProjectSettings.set_setting(KEY_SHOW_REFS, bool(settings.get("show_refs", true)))
	ProjectSettings.set_setting(KEY_SHOW_UNCOMMITTED, bool(settings.get("show_uncommitted", true)))
	ProjectSettings.set_setting(KEY_LANE_WIDTH, clampf(float(settings.get("lane_width", 14.0)), LANE_WIDTH_MIN, LANE_WIDTH_MAX))
	ProjectSettings.set_setting(KEY_LINE_STYLE, _clean_option(String(settings.get("line_style", "solid")), LINE_STYLES, "solid"))
	ProjectSettings.set_setting(KEY_NODE_SHAPE, _clean_option(String(settings.get("node_shape", "auto")), NODE_SHAPES, "auto"))
	ProjectSettings.set_setting(KEY_COLOR_SCHEME, _clean_option(String(settings.get("color_scheme", "default")), COLOR_SCHEMES, "default"))
	ProjectSettings.set_setting(KEY_ACCESSIBILITY, bool(settings.get("accessibility_mode", false)))
	ProjectSettings.set_setting(KEY_TAB_ICON, _clean_option(String(settings.get("tab_icon_theme", "default")), TAB_ICON_THEMES, "default"))
	ProjectSettings.set_setting(KEY_BRANCH_GLOB, String(settings.get("branch_glob", "")))
	ProjectSettings.set_setting(KEY_PR_PROVIDER, _clean_option(String(settings.get("pr_provider", "auto")), PR_PROVIDERS, "auto"))
	var remote := String(settings.get("pr_remote", "origin")).strip_edges()
	ProjectSettings.set_setting(KEY_PR_REMOTE, remote if not remote.is_empty() else "origin")


static func apply_settings(settings: Dictionary) -> Dictionary:
	var clean: Dictionary = (DEFAULTS as Dictionary).duplicate()
	for key in clean.keys():
		if settings.has(key):
			clean[key] = settings[key]
	clean["initial_load_count"] = clampi(int(clean.get("initial_load_count", 200)), 50, 1000)
	clean["date_format"] = _clean_option(String(clean.get("date_format", "iso")), DATE_MODES, "iso")
	clean["lane_width"] = clampf(float(clean.get("lane_width", 14.0)), LANE_WIDTH_MIN, LANE_WIDTH_MAX)
	clean["line_style"] = _clean_option(String(clean.get("line_style", "solid")), LINE_STYLES, "solid")
	clean["node_shape"] = _clean_option(String(clean.get("node_shape", "auto")), NODE_SHAPES, "auto")
	clean["color_scheme"] = _clean_option(String(clean.get("color_scheme", "default")), COLOR_SCHEMES, "default")
	clean["tab_icon_theme"] = _clean_option(String(clean.get("tab_icon_theme", "default")), TAB_ICON_THEMES, "default")
	clean["pr_provider"] = _clean_option(String(clean.get("pr_provider", "auto")), PR_PROVIDERS, "auto")
	var remote := String(clean.get("pr_remote", "origin")).strip_edges()
	clean["pr_remote"] = remote if not remote.is_empty() else "origin"
	clean["branch_glob"] = String(clean.get("branch_glob", ""))
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


static func _add_option(box: VBoxContainer, row_name: String, opt_name: String, label_text: String, items: Array, current: String, tip: String = "") -> OptionButton:
	var row := HBoxContainer.new()
	row.name = row_name
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var opt := OptionButton.new()
	opt.name = opt_name
	for item in items:
		opt.add_item(String(item))
	opt.selected = maxi(items.find(String(current).to_lower()), 0)
	if not tip.is_empty():
		opt.tooltip_text = tip
	row.add_child(opt)
	box.add_child(row)
	return opt


static func _add_text(box: VBoxContainer, row_name: String, field_name: String, label_text: String, current: String, placeholder: String, tip: String = "") -> LineEdit:
	var row := HBoxContainer.new()
	row.name = row_name
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var field := LineEdit.new()
	field.name = field_name
	field.text = String(current)
	field.placeholder_text = placeholder
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.custom_minimum_size = Vector2(170, 0)
	if not tip.is_empty():
		field.tooltip_text = tip
	row.add_child(field)
	box.add_child(row)
	return field


static func make_settings_dialog(current: Dictionary) -> ConfirmationDialog:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Git Graph Settings"
	dialog.ok_button_text = "Save"
	var scroll := ScrollContainer.new()
	scroll.name = "DialogScroll"
	scroll.custom_minimum_size = Vector2(400, 420)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	dialog.add_child(scroll)
	var box := VBoxContainer.new()
	box.name = "DialogBox"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 6)
	scroll.add_child(box)
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
	_add_section(box, "Columns")
	_add_check(box, "SettingAvatars", "Show author avatars", bool(current.get("show_avatars", true)), "Deterministic color + initials, generated offline")
	_add_check(box, "SettingHash", "Show short hash column", bool(current.get("show_hash", true)), "Abbreviated commit hash before the subject")
	_add_check(box, "SettingRefs", "Show branch/tag chips", bool(current.get("show_refs", true)), "Current branch, other branches, and tags anchored to each commit")
	_add_check(box, "SettingUncommitted", "Show uncommitted changes row", bool(current.get("show_uncommitted", true)), "Pinned Uncommitted Changes (*) row above the log when the worktree is dirty")
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
	_add_check(box, "SettingFetchAvatars", "Fetch Gravatar images", bool(current.get("fetch_avatars", false)), "Downloads author icons once, caches under user:// (needs author emails)")
	_add_section(box, "Layout")
	var lane_row := HBoxContainer.new()
	lane_row.name = "SettingLaneRow"
	var lane_label := Label.new()
	lane_label.text = "Lane gutter width"
	lane_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lane_row.add_child(lane_label)
	var lane_spin := SpinBox.new()
	lane_spin.name = "SettingLaneWidth"
	lane_spin.min_value = LANE_WIDTH_MIN
	lane_spin.max_value = LANE_WIDTH_MAX
	lane_spin.step = 1
	lane_spin.value = clampf(float(current.get("lane_width", 14.0)), LANE_WIDTH_MIN, LANE_WIDTH_MAX)
	lane_spin.tooltip_text = "Width of one graph lane in pixels (drag the gutter edge in the graph to resize)"
	lane_row.add_child(lane_spin)
	box.add_child(lane_row)
	_add_section(box, "Graph style")
	_add_option(box, "SettingLineRow", "SettingLineStyle", "Line style", LINE_STYLES, String(current.get("line_style", "solid")), "How branch lanes are drawn")
	_add_option(box, "SettingNodeRow", "SettingNodeShape", "Node shape", NODE_SHAPES, String(current.get("node_shape", "auto")), "auto: diamonds for merges, circles otherwise")
	_add_option(box, "SettingSchemeRow", "SettingColorScheme", "Color scheme", COLOR_SCHEMES, String(current.get("color_scheme", "default")), "Branch lane palette")
	_add_section(box, "Accessibility")
	_add_check(box, "SettingAccessibility", "High-legibility mode", bool(current.get("accessibility_mode", false)), "Thicker lanes, outlined nodes, and text status tags instead of color-only cues")
	_add_section(box, "Branch filter")
	_add_text(box, "SettingGlobRow", "SettingBranchGlob", "Glob patterns", String(current.get("branch_glob", "")), "feature/*, !*-wip", "Comma-separated globs for the Branch dropdown; prefix with ! to exclude")
	_add_section(box, "Tab icon")
	_add_option(box, "SettingIconRow", "SettingTabIcon", "Icon theme", TAB_ICON_THEMES, String(current.get("tab_icon_theme", "default")), "branch tints the tab icon with the current branch color")
	_add_section(box, "Pull requests")
	_add_option(box, "SettingProviderRow", "SettingPrProvider", "Provider", PR_PROVIDERS, String(current.get("pr_provider", "auto")), "auto detects from the remote URL; none hides the PR menu")
	_add_text(box, "SettingPrRemoteRow", "SettingPrRemote", "Remote", String(current.get("pr_remote", "origin")), "origin", "Remote used for PR links and the open-PR list")
	_add_section(box, "Commit messages")
	_add_check(box, "SettingMarkdown", "Render markdown in bodies", bool(current.get("render_markdown", true)), "Bold, code, headers, lists, quotes, links")
	_add_check(box, "SettingEmoji", "Replace :emoji: shortcodes", bool(current.get("render_emoji", true)), "e.g. :rocket: becomes an emoji")
	return dialog


static func _read_option(box: VBoxContainer, row_name: String, opt_name: String) -> String:
	var opt: OptionButton = box.get_node_or_null(row_name + "/" + opt_name) as OptionButton
	if opt == null:
		opt = box.get_node_or_null(opt_name) as OptionButton
	if opt != null and opt.item_count > 0 and opt.selected >= 0:
		return opt.get_item_text(opt.selected).to_lower()
	return ""


static func _read_text(box: VBoxContainer, row_name: String, field_name: String) -> String:
	var field: LineEdit = box.get_node_or_null(row_name + "/" + field_name) as LineEdit
	if field == null:
		field = box.get_node_or_null(field_name) as LineEdit
	if field != null:
		return field.text.strip_edges()
	return ""


static func read_settings(dialog: ConfirmationDialog) -> Dictionary:
	var out: Dictionary = (DEFAULTS as Dictionary).duplicate()
	var box: VBoxContainer = dialog.get_node_or_null("DialogScroll/DialogBox") as VBoxContainer
	if box == null:
		box = dialog.get_node_or_null("DialogBox") as VBoxContainer
	if box == null:
		return out
	var spin: SpinBox = box.get_node_or_null("SettingLoadRow/SettingLoadCount") as SpinBox
	if spin == null:
		spin = box.get_node_or_null("SettingLoadCount") as SpinBox
	if spin != null:
		out["initial_load_count"] = clampi(int(spin.value), 50, 1000)
	var lane_spin: SpinBox = box.get_node_or_null("SettingLaneRow/SettingLaneWidth") as SpinBox
	if lane_spin == null:
		lane_spin = box.get_node_or_null("SettingLaneWidth") as SpinBox
	if lane_spin != null:
		out["lane_width"] = clampf(float(lane_spin.value), LANE_WIDTH_MIN, LANE_WIDTH_MAX)
	var date_mode := _read_option(box, "SettingDateRow", "SettingDateMode")
	if not date_mode.is_empty():
		out["date_format"] = date_mode
	var line_style := _read_option(box, "SettingLineRow", "SettingLineStyle")
	if not line_style.is_empty():
		out["line_style"] = line_style
	var node_shape := _read_option(box, "SettingNodeRow", "SettingNodeShape")
	if not node_shape.is_empty():
		out["node_shape"] = node_shape
	var scheme := _read_option(box, "SettingSchemeRow", "SettingColorScheme")
	if not scheme.is_empty():
		out["color_scheme"] = scheme
	var icon := _read_option(box, "SettingIconRow", "SettingTabIcon")
	if not icon.is_empty():
		out["tab_icon_theme"] = icon
	var provider := _read_option(box, "SettingProviderRow", "SettingPrProvider")
	if not provider.is_empty():
		out["pr_provider"] = provider
	out["branch_glob"] = _read_text(box, "SettingGlobRow", "SettingBranchGlob")
	var pr_remote := _read_text(box, "SettingPrRemoteRow", "SettingPrRemote")
	out["pr_remote"] = pr_remote if not pr_remote.is_empty() else "origin"
	for pair in [
		["SettingAutoLoad", "auto_load_more"],
		["SettingAvatars", "show_avatars"],
		["SettingFetchAvatars", "fetch_avatars"],
		["SettingMarkdown", "render_markdown"],
		["SettingEmoji", "render_emoji"],
		["SettingAuthor", "show_author"],
		["SettingDate", "show_date"],
		["SettingHash", "show_hash"],
		["SettingRefs", "show_refs"],
		["SettingUncommitted", "show_uncommitted"],
		["SettingAccessibility", "accessibility_mode"],
	]:
		var toggle: CheckBox = box.get_node_or_null(String(pair[0])) as CheckBox
		if toggle != null:
			out[String(pair[1])] = toggle.button_pressed
	return apply_settings(out)
