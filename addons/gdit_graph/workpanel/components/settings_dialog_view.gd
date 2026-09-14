# Settings dialog view for the graph tab (mirrors settings_dialog.gd).
#
# The layout lives in settings_dialog.tscn with defaults matching
# SettingsDialogScript.DEFAULTS; setup() applies the live `current` dict
# (the old make_settings_dialog did both at once). read_settings() keeps
# working unchanged: every node path below is preserved from the factory.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/components/settings_dialog_view.gd").
@tool
extends ConfirmationDialog

const SettingsDialogScript = preload("res://addons/gdit_graph/workpanel/settings_dialog.gd")


func setup(current: Dictionary) -> void:
	var box = get_node_or_null("DialogScroll/DialogBox")
	if box == null:
		return
	_set_spin(box, "SettingLoadRow/SettingLoadCount", clampi(int(current.get("initial_load_count", 200)), 50, 1000))
	_set_check(box, "SettingAutoLoad", bool(current.get("auto_load_more", false)))
	_set_option(box, "SettingOrderRow/SettingCommitOrder", SettingsDialogScript.COMMIT_ORDERS, String(current.get("commit_order", "topo")))
	_set_check(box, "SettingAvatars", bool(current.get("show_avatars", true)))
	_set_check(box, "SettingHash", bool(current.get("show_hash", true)))
	_set_check(box, "SettingRefs", bool(current.get("show_refs", true)))
	_set_check(box, "SettingUncommitted", bool(current.get("show_uncommitted", true)))
	_set_check(box, "SettingStashes", bool(current.get("show_stashes", true)))
	_set_check(box, "SettingAuthor", bool(current.get("show_author", true)))
	_set_check(box, "SettingDate", bool(current.get("show_date", true)))
	_set_option(box, "SettingDateRow/SettingDateMode", SettingsDialogScript.DATE_MODES, String(current.get("date_format", "datetime")))
	_set_check(box, "SettingFetchAvatars", bool(current.get("fetch_avatars", false)))
	_set_spin(box, "SettingLaneRow/SettingLaneWidth", clampf(float(current.get("lane_width", 16.0)), SettingsDialogScript.LANE_WIDTH_MIN, SettingsDialogScript.LANE_WIDTH_MAX))
	_set_option(box, "SettingLineRow/SettingLineStyle", SettingsDialogScript.LINE_STYLES, String(current.get("line_style", "solid")))
	_set_option(box, "SettingGraphRow/SettingGraphStyle", SettingsDialogScript.GRAPH_STYLES, String(current.get("graph_style", "rounded")))
	_set_option(box, "SettingUncommittedRow/SettingUncommittedStyle", SettingsDialogScript.UNCOMMITTED_STYLES, String(current.get("uncommitted_style", "open_uncommitted")))
	_set_check(box, "SettingMuteMerges", bool(current.get("mute_merges", true)))
	_set_check(box, "SettingMuteNonAncestors", bool(current.get("mute_non_ancestors", false)))
	_set_option(box, "SettingNodeRow/SettingNodeShape", SettingsDialogScript.NODE_SHAPES, String(current.get("node_shape", "auto")))
	_set_option(box, "SettingSchemeRow/SettingColorScheme", SettingsDialogScript.COLOR_SCHEMES, String(current.get("color_scheme", "default")))
	_set_check(box, "SettingAccessibility", bool(current.get("accessibility_mode", false)))
	_set_text(box, "SettingGlobRow/SettingBranchGlob", String(current.get("branch_glob", "")))
	_set_option(box, "SettingIconRow/SettingTabIcon", SettingsDialogScript.TAB_ICON_THEMES, String(current.get("tab_icon_theme", "default")))
	_set_option(box, "SettingProviderRow/SettingPrProvider", SettingsDialogScript.PR_PROVIDERS, String(current.get("pr_provider", "auto")))
	_set_text(box, "SettingPrRemoteRow/SettingPrRemote", String(current.get("pr_remote", "origin")))
	_set_check(box, "SettingMarkdown", bool(current.get("render_markdown", true)))
	_set_check(box, "SettingEmoji", bool(current.get("render_emoji", true)))


func _set_spin(box: VBoxContainer, path: String, value: float) -> void:
	var spin := box.get_node_or_null(path) as SpinBox
	if spin != null:
		spin.value = value


func _set_check(box: VBoxContainer, node_name: String, pressed: bool) -> void:
	var toggle := box.get_node_or_null(node_name) as CheckBox
	if toggle != null:
		toggle.button_pressed = pressed


func _set_option(box: VBoxContainer, path: String, items: Array, current: String) -> void:
	var opt := box.get_node_or_null(path) as OptionButton
	if opt == null:
		return
	opt.selected = maxi(items.find(String(current).to_lower()), 0)


func _set_text(box: VBoxContainer, path: String, text: String) -> void:
	var field := box.get_node_or_null(path) as LineEdit
	if field != null:
		field.text = text
