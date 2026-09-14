# Graph settings model + dialog reader (Phase 4: plan sections III.I, V.19;
# Phase 5 polish: column visibility, resizable lanes, graph style,
# accessibility, tab icon theme, branch globs, PR provider).
#
# Dialog layout moved to workpanel/components/settings_dialog.tscn with value
# setup in settings_dialog_view.gd; the panel owns the instance (rebuilt on
# every open, connects `confirmed`, reads via read_settings). Only options
# the panel actually implements are exposed — every toggle below is wired in
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
const KEY_SHOW_STASHES = "gdit_graph/show_stashes"
const KEY_LANE_WIDTH = "gdit_graph/lane_width"
const KEY_DATE_COL_W = "gdit_graph/date_col_w"
const KEY_AUTHOR_COL_W = "gdit_graph/author_col_w"
const KEY_COMMIT_COL_W = "gdit_graph/commit_col_w"
const KEY_LINE_STYLE = "gdit_graph/line_style"
const KEY_GRAPH_STYLE = "gdit_graph/graph_style"
const KEY_UNCOMMITTED_STYLE = "gdit_graph/uncommitted_style"
const KEY_MUTE_MERGES = "gdit_graph/mute_merges"
const KEY_MUTE_NON_ANCESTORS = "gdit_graph/mute_non_ancestors"
const KEY_NODE_SHAPE = "gdit_graph/node_shape"
const KEY_COLOR_SCHEME = "gdit_graph/color_scheme"
const KEY_ACCESSIBILITY = "gdit_graph/accessibility_mode"
const KEY_TAB_ICON = "gdit_graph/tab_icon_theme"
const KEY_BRANCH_GLOB = "gdit_graph/branch_glob"
const KEY_PR_PROVIDER = "gdit_graph/pr_provider"
const KEY_PR_REMOTE = "gdit_graph/pr_remote"
const KEY_COMMIT_ORDER = "gdit_graph/commit_order"

const DATE_MODES = ["datetime", "date", "iso_datetime", "iso_date", "relative"]
const LINE_STYLES = ["solid", "dashed", "dotted"]
const GRAPH_STYLES = ["rounded", "angular"]
const UNCOMMITTED_STYLES = ["open_uncommitted", "open_head"]
const NODE_SHAPES = ["auto", "circle", "diamond", "square"]
const COLOR_SCHEMES = ["default", "mono", "warm", "cool", "high_contrast"]
const TAB_ICON_THEMES = ["default", "accent", "branch", "mono"]
const PR_PROVIDERS = ["auto", "none", "github", "gitlab", "bitbucket"]
const COMMIT_ORDERS = ["topo", "date", "author-date"]

const LANE_WIDTH_MIN = 8.0
const LANE_WIDTH_MAX = 30.0

const DEFAULTS = {
	"initial_load_count": 200,
	"auto_load_more": false,
	"show_avatars": true,
	"fetch_avatars": false,
	"date_format": "datetime",
	"render_markdown": true,
	"render_emoji": true,
	"show_author": true,
	"show_date": true,
	"show_hash": true,
	"show_refs": true,
	"show_uncommitted": true,
	"show_stashes": true,
	"lane_width": 16.0,
	"date_col_w": 0.0,
	"author_col_w": 0.0,
	"commit_col_w": 0.0,
	"line_style": "solid",
	"graph_style": "rounded",
	"uncommitted_style": "open_uncommitted",
	"mute_merges": true,
	"mute_non_ancestors": false,
	"node_shape": "auto",
	"color_scheme": "default",
	"accessibility_mode": false,
	"tab_icon_theme": "default",
	"branch_glob": "",
	"pr_provider": "auto",
	"pr_remote": "origin",
	"commit_order": "topo",
}


static func _clean_option(raw: String, allowed: Array, fallback: String) -> String:
	var mode := String(raw).strip_edges().to_lower()
	return mode if mode in allowed else String(fallback)


static func load_settings() -> Dictionary:
	var out: Dictionary = (DEFAULTS as Dictionary).duplicate()
	for key in [KEY_LOAD_COUNT, KEY_AUTO_LOAD, KEY_SHOW_AVATARS, KEY_FETCH_AVATARS, KEY_DATE_MODE, KEY_MARKDOWN, KEY_EMOJI, KEY_SHOW_AUTHOR, KEY_SHOW_DATE, KEY_SHOW_HASH, KEY_SHOW_REFS, KEY_SHOW_UNCOMMITTED, KEY_SHOW_STASHES, KEY_LANE_WIDTH, KEY_DATE_COL_W, KEY_AUTHOR_COL_W, KEY_COMMIT_COL_W, KEY_LINE_STYLE, KEY_GRAPH_STYLE, KEY_UNCOMMITTED_STYLE, KEY_MUTE_MERGES, KEY_MUTE_NON_ANCESTORS, KEY_NODE_SHAPE, KEY_COLOR_SCHEME, KEY_ACCESSIBILITY, KEY_TAB_ICON, KEY_BRANCH_GLOB, KEY_PR_PROVIDER, KEY_PR_REMOTE, KEY_COMMIT_ORDER]:
		if ProjectSettings.has_setting(key):
			match key:
				KEY_LOAD_COUNT:
					out["initial_load_count"] = clampi(int(ProjectSettings.get_setting(key, 200)), 50, 1000)
				KEY_DATE_MODE:
					out["date_format"] = _clean_option(String(ProjectSettings.get_setting(key, "datetime")), DATE_MODES, "datetime")
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
				KEY_SHOW_STASHES:
					out["show_stashes"] = bool(ProjectSettings.get_setting(key, true))
				KEY_LANE_WIDTH:
					out["lane_width"] = clampf(float(ProjectSettings.get_setting(key, 16.0)), LANE_WIDTH_MIN, LANE_WIDTH_MAX)
				KEY_DATE_COL_W:
					out["date_col_w"] = maxf(float(ProjectSettings.get_setting(key, 0.0)), 0.0)
				KEY_AUTHOR_COL_W:
					out["author_col_w"] = maxf(float(ProjectSettings.get_setting(key, 0.0)), 0.0)
				KEY_COMMIT_COL_W:
					out["commit_col_w"] = maxf(float(ProjectSettings.get_setting(key, 0.0)), 0.0)
				KEY_LINE_STYLE:
					out["line_style"] = _clean_option(String(ProjectSettings.get_setting(key, "solid")), LINE_STYLES, "solid")
				KEY_GRAPH_STYLE:
					out["graph_style"] = _clean_option(String(ProjectSettings.get_setting(key, "rounded")), GRAPH_STYLES, "rounded")
				KEY_UNCOMMITTED_STYLE:
					out["uncommitted_style"] = _clean_option(String(ProjectSettings.get_setting(key, "open_uncommitted")), UNCOMMITTED_STYLES, "open_uncommitted")
				KEY_MUTE_MERGES:
					out["mute_merges"] = bool(ProjectSettings.get_setting(key, true))
				KEY_MUTE_NON_ANCESTORS:
					out["mute_non_ancestors"] = bool(ProjectSettings.get_setting(key, false))
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
				KEY_COMMIT_ORDER:
					out["commit_order"] = _clean_option(String(ProjectSettings.get_setting(key, "topo")), COMMIT_ORDERS, "topo")
	return out


static func save_settings(settings: Dictionary) -> void:
	ProjectSettings.set_setting(KEY_LOAD_COUNT, clampi(int(settings.get("initial_load_count", 200)), 50, 1000))
	ProjectSettings.set_setting(KEY_AUTO_LOAD, bool(settings.get("auto_load_more", false)))
	ProjectSettings.set_setting(KEY_SHOW_AVATARS, bool(settings.get("show_avatars", true)))
	ProjectSettings.set_setting(KEY_FETCH_AVATARS, bool(settings.get("fetch_avatars", false)))
	ProjectSettings.set_setting(KEY_DATE_MODE, _clean_option(String(settings.get("date_format", "datetime")), DATE_MODES, "datetime"))
	ProjectSettings.set_setting(KEY_MARKDOWN, bool(settings.get("render_markdown", true)))
	ProjectSettings.set_setting(KEY_EMOJI, bool(settings.get("render_emoji", true)))
	ProjectSettings.set_setting(KEY_SHOW_AUTHOR, bool(settings.get("show_author", true)))
	ProjectSettings.set_setting(KEY_SHOW_DATE, bool(settings.get("show_date", true)))
	ProjectSettings.set_setting(KEY_SHOW_HASH, bool(settings.get("show_hash", true)))
	ProjectSettings.set_setting(KEY_SHOW_REFS, bool(settings.get("show_refs", true)))
	ProjectSettings.set_setting(KEY_SHOW_UNCOMMITTED, bool(settings.get("show_uncommitted", true)))
	ProjectSettings.set_setting(KEY_SHOW_STASHES, bool(settings.get("show_stashes", true)))
	ProjectSettings.set_setting(KEY_LANE_WIDTH, clampf(float(settings.get("lane_width", 16.0)), LANE_WIDTH_MIN, LANE_WIDTH_MAX))
	ProjectSettings.set_setting(KEY_DATE_COL_W, maxf(float(settings.get("date_col_w", 0.0)), 0.0))
	ProjectSettings.set_setting(KEY_AUTHOR_COL_W, maxf(float(settings.get("author_col_w", 0.0)), 0.0))
	ProjectSettings.set_setting(KEY_COMMIT_COL_W, maxf(float(settings.get("commit_col_w", 0.0)), 0.0))
	ProjectSettings.set_setting(KEY_LINE_STYLE, _clean_option(String(settings.get("line_style", "solid")), LINE_STYLES, "solid"))
	ProjectSettings.set_setting(KEY_GRAPH_STYLE, _clean_option(String(settings.get("graph_style", "rounded")), GRAPH_STYLES, "rounded"))
	ProjectSettings.set_setting(KEY_UNCOMMITTED_STYLE, _clean_option(String(settings.get("uncommitted_style", "open_uncommitted")), UNCOMMITTED_STYLES, "open_uncommitted"))
	ProjectSettings.set_setting(KEY_MUTE_MERGES, bool(settings.get("mute_merges", true)))
	ProjectSettings.set_setting(KEY_MUTE_NON_ANCESTORS, bool(settings.get("mute_non_ancestors", false)))
	ProjectSettings.set_setting(KEY_NODE_SHAPE, _clean_option(String(settings.get("node_shape", "auto")), NODE_SHAPES, "auto"))
	ProjectSettings.set_setting(KEY_COLOR_SCHEME, _clean_option(String(settings.get("color_scheme", "default")), COLOR_SCHEMES, "default"))
	ProjectSettings.set_setting(KEY_ACCESSIBILITY, bool(settings.get("accessibility_mode", false)))
	ProjectSettings.set_setting(KEY_TAB_ICON, _clean_option(String(settings.get("tab_icon_theme", "default")), TAB_ICON_THEMES, "default"))
	ProjectSettings.set_setting(KEY_BRANCH_GLOB, String(settings.get("branch_glob", "")))
	ProjectSettings.set_setting(KEY_PR_PROVIDER, _clean_option(String(settings.get("pr_provider", "auto")), PR_PROVIDERS, "auto"))
	var remote := String(settings.get("pr_remote", "origin")).strip_edges()
	ProjectSettings.set_setting(KEY_PR_REMOTE, remote if not remote.is_empty() else "origin")
	ProjectSettings.set_setting(KEY_COMMIT_ORDER, _clean_option(String(settings.get("commit_order", "topo")), COMMIT_ORDERS, "topo"))


static func apply_settings(settings: Dictionary) -> Dictionary:
	var clean: Dictionary = (DEFAULTS as Dictionary).duplicate()
	for key in clean.keys():
		if settings.has(key):
			clean[key] = settings[key]
	clean["initial_load_count"] = clampi(int(clean.get("initial_load_count", 200)), 50, 1000)
	clean["date_format"] = _clean_option(String(clean.get("date_format", "datetime")), DATE_MODES, "datetime")
	clean["lane_width"] = clampf(float(clean.get("lane_width", 16.0)), LANE_WIDTH_MIN, LANE_WIDTH_MAX)
	clean["date_col_w"] = maxf(float(clean.get("date_col_w", 0.0)), 0.0)
	clean["author_col_w"] = maxf(float(clean.get("author_col_w", 0.0)), 0.0)
	clean["commit_col_w"] = maxf(float(clean.get("commit_col_w", 0.0)), 0.0)
	clean["line_style"] = _clean_option(String(clean.get("line_style", "solid")), LINE_STYLES, "solid")
	clean["graph_style"] = _clean_option(String(clean.get("graph_style", "rounded")), GRAPH_STYLES, "rounded")
	clean["uncommitted_style"] = _clean_option(String(clean.get("uncommitted_style", "open_uncommitted")), UNCOMMITTED_STYLES, "open_uncommitted")
	clean["node_shape"] = _clean_option(String(clean.get("node_shape", "auto")), NODE_SHAPES, "auto")
	clean["color_scheme"] = _clean_option(String(clean.get("color_scheme", "default")), COLOR_SCHEMES, "default")
	clean["tab_icon_theme"] = _clean_option(String(clean.get("tab_icon_theme", "default")), TAB_ICON_THEMES, "default")
	clean["pr_provider"] = _clean_option(String(clean.get("pr_provider", "auto")), PR_PROVIDERS, "auto")
	var remote := String(clean.get("pr_remote", "origin")).strip_edges()
	clean["pr_remote"] = remote if not remote.is_empty() else "origin"
	clean["commit_order"] = _clean_option(String(clean.get("commit_order", "topo")), COMMIT_ORDERS, "topo")
	clean["branch_glob"] = String(clean.get("branch_glob", ""))
	return clean


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
	var graph_style := _read_option(box, "SettingGraphRow", "SettingGraphStyle")
	if not graph_style.is_empty():
		out["graph_style"] = graph_style
	var commit_order := _read_option(box, "SettingOrderRow", "SettingCommitOrder")
	if not commit_order.is_empty():
		out["commit_order"] = commit_order
	var uncommitted_style := _read_option(box, "SettingUncommittedRow", "SettingUncommittedStyle")
	if not uncommitted_style.is_empty():
		out["uncommitted_style"] = uncommitted_style
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
		["SettingStashes", "show_stashes"],
		["SettingAccessibility", "accessibility_mode"],
		["SettingMuteMerges", "mute_merges"],
		["SettingMuteNonAncestors", "mute_non_ancestors"],
	]:
		var toggle: CheckBox = box.get_node_or_null(String(pair[0])) as CheckBox
		if toggle != null:
			out[String(pair[1])] = toggle.button_pressed
	return apply_settings(out)
