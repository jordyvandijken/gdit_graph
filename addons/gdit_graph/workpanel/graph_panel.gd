# Git Graph main-screen tab content (Phase 1 MVP: plan sections II rows
# 1-2+6, V phase 1; Phase 2: commit details + context actions, V phase 2;
# Phase 3: branch/tag/stash/remote management, V phase 3;
# Phase 4: find, comparison, review, settings, shortcuts, V phase 4;
# Phase 5 polish: column toggles, resizable lanes, graph styles,
# accessibility, context retention, icon theme, branch globs, PR links;
# plan section I remainder: cherry-pick/rebase, reflog, fetch-ref,
# merge-base).
#
# Hosted by plugin.gd in a MarginContainer under the editor main screen
# (top row, like Asset Store / Tasks), so this panel is always laid out at
# tab size. Toolbar (title, search, Fetch, Refresh, Settings, overflow menu)
# + branch filter, the graph_renderer.gd canvas in a
# ScrollContainer, an inline commit detail panel (graph_inline_detail.gd,
# opening between the selected row and the next, lanes still visible on the
# left), a comparison view (Ctrl+click two rows, merge-base subtitle), a
# Load-more pager, and a status row.
# Click-to-select loads details (files + inline diff); right-click opens
# the branch_menu.gd context menu (checkout / merge / cherry-pick / rebase /
# reset / copy, plus branch/tag creation and per-branch actions). The
# overflow (⋯) menu hosts stash, tag, remote, and reflog management plus
# pull/push/fetch-ref and config export.
#
# Owns no threads: all git work runs on the GraphManager worker thread and
# arrives via signals. Never touch UI from the thread.
#
# No class_name (repo convention): instantiated from graph_panel.tscn.
@tool
extends VBoxContainer

# Direct preload of the base manager, for its shared constants (the unborn
# branch sentinel). graph_manager.gd inherits from the same script; no cycle.
const GitManagerScript = preload("res://addons/gdit_graph/git_manager.gd")
const GraphRendererScript = preload("res://addons/gdit_graph/workpanel/graph_renderer.gd")
const BranchMenuScript = preload("res://addons/gdit_graph/workpanel/branch_menu.gd")
const GraphDialogsScript = preload("res://addons/gdit_graph/workpanel/graph_dialogs.gd")
const ComparisonViewScript = preload("res://addons/gdit_graph/workpanel/comparison_view.gd")
const GraphInlineDetailScript = preload("res://addons/gdit_graph/workpanel/graph_inline_detail.gd")
const SettingsDialogScript = preload("res://addons/gdit_graph/workpanel/settings_dialog.gd")
const ExportConfigScript = preload("res://addons/gdit_graph/workpanel/export_config.gd")
const PanelGraphUtils = preload("res://addons/gdit_graph/workpanel/graph_utils.gd")
const EditorUtils = preload("res://addons/gdit_graph/editor_utils.gd")
const PanelAvatars = preload("res://addons/gdit_graph/workpanel/avatar_manager.gd")
const GitOperations = preload("res://addons/gdit_graph/git_operations.gd")

# Phase 4 scene components: shared toolbar button + input dialogs (layout in
# .tscn, readers in graph_dialogs.gd / settings_dialog.gd keep working via
# preserved node names).
const ToolbarButtonScene = preload("res://addons/gdit_graph/components/toolbar_button.tscn")
const RenameDialogScene = preload("res://addons/gdit_graph/workpanel/components/rename_dialog.tscn")
const TagDialogScene = preload("res://addons/gdit_graph/workpanel/components/tag_dialog.tscn")
const StashDialogScene = preload("res://addons/gdit_graph/workpanel/components/stash_dialog.tscn")
const SettingsDialogScene = preload("res://addons/gdit_graph/workpanel/components/settings_dialog.tscn")

# Branch creation uses the shared sidepanel switcher (search-as-name with
# sanitize + validation, create, create-from-source, checkout, detach) so
# both panels offer the same creator. Name helpers come from the same
# utils/GitRefs the popup itself uses.
const BranchPopupScript = preload("res://addons/gdit_graph/sidepanel/branch_popup.gd")
const SidepanelBranchUtils = preload("res://addons/gdit_graph/sidepanel/version_control_panel_utils.gd")
const GitRefs = preload("res://addons/gdit_graph/git_refs.gd")

# Phase 5 scene components: filter row + find widget (layout in .tscn).
const FilterRowScene = preload("res://addons/gdit_graph/workpanel/components/filter_row.tscn")
const FindWidgetScene = preload("res://addons/gdit_graph/workpanel/components/find_widget.tscn")

# Overflow (⋯) menu item ids. Dynamic sub-item ids encode cache indices;
# routing bounds-checks against the caches (see _on_overflow_id).
const OV_PULL = 1
const OV_PUSH_FIRST = 2
const OV_STASH_PUSH = 3
const OV_TAG_CREATE = 4
const OV_EXPORT_CONFIG = 5
const OV_IMPORT_CONFIG = 6
const OV_PUSH_BASE = 100
const OV_STASH_APPLY_BASE = 1000
const OV_STASH_POP_BASE = 2000
const OV_STASH_DROP_BASE = 3000
const OV_TAG_CHECKOUT_BASE = 4000
const OV_TAG_DELETE_BASE = 5000
const OV_TAG_PUSH_BASE = 6000
const OV_TAG_PUSH_STRIDE = 10
const OV_REMOTE_FETCH_BASE = 7000
const OV_REMOTE_PRUNE_BASE = 8000
const OV_PR_OPEN = 9001
const OV_PR_NEW = 9002
const OV_PR_COPY = 9003
const OV_PR_REFRESH = 9004
const OV_PR_BASE = 9100
const OV_PR_CAP = 15
# Plan section I remainder: reflog checkout/copy and per-remote fetch-ref.
# Ranges sit above OV_PR_BASE + OV_PR_CAP so they never collide with the PR
# entries (see phase5.md overflow id space).
const OV_REFLOG_CHECKOUT_BASE = 9200
const OV_REFLOG_COPY_BASE = 9300
const OV_REMOTE_FETCH_REF_BASE = 9400
const OV_LIST_CAP = 20
const OV_MAX_TAG_PUSH_REMOTES = 5

const PAGE_LIMIT = 200

var git_manager = null
var _owns_git_manager = false
var _ui_built = false

var _commits = []
var _branches = []
var _head_hash = ""
var _offset = 0
var _loading = false
var _loading_more = false
var _scroll_to_head_pending = false
var _needs_refresh = false
# True once the manager's first env snapshot has landed (see _on_env_changed:
# the repo gate is false until then, so the first load happens from there).
var _env_ready_seen = false
var _current_rev = ""

var title_label = null
var fetch_button = null
var refresh_button = null
var settings_button = null
var overflow_button = null
var overflow_menu = null
var branch_filter = null
var branch_glob_field = null
var find_widget = null
var scroll = null
var renderer = null
var empty_label = null
var load_more_button = null
var inline_detail = null
var details = null
var compare_sep = null
var compare_view = null
var commit_menu = null
var confirm_dialog = null
var branch_popup = null
var rename_dialog = null
var tag_dialog = null
var stash_dialog = null
var settings_dialog = null
var avatar_http = null
var pr_http = null
var status_label = null
var _repo_ui = []
var _refresh_debounce = null
var _details_hash = ""
var _diff_path = ""
var _inline_height = 0.0
var _inline_uncommitted = false
# Generalized destructive-action confirmation: {"kind", ...fields} where
# kind is reset_hard | stash_drop | branch_delete | tag_delete | rebase.
var _pending_confirm = {}
var _pending_target_hash = ""
var _pending_branch_old = ""
var _tags = []
var _stashes = []
var _remotes = []
var _reflog = []
# VS Code-style "Uncommitted Changes (*)" table row: dirty flag + count from
# the graph_uncommitted query, materialized into _uncommitted_row ({} when
# hidden) and pinned above the log in _renderer_commit_list.
var _has_uncommitted = false
var _uncommitted_count = 0
var _uncommitted_row = {}
var _pending_tags = []
var _pending_stashes = []
var _pending_remotes = []
var _pending_reflog = []
var _overflow_nodes = []
var _overflow_build = 0
# Phase 4 state: display settings, find matches, comparison pair + pending
# diff path, stash keyboard navigation, avatar fetch queue.
var _settings = {}
var _find_hits = []
var _find_pos = -1
var _find_query = ""
var _find_scope = "all"
var _compare_a = ""
var _compare_b = ""
var _compare_path = ""
var _stash_nav = -1
# Stash-commit flag cache: stash `raw` line -> resolved full hash, so the
# per-refresh resolve only queries stashes never seen before (batched async
# via get_stash_hashes; indices shift on push/pop, raws identify).
var _stash_hash_cache = {}
# In-flight batch resolution state: request-time index -> raw snapshot plus
# a guard so one refresh issues at most one batch query.
var _pending_stash_raws = {}
var _stash_resolve_pending = false
var _avatar_queue = []
var _avatar_fetching = false
# Phase 5 state: retained UI context across hide/show, open-PR cache.
var _saved_context = {}
var _prs = []
var _pr_info = {}
var _pr_fetching = false
var _suppress_glob_sync = false


func set_git_manager(manager) -> void:
	if git_manager == manager:
		return
	# Methods AND signals: a base GitManager (or a test fake) satisfies the
	# method list but has no log_loaded/branches_loaded/..., and connecting
	# those anyway crashed at the first access. Keep the previous manager.
	var graph_signals := GitOperations.BASE_SIGNALS.duplicate()
	graph_signals.append_array(GitOperations.GRAPH_SIGNALS)
	if not GitOperations.is_compatible(manager, GitOperations.GRAPH_METHODS, graph_signals):
		push_warning("Git Graph: manager does not satisfy the GitOperations graph contract (methods %s, signals %s); keeping the previous manager." % [
			", ".join(GitOperations.missing_methods(manager, GitOperations.GRAPH_METHODS)),
			", ".join(GitOperations.missing_signals(manager, graph_signals)),
		])
		return
	_disconnect_git_manager()
	if _owns_git_manager and git_manager != null and git_manager.has_method("shutdown"):
		git_manager.shutdown()
	git_manager = manager
	_owns_git_manager = false
	if _ui_built and git_manager != null:
		_connect_git_manager()
		_check_git()
		if git_manager.is_repo():
			refresh()


func _ensure_git_manager() -> void:
	if git_manager != null:
		return
	# Standalone fallback (tab opened without plugin injection): build an
	# owned GraphManager with its own executor + worker so the tab works
	# on its own. Silent by design (verbose only); the plugin injects the
	# shared manager before _ready in the normal tab path, replacing this
	# fallback on arrival.
	git_manager = GitOperations.create_default_graph_manager(ProjectSettings.globalize_path("res://"))
	_owns_git_manager = true
	print_verbose("Git Graph: no manager injected, using owned fallback manager.")


func _connect_git_manager() -> void:
	if git_manager == null:
		return
	if not git_manager.log_loaded.is_connected(_on_log_loaded):
		git_manager.log_loaded.connect(_on_log_loaded)
	if not git_manager.branches_loaded.is_connected(_on_branches_loaded):
		git_manager.branches_loaded.connect(_on_branches_loaded)
	if not git_manager.head_loaded.is_connected(_on_head_loaded):
		git_manager.head_loaded.connect(_on_head_loaded)
	if not git_manager.commit_details_loaded.is_connected(_on_commit_details_loaded):
		git_manager.commit_details_loaded.connect(_on_commit_details_loaded)
	if not git_manager.commit_diff_loaded.is_connected(_on_commit_diff_loaded):
		git_manager.commit_diff_loaded.connect(_on_commit_diff_loaded)
	if not git_manager.tags_loaded.is_connected(_on_tags_loaded):
		git_manager.tags_loaded.connect(_on_tags_loaded)
	if not git_manager.stashes_loaded.is_connected(_on_stashes_loaded):
		git_manager.stashes_loaded.connect(_on_stashes_loaded)
	if not git_manager.stash_hashes_loaded.is_connected(_on_stash_hashes_loaded):
		git_manager.stash_hashes_loaded.connect(_on_stash_hashes_loaded)
	if not git_manager.remotes_loaded.is_connected(_on_remotes_loaded):
		git_manager.remotes_loaded.connect(_on_remotes_loaded)
	if not git_manager.reflog_loaded.is_connected(_on_reflog_loaded):
		git_manager.reflog_loaded.connect(_on_reflog_loaded)
	if not git_manager.uncommitted_loaded.is_connected(_on_uncommitted_loaded):
		git_manager.uncommitted_loaded.connect(_on_uncommitted_loaded)
	if not git_manager.comparison_files_loaded.is_connected(_on_comparison_files_loaded):
		git_manager.comparison_files_loaded.connect(_on_comparison_files_loaded)
	if not git_manager.comparison_diff_loaded.is_connected(_on_comparison_diff_loaded):
		git_manager.comparison_diff_loaded.connect(_on_comparison_diff_loaded)
	if not git_manager.merge_base_ready.is_connected(_on_merge_base_ready):
		git_manager.merge_base_ready.connect(_on_merge_base_ready)
	if not git_manager.operation_complete.is_connected(_on_operation_complete):
		git_manager.operation_complete.connect(_on_operation_complete)
	# is_repo()/get_branch()/has_remote() read a cache the manager refreshes
	# on its worker; re-run the gate when it lands.
	if git_manager.has_signal("env_changed") and not git_manager.env_changed.is_connected(_on_env_changed):
		git_manager.env_changed.connect(_on_env_changed)


func _on_env_changed() -> void:
	var was_ready: bool = _env_ready_seen
	_env_ready_seen = git_manager != null and git_manager.has_method("env_ready") and git_manager.env_ready()
	_check_git()
	# The FIRST snapshot is what makes the repo visible at all: _ready()'s
	# refresh() is gated on is_repo(), which is still false on that frame
	# because the snapshot is resolved on the worker. Without this the tab
	# stayed empty until some unrelated event (a file save, the refresh
	# button, showing the tab) happened to call refresh(). Later env changes
	# come from a checkout / pull / fetch, and those already refresh from
	# their own operation_complete.
	if _env_ready_seen and not was_ready and git_manager != null and git_manager.is_repo():
		refresh()


func _disconnect_git_manager() -> void:
	if git_manager == null:
		return
	if git_manager.log_loaded.is_connected(_on_log_loaded):
		git_manager.log_loaded.disconnect(_on_log_loaded)
	if git_manager.branches_loaded.is_connected(_on_branches_loaded):
		git_manager.branches_loaded.disconnect(_on_branches_loaded)
	if git_manager.head_loaded.is_connected(_on_head_loaded):
		git_manager.head_loaded.disconnect(_on_head_loaded)
	if git_manager.commit_details_loaded.is_connected(_on_commit_details_loaded):
		git_manager.commit_details_loaded.disconnect(_on_commit_details_loaded)
	if git_manager.commit_diff_loaded.is_connected(_on_commit_diff_loaded):
		git_manager.commit_diff_loaded.disconnect(_on_commit_diff_loaded)
	if git_manager.tags_loaded.is_connected(_on_tags_loaded):
		git_manager.tags_loaded.disconnect(_on_tags_loaded)
	if git_manager.stashes_loaded.is_connected(_on_stashes_loaded):
		git_manager.stashes_loaded.disconnect(_on_stashes_loaded)
	if git_manager.stash_hashes_loaded.is_connected(_on_stash_hashes_loaded):
		git_manager.stash_hashes_loaded.disconnect(_on_stash_hashes_loaded)
	if git_manager.remotes_loaded.is_connected(_on_remotes_loaded):
		git_manager.remotes_loaded.disconnect(_on_remotes_loaded)
	if git_manager.reflog_loaded.is_connected(_on_reflog_loaded):
		git_manager.reflog_loaded.disconnect(_on_reflog_loaded)
	if git_manager.uncommitted_loaded.is_connected(_on_uncommitted_loaded):
		git_manager.uncommitted_loaded.disconnect(_on_uncommitted_loaded)
	if git_manager.comparison_files_loaded.is_connected(_on_comparison_files_loaded):
		git_manager.comparison_files_loaded.disconnect(_on_comparison_files_loaded)
	if git_manager.comparison_diff_loaded.is_connected(_on_comparison_diff_loaded):
		git_manager.comparison_diff_loaded.disconnect(_on_comparison_diff_loaded)
	if git_manager.merge_base_ready.is_connected(_on_merge_base_ready):
		git_manager.merge_base_ready.disconnect(_on_merge_base_ready)
	if git_manager.operation_complete.is_connected(_on_operation_complete):
		git_manager.operation_complete.disconnect(_on_operation_complete)
	if git_manager.has_signal("env_changed") and git_manager.env_changed.is_connected(_on_env_changed):
		git_manager.env_changed.disconnect(_on_env_changed)


func _connect_filesystem_signals() -> void:
	if not Engine.is_editor_hint():
		return
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return
	if not fs.filesystem_changed.is_connected(_on_filesystem_changed):
		fs.filesystem_changed.connect(_on_filesystem_changed)


func _disconnect_filesystem_signals() -> void:
	if not Engine.is_editor_hint():
		return
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return
	if fs.filesystem_changed.is_connected(_on_filesystem_changed):
		fs.filesystem_changed.disconnect(_on_filesystem_changed)


func _ready() -> void:
	_build_ui()
	_ensure_git_manager()
	_connect_git_manager()
	_connect_filesystem_signals()
	_check_git()
	if git_manager != null and git_manager.is_repo():
		refresh()


func _exit_tree() -> void:
	_disconnect_filesystem_signals()
	_disconnect_git_manager()
	if _owns_git_manager and git_manager != null and git_manager.has_method("shutdown"):
		git_manager.shutdown()
		git_manager = null
		_owns_git_manager = false


func _enter_tree() -> void:
	_connect_git_manager()
	_connect_filesystem_signals()
	_check_git()
	if _ui_built and git_manager != null and git_manager.is_repo() and _commits.is_empty() and not _loading:
		refresh()


func _make_toolbar_button(button_name: String, glyph: String, tip: String) -> Button:
	# Shared scene (also used by the sidepanel); setup() applies glyph + tip.
	var button = ToolbarButtonScene.instantiate()
	button.name = button_name
	button.setup(glyph, tip)
	return button


func _build_ui() -> void:
	# Idempotent: this wires ~30 child connections (visibility_changed,
	# scroll_ended, every button), so a second pass would duplicate the whole
	# widget tree and double-fire every handler.
	if _ui_built:
		return
	_ui_built = true
	_settings = SettingsDialogScript.load_settings()
	var toolbar := HBoxContainer.new()
	toolbar.name = "GraphToolbar"
	title_label = Label.new()
	title_label.name = "GraphTitle"
	title_label.text = "Git Graph"
	title_label.add_theme_font_size_override("font_size", 13)
	toolbar.add_child(title_label)
	# Find search lives in the toolbar (always visible, between the title
	# and Fetch): query field + scope dropdown, match counter, and prev/next
	# buttons — no close button (Enter / Shift+Enter jump through matches,
	# Escape clears).
	find_widget = FindWidgetScene.instantiate()
	find_widget.name = "GraphFind"
	find_widget.search_changed.connect(_on_find_search_changed)
	find_widget.navigate_prev.connect(_on_find_prev)
	find_widget.navigate_next.connect(_on_find_next)
	toolbar.add_child(find_widget)
	fetch_button = _make_toolbar_button("GraphFetchButton", "⇄", "Fetch from remote")
	fetch_button.pressed.connect(_on_fetch)
	toolbar.add_child(fetch_button)
	refresh_button = _make_toolbar_button("GraphRefreshButton", "↻", "Refresh graph (Ctrl+R)")
	refresh_button.pressed.connect(_on_refresh_button)
	toolbar.add_child(refresh_button)
	settings_button = _make_toolbar_button("GraphSettingsButton", "⚙", "Graph settings")
	settings_button.pressed.connect(_on_settings_pressed)
	toolbar.add_child(settings_button)
	overflow_button = _make_toolbar_button("GraphOverflowButton", "⋯", "More actions (stash, tags, remotes, pull/push)")
	overflow_button.pressed.connect(_on_overflow_pressed)
	toolbar.add_child(overflow_button)
	overflow_menu = PopupMenu.new()
	overflow_menu.name = "GraphOverflowMenu"
	overflow_menu.about_to_popup.connect(_on_overflow_about_to_popup)
	overflow_menu.id_pressed.connect(_on_overflow_id)
	overflow_button.add_child(overflow_menu)
	add_child(toolbar)
	# The toolbar stays visible even without a repo (Refresh re-checks),
	# so it is not part of _repo_ui.

	# Phase 5 branch globs: inline pattern field filtering the dropdown.
	var filter_row = FilterRowScene.instantiate()
	filter_row.name = "GraphFilterRow"
	add_child(filter_row)
	branch_filter = filter_row.get_node("GraphBranchFilter")
	branch_glob_field = filter_row.get_node("GraphBranchGlob")
	branch_filter.item_selected.connect(_on_branch_filter_selected)
	branch_glob_field.text_changed.connect(_on_branch_glob_changed)
	_repo_ui.append(filter_row)

	scroll = ScrollContainer.new()
	scroll.name = "GraphScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_stretch_ratio = 3.0
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	if scroll.has_signal("scroll_ended"):
		scroll.scroll_ended.connect(_on_scroll_ended)
	add_child(scroll)
	_repo_ui.append(scroll)
	renderer = GraphRendererScript.new()
	renderer.name = "GraphCanvas"
	renderer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	renderer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Click-to-focus so Up/Down keyboard navigation has an owner.
	renderer.focus_mode = Control.FOCUS_CLICK
	renderer.commit_selected.connect(_on_commit_selected)
	renderer.commit_context_requested.connect(_on_commit_context)
	renderer.commit_compare_requested.connect(_on_compare_requested)
	renderer.commit_chip_activated.connect(_on_chip_activated)
	renderer.lane_width_changed.connect(_on_lane_width_changed)
	renderer.column_widths_changed.connect(_on_column_widths_changed)
	scroll.add_child(renderer)
	# Viewport culling: the canvas only draws visible rows, so scrolling
	# must redraw (movement alone does not re-run _draw).
	var vbar: VScrollBar = scroll.get_v_scroll_bar()
	if vbar != null and is_instance_valid(vbar):
		vbar.value_changed.connect(_on_graph_scroll_changed)

	# Inline empty state (centered message) for non-repos: a main-screen tab
	# cannot collapse like a dock, so the message replaces the graph area
	# instead of hiding the whole panel.
	empty_label = Label.new()
	empty_label.name = "GraphEmptyLabel"
	empty_label.text = "Not a Git repository."
	empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	empty_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	empty_label.add_theme_font_size_override("font_size", 14)
	empty_label.add_theme_color_override("font_color", Color.GRAY)
	empty_label.visible = false
	add_child(empty_label)

	load_more_button = Button.new()
	load_more_button.name = "GraphLoadMore"
	load_more_button.text = "Load more"
	load_more_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	load_more_button.visible = false
	load_more_button.pressed.connect(_on_load_more)
	add_child(load_more_button)
	# Not in _repo_ui: _check_git shows every repo row, but Load-more is
	# only visible when a full page arrived (see _on_log_loaded).

	# --- Inline commit details: a panel that opens between the selected
	# graph row and the next one (child of the renderer canvas, so it
	# scrolls with the rows). Hidden until the first selection so the
	# graph gets full height on open. `details` is the inner
	# commit_details.gd view, kept so the data-flow handlers below stay
	# unchanged.
	inline_detail = GraphInlineDetailScript.new()
	inline_detail.name = "GraphInlineDetail"
	inline_detail.visible = false
	inline_detail.file_selected.connect(_on_details_file_selected)
	inline_detail.open_file_requested.connect(_on_open_file_requested)
	inline_detail.copy_path_requested.connect(_on_copy_path_requested)
	inline_detail.review_toggled.connect(_on_review_toggled)
	inline_detail.closed.connect(_on_inline_detail_closed)
	renderer.add_child(inline_detail)
	renderer.resized.connect(_on_renderer_resized)
	details = inline_detail.details
	inline_detail.apply_settings(_settings)
	# --- Comparison section (Phase 4): Ctrl+click two rows. Hidden until
	# the first comparison so the graph keeps full height.
	compare_sep = HSeparator.new()
	compare_sep.name = "GraphCompareSeparator"
	compare_sep.visible = false
	add_child(compare_sep)
	compare_view = ComparisonViewScript.new()
	compare_view.name = "GraphCompare"
	compare_view.custom_minimum_size = Vector2(0, 220)
	compare_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	compare_view.size_flags_stretch_ratio = 2.0
	compare_view.visible = false
	compare_view.file_selected.connect(_on_compare_file_selected)
	compare_view.open_file_requested.connect(_on_open_file_requested)
	compare_view.copy_path_requested.connect(_on_copy_path_requested)
	compare_view.swap_requested.connect(_on_compare_swap)
	compare_view.closed.connect(_on_compare_closed)
	add_child(compare_view)
	commit_menu = BranchMenuScript.new()
	commit_menu.name = "GraphCommitMenu"
	commit_menu.checkout_requested.connect(_on_menu_checkout)
	commit_menu.merge_requested.connect(_on_menu_merge)
	commit_menu.cherry_pick_requested.connect(_on_menu_cherry_pick)
	commit_menu.rebase_requested.connect(_on_menu_rebase)
	commit_menu.reset_requested.connect(_on_menu_reset)
	commit_menu.copy_hash_requested.connect(_on_menu_copy_hash)
	commit_menu.copy_message_requested.connect(_on_menu_copy_message)
	commit_menu.create_branch_requested.connect(_on_menu_create_branch)
	commit_menu.create_tag_requested.connect(_on_menu_create_tag)
	commit_menu.branch_rename_requested.connect(_on_menu_branch_rename)
	commit_menu.branch_delete_requested.connect(_on_menu_branch_delete)
	commit_menu.branch_push_requested.connect(_on_menu_branch_push)
	add_child(commit_menu)
	confirm_dialog = ConfirmationDialog.new()
	confirm_dialog.name = "GraphConfirmDialog"
	confirm_dialog.confirmed.connect(_on_confirm_dialog_confirmed)
	add_child(confirm_dialog)
	# Branch creation goes through the shared sidepanel switcher (same
	# creator as the side panel): search doubles as the new-branch name,
	# "Create new branch" targets the clicked commit, "Create new branch
	# from..." picks another source, plus checkout / detach rows.
	branch_popup = BranchPopupScript.new()
	branch_popup.name = "GraphBranchPopup"
	branch_popup.checkout_requested.connect(_on_branch_popup_checkout)
	branch_popup.create_requested.connect(_on_branch_popup_create)
	branch_popup.detach_requested.connect(_on_branch_popup_detach)
	add_child(branch_popup)
	rename_dialog = RenameDialogScene.instantiate()
	rename_dialog.name = "GraphRenameDialog"
	rename_dialog.confirmed.connect(_on_rename_dialog_confirmed)
	add_child(rename_dialog)
	tag_dialog = TagDialogScene.instantiate()
	tag_dialog.name = "GraphTagDialog"
	tag_dialog.confirmed.connect(_on_tag_dialog_confirmed)
	add_child(tag_dialog)
	stash_dialog = StashDialogScene.instantiate()
	stash_dialog.name = "GraphStashDialog"
	stash_dialog.confirmed.connect(_on_stash_dialog_confirmed)
	add_child(stash_dialog)
	# The settings dialog is built on first open (_on_settings_pressed ->
	# _make_settings_dialog), not here: it is a heavyweight construction of
	# every option control and that helper rebuilds it from current settings
	# anyway.
	settings_dialog = null
	avatar_http = HTTPRequest.new()
	avatar_http.name = "GraphAvatarFetch"
	avatar_http.timeout = 15
	avatar_http.request_completed.connect(_on_avatar_fetched)
	add_child(avatar_http)
	# Phase 5 pull-request list fetch (provider REST, 20 max, cached).
	pr_http = HTTPRequest.new()
	pr_http.name = "GraphPrFetch"
	pr_http.timeout = 15
	pr_http.request_completed.connect(_on_prs_fetched)
	add_child(pr_http)
	_sync_glob_field()
	if renderer != null and is_instance_valid(renderer):
		renderer.apply_settings(_settings)

	var sep := HSeparator.new()
	sep.name = "GraphSeparator"
	add_child(sep)
	status_label = Label.new()
	status_label.name = "GraphStatus"
	status_label.text = "Ready"
	status_label.add_theme_font_size_override("font_size", 12)
	status_label.add_theme_color_override("font_color", Color.GRAY)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(status_label)

	_refresh_debounce = Timer.new()
	_refresh_debounce.name = "GraphRefreshDebounce"
	_refresh_debounce.wait_time = 0.5
	_refresh_debounce.one_shot = true
	_refresh_debounce.timeout.connect(_on_refresh_debounce_timeout)
	add_child(_refresh_debounce)
	visibility_changed.connect(_on_visibility_changed)


func _check_git() -> void:
	if git_manager == null:
		return
	if status_label == null:
		return
	# The repo snapshot is resolved on the manager's worker; before the first
	# one lands the cache reads false, which would flash the "Not a Git
	# repository" empty state for a frame.
	if git_manager.has_method("env_ready") and not git_manager.env_ready():
		_set_status("Checking git...", false)
		_set_empty_text("Checking git...")
		_set_repo_ui_visible(false)
		return
	if not git_manager.is_git_available():
		_set_status("Git not found. Please install Git.", true)
		_set_repo_ui_visible(false)
		load_more_button.visible = false
		_set_empty_text("Git not found. Please install Git.")
		return
	if not git_manager.is_repo():
		_set_status("Not a Git repository.", false)
		_set_repo_ui_visible(false)
		load_more_button.visible = false
		_set_empty_text("Not a Git repository.")
		return
	_set_repo_ui_visible(true)


func _set_empty_text(text: String) -> void:
	if empty_label != null and is_instance_valid(empty_label):
		(empty_label as Label).text = text


func _set_repo_ui_visible(visible: bool) -> void:
	for control in _repo_ui:
		if is_instance_valid(control):
			(control as Control).visible = visible
	if not visible and load_more_button != null and is_instance_valid(load_more_button):
		load_more_button.visible = false
	if empty_label != null and is_instance_valid(empty_label):
		empty_label.visible = not visible
	# The toolbar (with the always-visible find search) stays up for
	# Refresh; the search itself is disabled without a repo.
	if find_widget != null and is_instance_valid(find_widget):
		if find_widget.search_field != null and is_instance_valid(find_widget.search_field):
			find_widget.search_field.editable = visible
		if find_widget.scope_button != null and is_instance_valid(find_widget.scope_button):
			find_widget.scope_button.disabled = not visible
	if not visible:
		_clear_find_search()
		_close_compare_silent()
		_close_inline_detail()
	_apply_compare_visibility()


func _set_status(text: String, is_error: bool) -> void:
	if status_label == null:
		return
	status_label.text = text
	if is_error:
		status_label.add_theme_color_override("font_color", Color.RED)
	else:
		status_label.add_theme_color_override("font_color", Color.GRAY)


func _set_busy(busy: bool) -> void:
	_loading = busy
	if refresh_button != null:
		refresh_button.disabled = busy
	if fetch_button != null:
		fetch_button.disabled = busy


# Shared pre-flight for pull/fetch (DRY): null manager, non-repo, and
# missing-remote checks with status reporting. The checks live in
# editor_utils.guard_remote_op (shared with the side panel); this wrapper
# only adapts the panel's (text, is_error) status signature and re-runs
# _check_git on a non-repo. True means proceed.
func _guard_remote_op() -> bool:
	if git_manager != null and not git_manager.is_repo():
		_check_git()
	return EditorUtils.guard_remote_op(git_manager, Callable(self, "_set_status"))


# Full reload: first page of the log plus branches, HEAD, and the auxiliary
# lists (tags/stashes/remotes/reflog feed the overflow menu and the
# row-menu branch submenus). All are fast local reads on the one worker
# thread; details/diff/compare loads are never triggered from here.
func refresh() -> void:
	if git_manager == null:
		return
	_check_git()
	if not git_manager.is_repo():
		return
	_offset = 0
	_loading_more = false
	_scroll_to_head_pending = true
	_set_busy(true)
	_set_status("Loading commits...", false)
	git_manager.get_log(_page_limit(), 0, _current_rev, String(_settings.get("commit_order", "topo")))
	git_manager.get_branches(true)
	git_manager.get_head()
	git_manager.get_tags()
	git_manager.get_stashes()
	git_manager.get_remotes()
	git_manager.get_reflog()
	git_manager.get_uncommitted_count()
	# Stash hashes are NOT queried here: _apply_stash_flags() batches one
	# read for only the stashes it has not resolved yet, and caches them by
	# raw line. Eagerly resolving all of them on every refresh was the cost
	# this batching exists to remove.


func _page_limit() -> int:
	return clampi(int(_settings.get("initial_load_count", PAGE_LIMIT)), 50, 1000)


func _on_refresh_button() -> void:
	refresh()


func _on_refresh_debounce_timeout() -> void:
	if visible and git_manager != null and git_manager.is_repo() and not _loading:
		_needs_refresh = false
		refresh()


# Phase 5 context retention (plan item 29): hiding the tab snapshots
# scroll, selection, inline details, filter, find, and comparison state;
# showing it again restores the snapshot instead of resetting to the top.
# A pending filesystem refresh still runs, and then re-applies the saved
# selection/scroll on top of the fresh page (see _on_log_loaded).
#
# is_visible_in_tree(), not `visible`: the plugin hides the PARENT frame
# (plugin.gd _make_visible), which leaves this node's own flag true while
# still emitting visibility_changed on hide AND on show. Testing `visible`
# made the save half unreachable and ran refresh() on both transitions.
func _on_visibility_changed() -> void:
	if not is_visible_in_tree():
		_save_context()
		return
	if git_manager == null or not git_manager.is_repo():
		return
	if _needs_refresh and not _loading:
		_needs_refresh = false
		refresh()
	elif not _saved_context.is_empty():
		_restore_context()


func _save_context() -> void:
	var sel := ""
	if renderer != null and is_instance_valid(renderer):
		var current: Dictionary = renderer.selected_commit()
		sel = String(current.get("hash", ""))
	_saved_context = {
		"scroll": int(scroll.scroll_vertical) if scroll != null and is_instance_valid(scroll) else 0,
		"selected_hash": sel,
		"details_hash": String(_details_hash),
		"diff_path": String(_diff_path),
		"inline_height": float(_inline_height),
		"inline_uncommitted": bool(_inline_uncommitted),
		"current_rev": String(_current_rev),
		"filter_index": int(branch_filter.selected) if branch_filter != null and is_instance_valid(branch_filter) else 0,
		"find_query": String(_find_query),
		"find_scope": String(_find_scope),
		"compare_a": String(_compare_a),
		"compare_b": String(_compare_b),
		"compare_path": String(_compare_path),
		"stash_nav": int(_stash_nav),
	}


# Re-hydrate the panel fields from a _save_context() snapshot. Shared by the
# two restore entry points (no-op restore, and restore-on-top-of-a-fresh-log),
# so a new snapshot key only has to be handled once. Returns the snapshot's
# selection hash and scroll offset for the caller's own tail.
func _apply_saved_context(ctx: Dictionary) -> Dictionary:
	_inline_height = float(ctx.get("inline_height", _inline_height))
	_inline_uncommitted = bool(ctx.get("inline_uncommitted", _inline_uncommitted))
	_details_hash = String(ctx.get("details_hash", _details_hash))
	_diff_path = String(ctx.get("diff_path", _diff_path))
	_current_rev = String(ctx.get("current_rev", _current_rev))
	_find_query = String(ctx.get("find_query", _find_query))
	_find_scope = String(ctx.get("find_scope", _find_scope))
	_stash_nav = int(ctx.get("stash_nav", _stash_nav))
	# The dropdown must agree with the restored rev, or the filter reads
	# "All branches" while the log is scoped to a branch (and the next
	# dropdown interaction silently drops the rev).
	_restore_branch_filter(int(ctx.get("filter_index", 0)))
	if find_widget != null and is_instance_valid(find_widget):
		find_widget.set_query(_find_query)
		find_widget.set_scope(_find_scope)
	# set_query blocks the widget's signals, so the search never re-runs on
	# its own: re-run it here or the field shows text with stale/no matches.
	_rerun_find()
	return {"selected_hash": String(ctx.get("selected_hash", "")), "scroll": int(ctx.get("scroll", 0))}


func _restore_branch_filter(index: int) -> void:
	if branch_filter == null or not is_instance_valid(branch_filter):
		return
	# An empty dropdown (branches not loaded yet - the restore runs during a
	# log load) cannot be indexed: select(0) on an empty popup is an
	# out-of-bounds error. _rebuild_branch_filter picks the item up from
	# _current_rev when the list finally arrives.
	if branch_filter.item_count <= 0:
		return
	if index < 0 or index >= branch_filter.item_count:
		index = 0
	branch_filter.select(index)


func _restore_context() -> void:
	if _saved_context.is_empty():
		return
	var ctx: Dictionary = _saved_context
	_saved_context = {}
	var state := _apply_saved_context(ctx)
	var want_hash := String(state.get("selected_hash", ""))
	var saved_scroll := int(state.get("scroll", 0))
	if not want_hash.is_empty() and renderer != null and is_instance_valid(renderer):
		var idx: int = renderer.index_of_hash(want_hash)
		if idx != -1:
			renderer.select_index(idx)
			_restore_inline_after_list()
			if inline_detail != null and is_instance_valid(inline_detail) and inline_detail.visible:
				if scroll != null and is_instance_valid(scroll):
					scroll.scroll_vertical = saved_scroll
			else:
				_scroll_to_index(idx)
		# else: the saved commit is not on the loaded page (a log refresh
		# while hidden drops it). Nothing to reselect; the list keeps its
		# own position rather than jumping to a wrong row.
	elif scroll != null and is_instance_valid(scroll):
		scroll.scroll_vertical = saved_scroll
	var ca := String(ctx.get("compare_a", ""))
	var cb := String(ctx.get("compare_b", ""))
	if not ca.is_empty() and not cb.is_empty():
		_open_compare(ca, cb)
		_compare_path = String(ctx.get("compare_path", ""))
	_apply_compare_visibility()


func _on_filesystem_changed() -> void:
	_needs_refresh = true
	if _refresh_debounce != null and is_instance_valid(_refresh_debounce):
		_refresh_debounce.start()


func _on_load_more() -> void:
	if git_manager == null or _loading:
		return
	_loading_more = true
	_set_busy(true)
	_set_status("Loading more commits...", false)
	git_manager.get_log(_page_limit(), _offset, _current_rev, String(_settings.get("commit_order", "topo")))


func _on_graph_scroll_changed(_value: float) -> void:
	if renderer != null and is_instance_valid(renderer):
		renderer.queue_redraw()


# Auto-load the next page when the user reaches the bottom (settings
# toggle, default off). Guarded like the manual button: repo, idle, and a
# full previous page (otherwise there is nothing more to fetch).
func _on_scroll_ended() -> void:
	if not bool(_settings.get("auto_load_more", false)):
		return
	if git_manager == null or _loading or not git_manager.is_repo():
		return
	if load_more_button == null or not is_instance_valid(load_more_button):
		return
	if not load_more_button.visible:
		return
	if scroll == null or not is_instance_valid(scroll):
		return
	var bar: VScrollBar = scroll.get_v_scroll_bar()
	if bar == null:
		return
	if bar.value >= bar.max_value - bar.page - 4.0:
		_on_load_more()


func _on_fetch() -> void:
	if not _guard_remote_op():
		return
	_set_busy(true)
	_set_status("Fetching...", false)
	git_manager.fetch()


func _on_branch_filter_selected(index: int) -> void:
	if branch_filter == null:
		return
	var label: String = branch_filter.get_item_text(index)
	if index == 0:
		_current_rev = ""
	else:
		_current_rev = _rev_for_branch_label(label)
	refresh()


# The filter shows display names; map back to something `git log` accepts.
func _rev_for_branch_label(label: String) -> String:
	for b in _branches:
		var info: Dictionary = b
		if String(info.get("name", "")) == label:
			if bool(info.get("detached", false)):
				return "HEAD"
			return label
	return label


func _on_log_loaded(commits: Array) -> void:
	if _loading_more:
		_commits.append_array(commits)
		# Lanes must be computed over the MERGED list: the manager no longer
		# assigns them per page, and a page laid out on its own would restart
		# at lane 0 and collide with the pages above it.
		PanelGraphUtils.assign_lanes(_commits)
	else:
		_commits = commits
		PanelGraphUtils.assign_lanes(_commits)
	_offset = _commits.size()
	_loading_more = false
	_apply_stash_flags()
	_rebuild_uncommitted_row()
	_renderer_commit_list()
	_set_busy(false)
	load_more_button.visible = commits.size() >= _page_limit()
	if _commits.is_empty():
		_set_status("No commits yet.", false)
	else:
		_set_status("Loaded %d commits." % _commits.size(), false)
	_rerun_find()
	_refresh_avatars()
	if _consume_saved_context_after_load():
		return
	if _scroll_to_head_pending:
		_try_scroll_to_head()


# Visibility-refresh path: the tab was hidden while _save_context held the
# UI state and a reload just landed. Reselect the saved commit (or fall
# back to the raw scroll offset) instead of jumping to HEAD. Returns true
# when a restore was applied.
func _consume_saved_context_after_load() -> bool:
	if _saved_context.is_empty():
		return false
	var ctx: Dictionary = _saved_context
	_saved_context = {}
	var state := _apply_saved_context(ctx)
	var want_hash := String(state.get("selected_hash", ""))
	var saved_scroll := int(state.get("scroll", 0))
	if not want_hash.is_empty() and renderer != null and is_instance_valid(renderer):
		var idx: int = renderer.index_of_hash(want_hash)
		if idx != -1:
			_scroll_to_head_pending = false
			renderer.select_index(idx)
			_restore_inline_after_list()
			if _inline_uncommitted and inline_detail != null and is_instance_valid(inline_detail):
				inline_detail.show_uncommitted(_uncommitted_count)
				_update_inline_detail_size()
			elif not _details_hash.is_empty() and git_manager != null:
				git_manager.get_commit_details(_details_hash)
			if inline_detail != null and is_instance_valid(inline_detail) and inline_detail.visible:
				if scroll != null and is_instance_valid(scroll):
					scroll.scroll_vertical = saved_scroll
			else:
				_scroll_to_index(idx)
			_apply_compare_visibility()
			return true
	if scroll != null and is_instance_valid(scroll):
		scroll.scroll_vertical = saved_scroll
	_scroll_to_head_pending = false
	return true


func _renderer_commit_list() -> void:
	if renderer != null and is_instance_valid(renderer):
		# Preserve the selection across rebuilds: prepending the uncommitted
		# row shifts every commit index by one, so reselect by hash.
		var sel_hash := ""
		var current: Dictionary = renderer.selected_commit()
		if not current.is_empty():
			sel_hash = String(current.get("hash", ""))
		var display: Array = []
		if not _uncommitted_row.is_empty():
			display.append(_uncommitted_row)
		if bool(_settings.get("show_stashes", true)):
			display.append_array(_commits)
		else:
			for c in _commits:
				if not bool((c as Dictionary).get("is_stash", false)):
					display.append(c)
		renderer.set_commits(display)
		renderer.set_head(_head_hash)
		if not sel_hash.is_empty():
			var ni: int = renderer.index_of_hash(sel_hash)
			if ni != -1:
				renderer.select_index(ni)
			elif sel_hash == "*":
				# The selected uncommitted row vanished (worktree cleaned):
				# clear instead of leaving the highlight on a new commit.
				renderer.selected = -1
				renderer.queue_redraw()
		_restore_inline_after_list()


# Re-anchor the inline detail gap after the commit list is rebuilt
# (refresh, pagination, uncommitted poll): reselect by hash, since
# prepending the uncommitted row shifts every commit index by one. When
# the open commit is gone, the panel closes instead of pointing at a new
# row.
func _restore_inline_after_list() -> void:
	if renderer == null or not is_instance_valid(renderer):
		return
	if inline_detail == null or not is_instance_valid(inline_detail):
		return
	var want := ""
	if _inline_uncommitted:
		want = "*"
	elif not _details_hash.is_empty():
		want = _details_hash
	if want.is_empty():
		renderer.clear_detail()
		inline_detail.visible = false
		return
	var idx: int = renderer.index_of_hash(want)
	if idx == -1:
		_close_inline_detail()
		return
	if _inline_height <= 0.0:
		_inline_height = inline_detail.desired_height()
	renderer.set_detail(idx, _inline_height)
	_layout_inline_detail()


# The uncommitted row pins to the top of the All-branches view only: a
# branch-scoped log (_current_rev) lists that ref's history, where a
# worktree row would be misleading.
func _rebuild_uncommitted_row() -> void:
	if bool(_settings.get("show_uncommitted", true)) and _has_uncommitted and String(_current_rev).is_empty():
		_uncommitted_row = PanelGraphUtils.make_uncommitted_commit()
	else:
		_uncommitted_row = {}


# Upstream stash nodes (web/graph.ts Vertex isStash): flag the loaded log
# commits that ARE stash commits so the renderer draws the double-circle
# node + stash tooltip instead of a plain node. `git log --all` already
# carries stash commits (refs/stash); each stash list entry resolves to its
# hash via the batched get_stash_hashes worker query (cached by raw line,
# one git process for all unknown stashes). Stashes outside the loaded page
# stay menu-only (same loaded-page limit as find).
func _apply_stash_flags() -> void:
	# Prune hashes for stashes that no longer exist (dropped upstream). Runs
	# BEFORE the early returns: dropping the last stash is exactly when
	# _stashes empties out, and that is when the cache needs reclaiming.
	if _stash_hash_cache.size() > 60 and not _stashes.is_empty():
		var live := {}
		for s in _stashes:
			var raw := String((s as Dictionary).get("raw", ""))
			if _stash_hash_cache.has(raw):
				live[raw] = _stash_hash_cache[raw]
		_stash_hash_cache = live
	if _commits.is_empty() or _stashes.is_empty():
		return
	if git_manager == null:
		return
	var by_hash := {}
	for i in range(_commits.size()):
		by_hash[String((_commits[i] as Dictionary).get("hash", ""))] = i
	# Unknown raws resolve asynchronously (perf): the old synchronous
	# rev_parse loop blocked the main thread once per new stash. Flags for
	# already-cached hashes apply immediately below; newly resolved ones
	# re-flag via _on_stash_hashes_loaded.
	var need: Array = []
	for s in _stashes:
		var info: Dictionary = s
		var idx := int(info.get("index", -1))
		if idx < 0:
			continue
		if not String(_stash_hash_cache.get(String(info.get("raw", "")), "")).is_empty():
			continue
		if not need.has(idx):
			need.append(idx)
	if not need.is_empty() and not _stash_resolve_pending and git_manager.has_method("get_stash_hashes"):
		# Snapshot index -> raw now: indices shift on push/pop, so the
		# load handler maps results through this snapshot, not the live
		# list.
		_pending_stash_raws = {}
		for s in _stashes:
			var info: Dictionary = s
			var idx := int(info.get("index", -1))
			if need.has(idx):
				_pending_stash_raws[idx] = String(info.get("raw", ""))
		_stash_resolve_pending = true
		git_manager.get_stash_hashes(need)
	_flag_stashes_with_cache(by_hash)
	_prune_stash_hash_cache()


# Flag loaded log commits that ARE stash commits using only already-resolved
# hashes (sync, no git). Unknown raws are resolved separately (async batch).
func _flag_stashes_with_cache(by_hash: Dictionary) -> void:
	for s in _stashes:
		var info: Dictionary = s
		var raw := String(info.get("raw", ""))
		var idx := int(info.get("index", -1))
		if idx < 0:
			continue
		# Unresolved: the hash query has not landed for this entry yet. The
		# stash_hashes_loaded handler re-runs this pass when it does.
		var resolved := String(_stash_hash_cache.get(raw, ""))
		if resolved.is_empty():
			continue
		if not by_hash.has(resolved):
			continue
		var commit: Dictionary = _commits[int(by_hash[resolved])]
		if bool(commit.get("is_stash", false)):
			continue
		commit["is_stash"] = true
		commit["stash_selector"] = PanelGraphUtils.stash_ref(idx)
		var parents: Array = commit.get("parents", [])
		commit["stash_base"] = String(parents[0]) if not parents.is_empty() else ""
		if String(commit.get("subject", "")).strip_edges().is_empty():
			commit["subject"] = "stash@{%d}: %s" % [idx, String(info.get("message", ""))]


# Batch resolution landed: merge hashes into the cache (via the request-time
# raw snapshot), re-flag, and rebuild the display list.
func _on_stash_hashes_loaded(entries: Array) -> void:
	_stash_resolve_pending = false
	if entries.is_empty():
		_pending_stash_raws = {}
		return
	for e in entries:
		var info: Dictionary = e
		var raw := String(_pending_stash_raws.get(int(info.get("index", -1)), ""))
		var h := String(info.get("hash", ""))
		if not raw.is_empty() and not h.is_empty():
			_stash_hash_cache[raw] = h
	_pending_stash_raws = {}
	if _commits.is_empty():
		return
	var by_hash := {}
	for i in range(_commits.size()):
		by_hash[String((_commits[i] as Dictionary).get("hash", ""))] = i
	_flag_stashes_with_cache(by_hash)
	_prune_stash_hash_cache()
	_renderer_commit_list()


func _prune_stash_hash_cache() -> void:
	# Prune hashes for stashes that no longer exist (dropped upstream).
	if _stash_hash_cache.size() > 60:
		var live := {}
		for s in _stashes:
			var raw := String((s as Dictionary).get("raw", ""))
			if _stash_hash_cache.has(raw):
				live[raw] = _stash_hash_cache[raw]
			_stash_hash_cache = live


func _on_uncommitted_loaded(has_changes: bool, count: int) -> void:
	_has_uncommitted = bool(has_changes)
	_uncommitted_count = maxi(int(count), 0)
	_rebuild_uncommitted_row()
	_renderer_commit_list()
	_rerun_find()
	# The dirtiness query lands after the log page: re-anchor HEAD so the
	# newly pinned row cannot push it out of view before first interaction.
	if renderer != null and is_instance_valid(renderer) and renderer.selected < 0 and _details_hash.is_empty() and not _inline_uncommitted:
		_try_scroll_to_head()


func _on_branches_loaded(branches: Array) -> void:
	_branches = branches
	_rebuild_branch_filter()


# Auxiliary lists arrive via signals but only commit to the caches on the
# matching operation_complete success: a failed load emits an empty list,
# which must not wipe a good cache (e.g. a transient git lock hiccup).
func _on_tags_loaded(tags: Array) -> void:
	_pending_tags = tags


func _on_stashes_loaded(stashes: Array) -> void:
	_pending_stashes = stashes


func _on_remotes_loaded(remotes: Array) -> void:
	_pending_remotes = remotes


func _on_reflog_loaded(entries: Array) -> void:
	_pending_reflog = entries


# Phase 5 branch globs (plan item 31): the dropdown lists only branches
# matching _settings["branch_glob"] (comma-separated, `!` negates).
# Empty glob lists everything (previous behavior).
func _rebuild_branch_filter() -> void:
	if branch_filter == null:
		return
	var previous := ""
	if branch_filter.item_count > 0 and branch_filter.selected >= 0:
		previous = branch_filter.get_item_text(branch_filter.selected)
	# _current_rev wins whenever it is set and the dropdown does not already
	# show it (first build, or a rebuild from an "All branches" state after a
	# config import / tab restore): the filter has to follow the rev, not the
	# other way round, or a branch-scoped log sits under an "All branches"
	# dropdown and the next interaction silently discards the rev.
	# Deferred while the branch list is still empty - there is no label to
	# map the rev to yet, and the rebuild runs again when it arrives.
	if not _current_rev.is_empty() and not _branches.is_empty():
		var rev_label := _label_for_rev(_current_rev)
		if rev_label.is_empty():
			# Rev is gone from the loaded branch list (deleted upstream):
			# drop it, and fall back to All rather than keeping a rev that
			# fails the next load - or leaving the dropdown on a branch the
			# log no longer follows.
			_current_rev = ""
			previous = ""
		else:
			previous = rev_label
	branch_filter.clear()
	branch_filter.add_item("All branches")
	var select := 0
	var found := previous.is_empty() or previous == "All branches"
	var glob := String(_settings.get("branch_glob", ""))
	for b in _branches:
		var info: Dictionary = b
		var label := String(info.get("name", ""))
		if label.is_empty():
			continue
		if not PanelGraphUtils.match_any_glob(label, glob):
			continue
		branch_filter.add_item(label)
		if label == previous:
			select = branch_filter.item_count - 1
			found = true
	if not found:
		# Previously selected branch is gone (deleted upstream or newly
		# filtered out): fall back to All instead of keeping a rev that
		# would fail the next load.
		_current_rev = ""
		select = 0
	branch_filter.selected = select


# Dropdown label whose rev is `rev` (labels are the branch "name";
# _rev_for_branch_label is the forward mapping and handles detached HEAD).
# "" when the rev is not in the loaded branch list.
func _label_for_rev(rev: String) -> String:
	if rev.is_empty():
		return ""
	for b in _branches:
		var info: Dictionary = b
		var label := String(info.get("name", ""))
		if not label.is_empty() and _rev_for_branch_label(label) == rev:
			return label
	return ""


func _sync_glob_field() -> void:
	if branch_glob_field == null or not is_instance_valid(branch_glob_field):
		return
	_suppress_glob_sync = true
	branch_glob_field.text = String(_settings.get("branch_glob", ""))
	_suppress_glob_sync = false


func _on_branch_glob_changed(new_text: String) -> void:
	if _suppress_glob_sync:
		return
	_settings["branch_glob"] = String(new_text).strip_edges()
	SettingsDialogScript.save_settings(_settings)
	_rebuild_branch_filter()


func _on_head_loaded(hash_value: String) -> void:
	_head_hash = String(hash_value)
	if renderer != null and is_instance_valid(renderer):
		renderer.set_head(_head_hash)
	if _scroll_to_head_pending:
		_try_scroll_to_head()


func _try_scroll_to_head() -> void:
	if _head_hash.is_empty() or renderer == null or not is_instance_valid(renderer):
		return
	if not is_instance_valid(scroll) or _commits.is_empty():
		return
	_scroll_to_head_pending = false
	var idx: int = renderer.index_of_hash(_head_hash)
	if idx == -1:
		return
	_scroll_to_index(idx)


func _on_commit_selected(commit: Dictionary) -> void:
	if renderer == null or not is_instance_valid(renderer):
		return
	if inline_detail == null or not is_instance_valid(inline_detail):
		return
	# Clicking the already-open commit closes its inline panel again.
	# (Right-clicks never reach this branch for the open row: the
	# renderer skips its commit_selected emission when the row is
	# already selected, so the context menu cannot toggle it shut.)
	var picked_hash := String(commit.get("hash", ""))
	if not _details_hash.is_empty() and picked_hash == _details_hash and inline_detail.visible:
		_on_inline_detail_closed()
		return
	# The uncommitted row has no hash to `git show`: point at the
	# Source Control panel instead of firing a doomed details load.
	if bool(commit.get("uncommitted", false)):
		# Resolve the anchor row BEFORE touching panel state: if the row is
		# gone, nothing is shown, and state claiming an open inline panel
		# would make the next list rebuild try (and fail) to re-anchor it.
		var uidx: int = renderer.index_of_hash("*")
		if uidx == -1:
			uidx = renderer.selected
		if uidx < 0 or uidx >= renderer.commits.size():
			return
		_details_hash = ""
		_diff_path = ""
		_inline_uncommitted = true
		_set_status("Uncommitted Changes (%d files) — stage and commit from the Source Control panel." % _uncommitted_count, false)
		inline_detail.show_uncommitted(_uncommitted_count)
		_open_inline_detail(uidx)
		return
	_inline_uncommitted = false
	_details_hash = picked_hash
	_diff_path = ""
	_set_status(
		"%s  %s — %s, %s" % [
			String(commit.get("short", "")),
			String(commit.get("subject", "")),
			String(commit.get("author", "")),
			PanelGraphUtils.format_graph_date(String(commit.get("date", "")), String(_settings.get("date_format", "iso"))),
		],
		false
	)
	# Stash navigation passes a synthetic commit that is not a graph row:
	# anchor the panel at the current selection when the hash is absent.
	var idx: int = renderer.index_of_hash(_details_hash)
	if idx == -1:
		idx = renderer.selected
	if idx < 0 or idx >= renderer.commits.size():
		_close_inline_detail()
		return
	inline_detail.show_commit(commit)
	_open_inline_detail(idx)
	if git_manager != null and not _details_hash.is_empty():
		git_manager.get_commit_details(_details_hash)


# Reserve the renderer gap under row idx and position the inline panel in
# it. The panel stays open until another commit is clicked (or closed).
func _open_inline_detail(idx: int) -> void:
	if renderer == null or not is_instance_valid(renderer):
		return
	if inline_detail == null or not is_instance_valid(inline_detail):
		return
	if idx < 0 or idx >= renderer.commits.size():
		return
	if _inline_height <= 0.0:
		_inline_height = inline_detail.desired_height()
	renderer.set_detail(idx, _inline_height)
	_layout_inline_detail()
	_update_inline_detail_size()
	_ensure_inline_visible()


func _layout_inline_detail() -> void:
	if renderer == null or not is_instance_valid(renderer):
		return
	if inline_detail == null or not is_instance_valid(inline_detail):
		return
	if details == null or not is_instance_valid(details):
		details = inline_detail.details
	if not renderer.is_detail_visible():
		inline_detail.visible = false
		return
	inline_detail.set_lane_width(renderer.detail_gutter_width())
	inline_detail.position = Vector2(0, renderer.detail_y())
	inline_detail.size = Vector2(maxf(renderer.size.x, 10.0), renderer.detail_height)
	inline_detail.visible = true
	renderer.queue_redraw()


func _close_inline_detail() -> void:
	_details_hash = ""
	_diff_path = ""
	_inline_height = 0.0
	_inline_uncommitted = false
	if renderer != null and is_instance_valid(renderer):
		renderer.clear_detail()
	if inline_detail != null and is_instance_valid(inline_detail):
		inline_detail.visible = false


func _on_inline_detail_closed() -> void:
	_close_inline_detail()
	if renderer != null and is_instance_valid(renderer):
		renderer.selected = -1
		renderer.queue_redraw()
	_set_status("Commit details closed.", false)


# Recompute the auto-size height from the loaded content and grow/shrink
# the renderer gap to match. Rows below the panel shift accordingly.
func _update_inline_detail_size() -> void:
	if renderer == null or not is_instance_valid(renderer):
		return
	if inline_detail == null or not is_instance_valid(inline_detail):
		return
	if not inline_detail.visible or not renderer.is_detail_visible():
		return
	var want: float = inline_detail.desired_height()
	if is_equal_approx(want, _inline_height) and is_equal_approx(want, renderer.detail_height):
		return
	_inline_height = want
	renderer.set_detail(renderer.detail_index, _inline_height)
	_layout_inline_detail()


func _on_renderer_resized() -> void:
	_layout_inline_detail()
	# Viewport culling depends on the laid-out size: a first draw with a
	# zero-size viewport culls everything, so always redraw on resize.
	if renderer != null and is_instance_valid(renderer):
		renderer.queue_redraw()


# After opening, make sure the whole panel is readable: scroll just
# enough to reveal it when its bottom falls outside the viewport.
func _ensure_inline_visible() -> void:
	if inline_detail == null or not is_instance_valid(inline_detail):
		return
	if not inline_detail.visible:
		return
	if scroll == null or not is_instance_valid(scroll):
		return
	if renderer == null or not is_instance_valid(renderer):
		return
	await get_tree().process_frame
	if not is_instance_valid(scroll) or not is_instance_valid(renderer):
		return
	if inline_detail == null or not is_instance_valid(inline_detail):
		return
	if not inline_detail.visible:
		return
	var top: float = inline_detail.position.y
	var bottom: float = top + inline_detail.size.y
	var view_top := float(scroll.scroll_vertical)
	var view_h := maxf(scroll.size.y - 8.0, 120.0)
	if bottom > view_top + view_h:
		scroll.scroll_vertical = int(maxf(bottom - view_h + 12.0, 0.0))
	elif top < view_top + float(renderer.row_height()):
		scroll.scroll_vertical = int(maxf(top - 12.0, 0.0))


func _on_commit_details_loaded(loaded: Dictionary) -> void:
	if details == null or not is_instance_valid(details):
		return
	# Stale guard: the user may have clicked elsewhere while this was loading.
	if String(loaded.get("hash", "")) != _details_hash:
		return
	details.show_details(loaded)
	_update_inline_detail_size()
	# The details view auto-selects its first file, which fires
	# file_selected and drives the first diff load (see
	# _on_details_file_selected).


func _on_details_file_selected(path: String) -> void:
	if git_manager == null or _details_hash.is_empty():
		return
	_diff_path = String(path)
	git_manager.get_commit_diff(_details_hash, _diff_path)


func _on_commit_diff_loaded(result: Dictionary) -> void:
	if details == null or not is_instance_valid(details):
		return
	if String(result.get("hash", "")) != _details_hash:
		return
	if String(result.get("path", "")) != _diff_path:
		return
	details.diff_view.set_diff(String(result.get("diff", "")), bool(result.get("truncated", false)))
	_update_inline_detail_size()


func _on_commit_context(commit: Dictionary) -> void:
	if commit_menu == null or not is_instance_valid(commit_menu):
		return
	if bool(commit.get("uncommitted", false)):
		_set_status("Uncommitted Changes — stage and commit from the Source Control panel.", false)
		return
	commit_menu.popup_for_commit(commit, _current_branch_name(), _branches, _remotes)


# --- Phase 2 context-menu actions ---

func _on_menu_checkout(ref: String) -> void:
	if git_manager == null:
		return
	_set_busy(true)
	_set_status("Checking out %s..." % ref, false)
	git_manager.checkout_ref(ref)


# Clicked ref chip: confirm before switching. The current branch
# needs no switch; tags check out detached (same as the context menu).
func _on_chip_activated(_commit: Dictionary, ref: String, kind: String) -> void:
	if git_manager == null:
		return
	var target := String(ref).strip_edges()
	if target.is_empty():
		return
	if String(kind) == "branch" and target == _current_branch_name():
		_set_status("Already on branch '%s'." % target, false)
		return
	if String(kind) == "tag":
		_ask_confirm("checkout_chip", "Check out tag '%s'? HEAD will be detached at that tag." % target, {"ref": target})
	else:
		_ask_confirm("checkout_chip", "Switch to branch '%s'? The worktree switches to that branch." % target, {"ref": target})


func _on_menu_merge(ref: String) -> void:
	if git_manager == null:
		return
	_set_busy(true)
	_set_status("Merging %s..." % ref, false)
	git_manager.merge_ref(ref)


func _on_menu_cherry_pick(commit_hash: String) -> void:
	if git_manager == null:
		return
	if String(commit_hash).is_empty():
		return
	_set_busy(true)
	_set_status("Cherry-picking %s..." % PanelGraphUtils.short_hash(commit_hash), false)
	git_manager.cherry_pick(commit_hash)


func _on_menu_rebase(commit_hash: String) -> void:
	if git_manager == null:
		return
	if String(commit_hash).is_empty():
		return
	# Rebase rewrites the current branch: confirm first, like hard reset.
	_ask_confirm("rebase", "Rebase the current branch onto %s? Commits will be rewritten. This cannot be undone (recover via the reflog menu)." % PanelGraphUtils.short_hash(commit_hash), {"hash": String(commit_hash)})


func _on_menu_reset(commit_hash: String, mode: String) -> void:
	if git_manager == null:
		return
	if String(mode) == "hard":
		# Hard reset discards index + worktree changes: confirm first, like
		# the side panel's discard dialog. Soft/mixed keep the worktree.
		_ask_confirm("reset_hard", "Hard-reset the current branch to %s? Index and working-tree changes will be lost. This cannot be undone." % PanelGraphUtils.short_hash(commit_hash), {"hash": commit_hash, "mode": mode})
		return
	_do_reset(commit_hash, mode)


# Shared destructive-action confirmation. Stores the pending payload and
# shows the dialog; _on_confirm_dialog_confirmed routes by kind.
func _ask_confirm(kind: String, prompt: String, fields: Dictionary) -> void:
	_pending_confirm = {"kind": kind}
	for key in fields:
		_pending_confirm[key] = fields[key]
	if confirm_dialog != null and is_instance_valid(confirm_dialog):
		confirm_dialog.dialog_text = prompt
		confirm_dialog.popup_centered()


func _on_confirm_dialog_confirmed() -> void:
	if _pending_confirm.is_empty() or git_manager == null:
		return
	var pending: Dictionary = _pending_confirm
	_pending_confirm = {}
	match String(pending.get("kind", "")):
		"reset_hard":
			_do_reset(String(pending.get("hash", "")), String(pending.get("mode", "mixed")))
		"rebase":
			_do_rebase(String(pending.get("hash", "")))
		"stash_drop":
			_do_stash_drop(int(pending.get("index", 0)))
		"branch_delete":
			_do_branch_delete(String(pending.get("name", "")))
		"tag_delete":
			_do_tag_delete(String(pending.get("name", "")))
		"checkout_chip":
			_on_menu_checkout(String(pending.get("ref", "")))


func _do_reset(commit_hash: String, mode: String) -> void:
	if commit_hash.is_empty():
		return
	_set_busy(true)
	_set_status("Resetting (%s) to %s..." % [mode, PanelGraphUtils.short_hash(commit_hash)], false)
	git_manager.reset_ref(commit_hash, mode)


func _do_rebase(commit_hash: String) -> void:
	if commit_hash.is_empty():
		return
	_set_busy(true)
	_set_status("Rebasing onto %s..." % PanelGraphUtils.short_hash(commit_hash), false)
	git_manager.rebase_ref(commit_hash)


# --- Phase 3 row-menu actions (branch/tag) ---

func _on_menu_create_branch(commit_hash: String) -> void:
	if git_manager == null or String(commit_hash).is_empty():
		return
	# "Create new branch" inside the switcher targets this commit; the
	# switcher itself sanitizes + validates the typed name and offers a
	# create-from-source mode, same as the side panel.
	_pending_target_hash = String(commit_hash)
	if branch_popup != null and is_instance_valid(branch_popup):
		branch_popup.show_switcher(_branches, _tags)


func _on_branch_popup_create(branch_name: String, source_ref: String) -> void:
	if git_manager == null:
		return
	var clean := SidepanelBranchUtils.sanitize_branch_name(branch_name)
	if clean.is_empty():
		return
	if not bool(GitRefs.validate_branch_name(clean).get("ok", false)):
		return
	# Empty source = the commit the row menu was opened on. Unlike the
	# side panel (create + checkout), the graph only creates the branch
	# here — yanking the worktree to an old commit on right-click would
	# be surprising.
	var source := String(source_ref).strip_edges()
	if source.is_empty():
		source = _pending_target_hash
	if source.is_empty():
		return
	_set_busy(true)
	_set_status("Creating branch '%s'..." % clean, false)
	git_manager.create_branch(clean, source)


func _on_branch_popup_checkout(ref: String, kind: String) -> void:
	if git_manager == null or String(ref).strip_edges().is_empty():
		return
	# Reuse the ref-chip flow: already-on-branch guard plus the confirm
	# dialog for tag (detached) and branch switches.
	_on_chip_activated({}, String(ref), "tag" if String(kind) == "tag" else "branch")


func _on_branch_popup_detach() -> void:
	if git_manager == null or _pending_target_hash.is_empty():
		return
	# Detach at the commit the row menu was opened on — same as the row
	# menu's "Checkout commit (detached)" entry.
	_on_menu_checkout(_pending_target_hash)


func _on_menu_create_tag(commit_hash: String) -> void:
	if git_manager == null or String(commit_hash).is_empty():
		return
	_pending_target_hash = String(commit_hash)
	_open_tag_dialog()


func _open_tag_dialog() -> void:
	if tag_dialog != null and is_instance_valid(tag_dialog):
		GraphDialogsScript.clear_inputs(tag_dialog)
		tag_dialog.popup_centered()


func _on_tag_dialog_confirmed() -> void:
	if git_manager == null or tag_dialog == null or _pending_target_hash.is_empty():
		return
	var ref_name := GraphDialogsScript.line_text(tag_dialog, "DialogInput")
	if ref_name.is_empty():
		return
	var annotated := GraphDialogsScript.checked(tag_dialog, "DialogCheck")
	var note := GraphDialogsScript.line_text(tag_dialog, "DialogMessage")
	_set_busy(true)
	_set_status("Creating tag '%s'..." % ref_name, false)
	git_manager.create_tag(ref_name, _pending_target_hash, annotated, note)


func _on_menu_branch_rename(old_name: String) -> void:
	if git_manager == null or String(old_name).is_empty():
		return
	_pending_branch_old = String(old_name)
	if rename_dialog != null and is_instance_valid(rename_dialog):
		GraphDialogsScript.clear_inputs(rename_dialog)
		rename_dialog.dialog_text = "Rename branch '%s' to:" % _pending_branch_old
		rename_dialog.popup_centered()


func _on_rename_dialog_confirmed() -> void:
	if git_manager == null or rename_dialog == null or _pending_branch_old.is_empty():
		return
	var new_name := GraphDialogsScript.line_text(rename_dialog, "DialogInput")
	if new_name.is_empty() or new_name == _pending_branch_old:
		return
	_set_busy(true)
	_set_status("Renaming branch '%s'..." % _pending_branch_old, false)
	git_manager.rename_branch(_pending_branch_old, new_name)


func _on_menu_branch_delete(branch_name: String) -> void:
	if git_manager == null or String(branch_name).is_empty():
		return
	# Safe delete (-d) refuses unmerged branches inside git; the confirm
	# here guards the ref removal itself (recoverable via reflog, but
	# annoying to lose).
	_ask_confirm("branch_delete", "Delete branch '%s'? Commits reachable only from it become harder to find." % branch_name, {"name": String(branch_name)})


func _do_branch_delete(branch_name: String) -> void:
	if branch_name.is_empty():
		return
	_set_busy(true)
	_set_status("Deleting branch '%s'..." % branch_name, false)
	git_manager.delete_branch(branch_name)


func _on_menu_branch_push(branch_name: String, remote: String) -> void:
	if git_manager == null:
		return
	if String(branch_name).is_empty() or String(remote).is_empty():
		return
	_set_busy(true)
	_set_status("Pushing '%s' to '%s'..." % [branch_name, remote], false)
	git_manager.push_ref(branch_name, remote)


func _do_tag_delete(tag_name: String) -> void:
	if tag_name.is_empty():
		return
	_set_busy(true)
	_set_status("Deleting tag '%s'..." % tag_name, false)
	git_manager.delete_tag(tag_name)


func _do_stash_drop(index: int) -> void:
	_set_busy(true)
	_set_status("Dropping %s..." % PanelGraphUtils.stash_ref(index), false)
	git_manager.stash_drop(index)


func _on_menu_copy_hash(commit_hash: String) -> void:
	DisplayServer.clipboard_set(String(commit_hash))
	_set_status("Copied commit hash.", false)


func _on_menu_copy_message(message: String) -> void:
	DisplayServer.clipboard_set(String(message))
	_set_status("Copied commit subject.", false)


func _on_open_file_requested(repo_path: String) -> void:
	# The file is opened at its worktree state (like the side panel): when
	# the selected commit is old, the content may differ from the diff.
	EditorUtils.open_file_in_editor(repo_path)


func _on_copy_path_requested(repo_path: String) -> void:
	DisplayServer.clipboard_set(String(repo_path))
	_set_status("Copied path: %s" % repo_path, false)


# Checkout/merge/reset rewrite files on disk, but open editor tabs keep
# stale in-memory text until a rescan. Shared helper (same as the side
# panel): reload the tabs AND rescan so the new content shows immediately.
func _reload_editor_after_disk_change() -> void:
	EditorUtils.reload_editor_after_disk_change()


# --- Phase 3 overflow (⋯) menu: pull/push, stash, tags, remotes ---

func _remote_names() -> Array:
	var names: Array = []
	for r in _remotes:
		var info: Dictionary = r
		var remote_name := String(info.get("name", ""))
		if not remote_name.is_empty() and not names.has(remote_name):
			names.append(remote_name)
	return names


func _current_branch_name() -> String:
	if git_manager == null or not git_manager.is_repo():
		return "-"
	return String(git_manager.get_branch())


# True when HEAD is not on a named branch: git reports "HEAD" for a detached
# one, the manager's UNBORN_BRANCH sentinel for a repo with no commits, and
# "" / "-" when the manager has no answer. One predicate, four call sites
# (overflow menus, push/fetch targets) - they must agree or the menus offer
# actions the others refuse.
func _is_detached_head(current: String) -> bool:
	return current.is_empty() or current == "-" or current == "HEAD" or current == GitManagerScript.UNBORN_BRANCH


# Label with a fallback and a hard width cap, so long reflog/PR subjects
# cannot blow out the overflow menu.
func _ellipsize(text: String, fallback: String, cap: int = 44) -> String:
	var label := String(text).strip_edges()
	if label.is_empty():
		label = String(fallback)
	if label.length() > cap:
		return label.left(cap) + "…"
	return label


func _on_overflow_pressed() -> void:
	if overflow_menu == null or not is_instance_valid(overflow_menu):
		return
	overflow_menu.position = DisplayServer.mouse_get_position()
	overflow_menu.popup()


# Rebuilt on every open from the refresh caches (cheap, synchronous — no
# git calls here). Dynamic submenu nodes are recreated each time; the
# previous set is freed first (safe: the menu is not visible yet).
func _on_overflow_about_to_popup() -> void:
	if overflow_menu == null:
		return
	overflow_menu.clear()
	for node in _overflow_nodes:
		if is_instance_valid(node):
			(node as Node).queue_free()
	_overflow_nodes = []
	_overflow_build += 1
	if git_manager == null or not git_manager.is_repo():
		overflow_menu.add_item("Not a Git repository.", -1)
		overflow_menu.set_item_disabled(0, true)
		return
	_add_overflow_push_pull()
	overflow_menu.add_separator()
	_add_overflow_stash_menu()
	_add_overflow_tags_menu()
	_add_overflow_remotes_menu()
	_add_overflow_reflog_menu()
	_add_overflow_pr_menu()
	overflow_menu.add_separator()
	overflow_menu.add_item("Export repository configuration...", OV_EXPORT_CONFIG)
	overflow_menu.add_item("Import repository configuration...", OV_IMPORT_CONFIG)


func _add_overflow_push_pull() -> void:
	overflow_menu.add_item("Pull", OV_PULL)
	var current := _current_branch_name()
	var detached := _is_detached_head(current)
	var remote_names := _remote_names()
	if detached:
		overflow_menu.add_item("Push (detached HEAD)", -1)
		overflow_menu.set_item_disabled(overflow_menu.item_count - 1, true)
	elif remote_names.is_empty():
		overflow_menu.add_item("Push (no git remote configured)", -1)
		overflow_menu.set_item_disabled(overflow_menu.item_count - 1, true)
	elif remote_names.size() == 1:
		overflow_menu.add_item("Push '%s' to '%s'" % [current, String(remote_names[0])], OV_PUSH_FIRST)
	else:
		var sub := _make_overflow_submenu("OverflowPushSubmenu")
		for ri in range(remote_names.size()):
			sub.add_item("Push '%s' to '%s'" % [current, String(remote_names[ri])], OV_PUSH_BASE + ri)
		overflow_menu.add_submenu_item("Push '%s'" % current, sub.name)


func _make_overflow_submenu(node_name: String, owner_menu: PopupMenu = null) -> PopupMenu:
	var sub := PopupMenu.new()
	# Build counter suffix: the previous build's nodes are queue_free'd but
	# still siblings until frame end, so fresh names must not collide with
	# theirs (submenu lookup is by name).
	sub.name = "%s#%d" % [node_name, _overflow_build]
	sub.id_pressed.connect(_on_overflow_id)
	# A submenu item resolves its target by name among the children of the
	# menu that owns the item, so nested (per-entry) submenus must live
	# under their intermediate menu — never as siblings under the root.
	if owner_menu == null:
		owner_menu = overflow_menu
	owner_menu.add_child(sub)
	_overflow_nodes.append(sub)
	return sub


func _stash_label(info: Dictionary) -> String:
	var idx := int(info.get("index", 0))
	var message := _ellipsize(String(info.get("message", "")), String(info.get("raw", "")))
	return "%s: %s" % [PanelGraphUtils.stash_ref(idx), message]


func _add_overflow_stash_menu() -> void:
	overflow_menu.add_item("Stash changes...", OV_STASH_PUSH)
	var sub := _make_overflow_submenu("OverflowStashesSubmenu")
	if _stashes.is_empty():
		sub.add_item("No stashes", -1)
		sub.set_item_disabled(0, true)
	var shown := 0
	for s in _stashes:
		if shown >= OV_LIST_CAP:
			break
		var info: Dictionary = s
		var idx := int(info.get("index", shown))
		var entry := _make_overflow_submenu("OverflowStash%dSubmenu" % idx, sub)
		entry.add_item("Apply (keep stash)", OV_STASH_APPLY_BASE + idx)
		entry.add_item("Pop (apply + drop)", OV_STASH_POP_BASE + idx)
		entry.add_item("Drop...", OV_STASH_DROP_BASE + idx)
		sub.add_submenu_item(_stash_label(info), entry.name)
		shown += 1
	if _stashes.size() > shown:
		sub.add_item("(+%d more)" % (_stashes.size() - shown), -1)
		sub.set_item_disabled(sub.item_count - 1, true)
	overflow_menu.add_submenu_item("Stashes (%d)" % _stashes.size(), sub.name)


func _add_overflow_tags_menu() -> void:
	var sub := _make_overflow_submenu("OverflowTagsSubmenu")
	sub.add_item("Create tag at selected commit...", OV_TAG_CREATE)
	if _details_hash.is_empty():
		sub.set_item_disabled(0, true)
	if not _tags.is_empty():
		sub.add_separator()
	var remote_names := _remote_names()
	var shown := 0
	for t in _tags:
		if shown >= OV_LIST_CAP:
			break
		var info: Dictionary = t
		var tag_name := String(info.get("name", ""))
		if tag_name.is_empty():
			continue
		var entry := _make_overflow_submenu("OverflowTag%dSubmenu" % shown, sub)
		entry.add_item("Checkout '%s'" % tag_name, OV_TAG_CHECKOUT_BASE + shown)
		entry.add_item("Delete '%s'..." % tag_name, OV_TAG_DELETE_BASE + shown)
		for ri in range(mini(remote_names.size(), OV_MAX_TAG_PUSH_REMOTES)):
			entry.add_item("Push to '%s'" % String(remote_names[ri]), OV_TAG_PUSH_BASE + shown * OV_TAG_PUSH_STRIDE + ri)
		sub.add_submenu_item(tag_name, entry.name)
		shown += 1
	if _tags.is_empty():
		sub.add_item("No tags", -1)
		sub.set_item_disabled(sub.item_count - 1, true)
	elif _tags.size() > shown:
		sub.add_item("(+%d more)" % (_tags.size() - shown), -1)
		sub.set_item_disabled(sub.item_count - 1, true)
	overflow_menu.add_submenu_item("Tags (%d)" % _tags.size(), sub.name)


func _add_overflow_remotes_menu() -> void:
	var sub := _make_overflow_submenu("OverflowRemotesSubmenu")
	if _remotes.is_empty():
		sub.add_item("No git remotes configured", -1)
		sub.set_item_disabled(0, true)
	var current := _current_branch_name()
	var detached := _is_detached_head(current)
	var shown := 0
	for r in _remotes:
		if shown >= OV_LIST_CAP:
			break
		var info: Dictionary = r
		var remote_name := String(info.get("name", ""))
		if remote_name.is_empty():
			continue
		sub.add_item("Fetch from '%s'" % remote_name, OV_REMOTE_FETCH_BASE + shown)
		sub.add_item("Fetch (prune) from '%s'" % remote_name, OV_REMOTE_PRUNE_BASE + shown)
		sub.add_item("Fetch '%s' from '%s'" % [current if not detached else "current branch", remote_name], OV_REMOTE_FETCH_REF_BASE + shown)
		if detached:
			sub.set_item_disabled(sub.item_count - 1, true)
		shown += 1
	overflow_menu.add_submenu_item("Remotes (%d)" % _remotes.size(), sub.name)


# Reflog recovery menu (plan section I get_reflog): recent HEAD movements
# with per-entry checkout (detached) + copy-hash. Caps display like the
# stash/tag submenus; indices route to _reflog_at bounds-checked.
func _reflog_label(info: Dictionary) -> String:
	var subject := _ellipsize(String(info.get("subject", "")), String(info.get("raw", "")))
	return "%s: %s" % [String(info.get("short", "")), subject]


func _reflog_at(index: int) -> Dictionary:
	if index < 0 or index >= _reflog.size():
		return {}
	return _reflog[index]


func _add_overflow_reflog_menu() -> void:
	var sub := _make_overflow_submenu("OverflowReflogSubmenu")
	if _reflog.is_empty():
		sub.add_item("No reflog entries", -1)
		sub.set_item_disabled(0, true)
	# Ids key off the _reflog position (not a display counter) so routing
	# via _reflog_at stays exact even if an entry is ever skipped.
	var total := mini(_reflog.size(), OV_LIST_CAP)
	for i in range(total):
		var info: Dictionary = _reflog[i]
		if String(info.get("hash", "")).is_empty():
			continue
		var entry := _make_overflow_submenu("OverflowReflog%dSubmenu" % i, sub)
		entry.add_item("Checkout (detached)", OV_REFLOG_CHECKOUT_BASE + i)
		entry.add_item("Copy hash", OV_REFLOG_COPY_BASE + i)
		sub.add_submenu_item(_reflog_label(info), entry.name)
	if _reflog.size() > total:
		sub.add_item("(+%d more)" % (_reflog.size() - total), -1)
		sub.set_item_disabled(sub.item_count - 1, true)
	overflow_menu.add_submenu_item("Reflog (%d)" % _reflog.size(), sub.name)


func _stash_info(index: int) -> Dictionary:
	for s in _stashes:
		var info: Dictionary = s
		if int(info.get("index", -1)) == index:
			return info
	return {}


func _tag_name_at(index: int) -> String:
	if index < 0 or index >= _tags.size():
		return ""
	return String((_tags[index] as Dictionary).get("name", ""))


func _remote_name_at(index: int) -> String:
	var remote_names := _remote_names()
	if index < 0 or index >= remote_names.size():
		return ""
	return String(remote_names[index])


func _on_overflow_id(id: int) -> void:
	if git_manager == null:
		return
	match id:
		OV_PULL:
			_do_pull()
		OV_PUSH_FIRST:
			_do_push_current(_remote_name_at(0))
		OV_STASH_PUSH:
			if stash_dialog != null and is_instance_valid(stash_dialog):
				GraphDialogsScript.clear_inputs(stash_dialog)
				stash_dialog.popup_centered()
		OV_TAG_CREATE:
			if not _details_hash.is_empty():
				_pending_target_hash = _details_hash
				_open_tag_dialog()
		OV_EXPORT_CONFIG:
			_do_export_config()
		OV_IMPORT_CONFIG:
			_do_import_config()
		OV_PR_OPEN:
			_do_pr_open_list()
		OV_PR_NEW:
			_do_pr_new()
		OV_PR_COPY:
			_do_pr_copy()
		OV_PR_REFRESH:
			_maybe_fetch_prs()
		_:
			if id >= OV_PUSH_BASE and id < OV_STASH_APPLY_BASE:
				_do_push_current(_remote_name_at(id - OV_PUSH_BASE))
			elif id >= OV_STASH_APPLY_BASE and id < OV_STASH_POP_BASE:
				_do_stash_apply(id - OV_STASH_APPLY_BASE)
			elif id >= OV_STASH_POP_BASE and id < OV_STASH_DROP_BASE:
				_do_stash_pop(id - OV_STASH_POP_BASE)
			elif id >= OV_STASH_DROP_BASE and id < OV_TAG_CHECKOUT_BASE:
				_do_stash_drop_ask(id - OV_STASH_DROP_BASE)
			elif id >= OV_TAG_CHECKOUT_BASE and id < OV_TAG_DELETE_BASE:
				_do_tag_checkout(_tag_name_at(id - OV_TAG_CHECKOUT_BASE))
			elif id >= OV_TAG_DELETE_BASE and id < OV_TAG_PUSH_BASE:
				_do_tag_delete_ask(_tag_name_at(id - OV_TAG_DELETE_BASE))
			elif id >= OV_TAG_PUSH_BASE and id < OV_REMOTE_FETCH_BASE:
				var slot := id - OV_TAG_PUSH_BASE
				_do_tag_push(_tag_name_at(slot / OV_TAG_PUSH_STRIDE), _remote_name_at(slot % OV_TAG_PUSH_STRIDE))
			elif id >= OV_REMOTE_FETCH_BASE and id < OV_REMOTE_PRUNE_BASE:
				_do_fetch_remote(_remote_name_at(id - OV_REMOTE_FETCH_BASE), false)
			elif id >= OV_PR_BASE and id < OV_PR_BASE + OV_PR_CAP:
				_do_pr_open_index(id - OV_PR_BASE)
			elif id >= OV_REMOTE_PRUNE_BASE and id < OV_PR_OPEN:
				_do_fetch_remote(_remote_name_at(id - OV_REMOTE_PRUNE_BASE), true)
			elif id >= OV_REFLOG_CHECKOUT_BASE and id < OV_REFLOG_COPY_BASE:
				_do_reflog_checkout(id - OV_REFLOG_CHECKOUT_BASE)
			elif id >= OV_REFLOG_COPY_BASE and id < OV_REMOTE_FETCH_REF_BASE:
				_do_reflog_copy(id - OV_REFLOG_COPY_BASE)
			elif id >= OV_REMOTE_FETCH_REF_BASE and id < OV_REMOTE_FETCH_REF_BASE + OV_LIST_CAP:
				_do_fetch_ref(_remote_name_at(id - OV_REMOTE_FETCH_REF_BASE))


func _do_pull() -> void:
	if not _guard_remote_op():
		return
	_set_busy(true)
	_set_status("Pulling...", false)
	git_manager.pull()


func _do_push_current(remote: String) -> void:
	if git_manager == null or remote.is_empty():
		return
	var current := _current_branch_name()
	if _is_detached_head(current):
		_set_status("Error: cannot push while HEAD is detached.", true)
		return
	_set_busy(true)
	_set_status("Pushing '%s' to '%s'..." % [current, remote], false)
	git_manager.push_ref(current, remote)


func _do_stash_apply(index: int) -> void:
	if _stash_info(index).is_empty():
		return
	_set_busy(true)
	_set_status("Applying %s..." % PanelGraphUtils.stash_ref(index), false)
	git_manager.stash_apply(index)


func _do_stash_pop(index: int) -> void:
	if _stash_info(index).is_empty():
		return
	_set_busy(true)
	_set_status("Popping %s..." % PanelGraphUtils.stash_ref(index), false)
	git_manager.stash_pop(index)


func _do_stash_drop_ask(index: int) -> void:
	if _stash_info(index).is_empty():
		return
	# Dropping discards the stashed changes permanently.
	_ask_confirm("stash_drop", "Drop %s? The stashed changes will be lost. This cannot be undone." % PanelGraphUtils.stash_ref(index), {"index": index})


func _do_tag_checkout(tag_name: String) -> void:
	if tag_name.is_empty():
		return
	_set_busy(true)
	_set_status("Checking out tag '%s'..." % tag_name, false)
	git_manager.checkout_ref(tag_name)


func _do_tag_delete_ask(tag_name: String) -> void:
	if tag_name.is_empty():
		return
	_ask_confirm("tag_delete", "Delete tag '%s'? This removes the local tag." % tag_name, {"name": tag_name})


func _do_tag_push(tag_name: String, remote: String) -> void:
	if tag_name.is_empty() or remote.is_empty():
		return
	_set_busy(true)
	_set_status("Pushing tag '%s' to '%s'..." % [tag_name, remote], false)
	git_manager.push_ref(tag_name, remote)


func _do_fetch_remote(remote: String, prune: bool) -> void:
	if remote.is_empty():
		return
	_set_busy(true)
	_set_status("Fetching from '%s'%s..." % [remote, " (prune)" if prune else ""], false)
	git_manager.fetch_remote(remote, prune)


func _do_fetch_ref(remote: String) -> void:
	if git_manager == null or String(remote).is_empty():
		return
	var current := _current_branch_name()
	if _is_detached_head(current):
		_set_status("Error: cannot fetch a branch while HEAD is detached.", true)
		return
	_set_busy(true)
	_set_status("Fetching '%s' from '%s'..." % [current, remote], false)
	git_manager.fetch_ref(remote, current)


func _do_reflog_checkout(index: int) -> void:
	var info := _reflog_at(index)
	if info.is_empty():
		return
	# Reuse the row-menu checkout path (busy + status + editor reload).
	_on_menu_checkout(String(info.get("hash", "")))


func _do_reflog_copy(index: int) -> void:
	var info := _reflog_at(index)
	if info.is_empty():
		return
	DisplayServer.clipboard_set(String(info.get("hash", "")))
	_set_status("Copied reflog hash.", false)


func _on_stash_dialog_confirmed() -> void:
	if git_manager == null or stash_dialog == null:
		return
	var note := GraphDialogsScript.line_text(stash_dialog, "DialogInput")
	_set_busy(true)
	_set_status("Stashing changes...", false)
	git_manager.stash_push(note)


func _is_phase3_mutation(action: String) -> bool:
	return action in [
		"graph_branch_create", "graph_branch_delete", "graph_branch_rename",
		"graph_tag_create", "graph_tag_delete",
		"graph_stash_push", "graph_stash_apply", "graph_stash_pop", "graph_stash_drop",
		"graph_push", "graph_fetch", "graph_fetch_ref",
	]


func _phase3_success_message(result: Dictionary) -> String:
	var action := String(result.get("action", ""))
	match action:
		"graph_branch_create":
			return "Created branch '%s'." % String(result.get("name", ""))
		"graph_branch_delete":
			return "Deleted branch '%s'." % String(result.get("name", ""))
		"graph_branch_rename":
			return "Renamed branch '%s' to '%s'." % [String(result.get("old", "")), String(result.get("new", ""))]
		"graph_tag_create":
			return "Created tag '%s'." % String(result.get("name", ""))
		"graph_tag_delete":
			return "Deleted tag '%s'." % String(result.get("name", ""))
		"graph_stash_push":
			return "Stashed changes."
		"graph_stash_apply":
			return "Applied %s." % String(result.get("ref", "stash"))
		"graph_stash_pop":
			return "Popped %s." % String(result.get("ref", "stash"))
		"graph_stash_drop":
			return "Dropped %s." % String(result.get("ref", "stash"))
		"graph_push":
			return "Pushed '%s' to '%s'." % [String(result.get("ref", "")), String(result.get("remote", ""))]
		"graph_fetch":
			return "Fetched from '%s'." % String(result.get("remote", ""))
		"graph_fetch_ref":
			return "Fetched '%s' from '%s'." % [String(result.get("ref", "")), String(result.get("remote", ""))]
	return "Done."


func _on_operation_complete(result: Dictionary) -> void:
	var action := String(result.get("action", ""))
	if action == "fetch":
		_set_busy(false)
		if result.has("error"):
			_set_status("Error: %s" % String(result.get("error", "Unknown error")), true)
		else:
			refresh()
		return
	if action == "pull":
		_set_busy(false)
		if result.has("error"):
			_set_status("Error: %s" % String(result.get("error", "Unknown error")), true)
		else:
			_set_status("Pulled successfully!", false)
			_reload_editor_after_disk_change()
			refresh()
		return
	# Commits through this panel's own manager (base GitManager.commit
	# inherited by GraphManager): a new HEAD exists, so reload the log
	# instead of waiting for a manual refresh.
	if action == "commit":
		_set_busy(false)
		if result.has("error"):
			_set_status("Error: %s" % String(result.get("error", "Unknown error")), true)
		else:
			refresh()
		return
	# Auxiliary list loads commit their pending caches only on success, so
	# a failed load never wipes a good list (see _on_tags_loaded etc.).
	if action == "graph_tags":
		if not result.has("error"):
			_tags = _pending_tags
		_pending_tags = []
		return
	if action == "graph_stashes":
		if not result.has("error"):
			_stashes = _pending_stashes
			# Stash hashes may have shifted: re-flag the loaded page so
			# stash nodes/tooltips follow, then rebuild the display list.
			if not _commits.is_empty():
				_apply_stash_flags()
				_renderer_commit_list()
		_pending_stashes = []
		return
	if action == "graph_remotes":
		if not result.has("error"):
			_remotes = _pending_remotes
			_resolve_pr_info()
			_maybe_fetch_prs()
		_pending_remotes = []
		return
	if action == "graph_reflog":
		if not result.has("error"):
			_reflog = _pending_reflog
		_pending_reflog = []
		return
	# Dirtiness is advisory: a failed count keeps the previous row state
	# (the manager only emits on success) and never flashes an error.
	if action == "graph_uncommitted":
		return
	# Stash-hash resolution is advisory too: the dedicated signal applies
	# results, and a failure just leaves stash nodes menu-only.
	if action == "graph_stash_hashes":
		_stash_resolve_pending = false
		return
	if _is_phase3_mutation(action):
		_set_busy(false)
		if result.has("error"):
			_set_status("Error: %s" % String(result.get("error", "Unknown error")), true)
			return
		_set_status(_phase3_success_message(result), false)
		# Stash push/apply/pop rewrite tracked files like checkout does.
		if action == "graph_stash_push" or action == "graph_stash_apply" or action == "graph_stash_pop":
			_reload_editor_after_disk_change()
		refresh()
		return
	# checkout_ref is the shared base implementation (emits "checkout" and
	# refreshes status, like every other consumer of the contract expects).
	if action == "checkout" or action == "graph_merge" or action == "graph_reset" or action == "graph_rebase" or action == "graph_cherry_pick":
		_set_busy(false)
		if result.has("error"):
			_set_status("Error: %s" % String(result.get("error", "Unknown error")), true)
			return
		var done_label := {"checkout": "Checked out", "graph_merge": "Merged", "graph_reset": "Reset", "graph_rebase": "Rebased onto", "graph_cherry_pick": "Cherry-picked"}
		var ref := String(result.get("ref", result.get("hash", "")))
		_set_status("%s %s." % [String(done_label.get(action, "Done")), ref], false)
		_reload_editor_after_disk_change()
		refresh()
		return
	if action == "graph_details":
		if result.has("error") and String(result.get("hash", "")) == _details_hash:
			_set_status("Error: %s" % String(result.get("error", "Unknown error")), true)
			if details != null and is_instance_valid(details):
				details.show_load_error("Failed to load commit details.")
		return
	if action == "graph_diff":
		if result.has("error") and String(result.get("hash", "")) == _details_hash and String(result.get("path", "")) == _diff_path:
			if details != null and is_instance_valid(details):
				details.diff_view.show_message("Failed to load diff: %s" % String(result.get("error", "Unknown error")))
		return
	if action == "graph_compare_files":
		if result.has("error") and String(result.get("a", "")) == _compare_a and String(result.get("b", "")) == _compare_b:
			if compare_view != null and is_instance_valid(compare_view):
				compare_view.show_files_error("Failed to load comparison: %s" % String(result.get("error", "Unknown error")))
		return
	if action == "graph_compare_diff":
		if result.has("error") and String(result.get("a", "")) == _compare_a and String(result.get("b", "")) == _compare_b and String(result.get("path", "")) == _compare_path:
			if compare_view != null and is_instance_valid(compare_view):
				compare_view.show_diff_message("Failed to load diff: %s" % String(result.get("error", "Unknown error")))
		return
	if not action.begins_with("graph_"):
		return
	# A successful log_loaded reports its own progress just before this.
	if result.has("error"):
		# A failed *pagination* page emits no log_loaded, so surface it or
		# "Load more" silently stops working. A failed background refresh
		# keeps the list it already has: stay quiet.
		if action == "graph_log" and not _loading_more and not _commits.is_empty():
			return
		_set_busy(false)
		_loading_more = false
		_set_status("Error: %s" % String(result.get("error", "Unknown error")), true)


# --- Phase 4: keyboard shortcuts (plan section V.20) ---
#
# Ctrl/Cmd+F focuses the toolbar search, Ctrl/Cmd+H scroll to HEAD,
# Ctrl/Cmd+R refresh, Ctrl/Cmd+S / Ctrl/Cmd+Shift+S stash navigation,
# Up/Down graph walk (only when the canvas owns focus, so editor fields
# keep their keys), Escape clears the search first, then the inline
# details, then the comparison.
func _unhandled_key_input(event: InputEvent) -> void:
	if not visible:
		return
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	var ctrl := key.ctrl_pressed or key.meta_pressed
	if ctrl and key.keycode == KEY_F:
		accept_event()
		_on_find_pressed()
		return
	if ctrl and key.keycode == KEY_H:
		accept_event()
		_try_scroll_to_head()
		return
	if ctrl and key.keycode == KEY_R:
		accept_event()
		refresh()
		return
	if ctrl and key.keycode == KEY_S:
		accept_event()
		_stash_nav_step(-1 if key.shift_pressed else 1)
		return
	if key.keycode == KEY_ESCAPE:
		if find_widget != null and is_instance_valid(find_widget) and not String(find_widget.get_query()).strip_edges().is_empty():
			accept_event()
			_clear_find_search()
		elif inline_detail != null and is_instance_valid(inline_detail) and inline_detail.visible:
			accept_event()
			_on_inline_detail_closed()
		elif not _compare_a.is_empty() and compare_view != null and is_instance_valid(compare_view):
			accept_event()
			compare_view.close_view()
		return
	if key.keycode == KEY_UP or key.keycode == KEY_DOWN:
		if renderer != null and is_instance_valid(renderer) and renderer.has_focus() and not (renderer.commits as Array).is_empty():
			var rows: Array = renderer.commits
			var cur: int = renderer.selected
			var nxt := -1
			if ctrl:
				# Upstream branch-aware walk (web/graph.ts
				# getFirst/AlternativeParent/ChildIndex): Ctrl+Up opens the
				# child on the same branch, Ctrl+Down the parent; Shift
				# follows the alternative branch at merges.
				var use_alt := key.shift_pressed
				if key.keycode == KEY_UP:
					nxt = PanelGraphUtils.alternative_child_index(rows, cur) if use_alt else PanelGraphUtils.first_child_index(rows, cur)
				else:
					nxt = PanelGraphUtils.alternative_parent_index(rows, cur) if use_alt else PanelGraphUtils.first_parent_index(rows, cur)
			else:
				var step := -1 if key.keycode == KEY_UP else 1
				nxt = clampi(cur + step, 0, rows.size() - 1)
			if nxt >= 0 and nxt < rows.size() and nxt != cur:
				accept_event()
				_on_commit_selected(renderer.select_index(nxt))
		return


# --- Phase 4: toolbar find search (plan sections III.H, V.16) ---
#
# Filters the already-loaded page locally via GraphUtils (instant, no git
# round-trip). Typing highlights + scrolls to the first hit without moving
# the selection (no details churn); Enter / Shift+Enter (or the prev/next
# buttons) step through the matches — highlight, count, scroll, and row
# selection follow, but the commit is never opened (click a row for details).
# The search is always visible in the toolbar, so there is no toggle or
# close — Ctrl+F focuses the field and Escape clears the query.

func _on_find_pressed() -> void:
	if find_widget == null or not is_instance_valid(find_widget):
		return
	if git_manager == null or not git_manager.is_repo():
		_check_git()
		return
	find_widget.open_widget()


func _clear_find_search() -> void:
	_find_hits = []
	_find_pos = -1
	_find_query = ""
	if renderer != null and is_instance_valid(renderer):
		renderer.clear_search()
	if find_widget != null and is_instance_valid(find_widget):
		find_widget.clear()


func _on_find_search_changed(query: String, scope: String) -> void:
	_find_query = String(query)
	_find_scope = String(scope).to_lower()
	_rerun_find()


func _rerun_find() -> void:
	_find_hits = []
	_find_pos = -1
	if renderer == null or not is_instance_valid(renderer):
		return
	if _find_query.strip_edges().is_empty() or find_widget == null or not is_instance_valid(find_widget):
		renderer.clear_search()
		if find_widget != null and is_instance_valid(find_widget):
			find_widget.set_result_count(0, 0)
		return
	# Search the renderer's DISPLAY list, not _commits: the display list
	# prepends the uncommitted row and filters stashes, so _commits indices
	# are off by one (or worse) whenever either applies. Every consumer of
	# _find_hits (renderer highlight, select_index, row_y) is display-space.
	_find_hits = PanelGraphUtils.filter_commit_indices(renderer.commits, _find_query, _find_scope)
	if _find_hits.is_empty():
		renderer.set_search_hits([], -1)
		find_widget.set_result_count(0, 0)
		return
	_find_pos = 0
	renderer.set_search_hits(_find_hits, int(_find_hits[0]))
	find_widget.set_result_count(1, _find_hits.size())
	_scroll_to_index(int(_find_hits[0]))


func _on_find_next() -> void:
	_jump_find(1)


func _on_find_prev() -> void:
	_jump_find(-1)


func _jump_find(dir: int) -> void:
	if _find_hits.is_empty() or renderer == null or not is_instance_valid(renderer):
		return
	_find_pos = posmod(_find_pos + dir, _find_hits.size())
	var idx := int(_find_hits[_find_pos])
	renderer.set_search_hits(_find_hits, idx)
	if find_widget != null and is_instance_valid(find_widget):
		find_widget.set_result_count(_find_pos + 1, _find_hits.size())
	_scroll_to_index(idx)
	# Move the row selection so Up/Down continues from the match, but do
	# not open the commit: no details load, no inline panel expand.
	renderer.select_index(idx)


func _scroll_to_index(idx: int) -> void:
	if renderer == null or not is_instance_valid(renderer):
		return
	if not is_instance_valid(scroll) or renderer.commits.is_empty():
		return
	# Bound against the display list (same space as idx), not _commits.
	if idx < 0 or idx >= renderer.commits.size():
		return
	await get_tree().process_frame
	if not is_instance_valid(scroll) or not is_instance_valid(renderer):
		return
	var view_h := maxf(scroll.size.y - 8.0, renderer.ROW_H * 3.0)
	scroll.scroll_vertical = maxi(0, int(renderer.row_y(idx) - view_h * 0.5 + renderer.ROW_H * 0.5))


# --- Phase 4: commit comparison (plan sections III.C, V.17) ---
#
# Ctrl+click a second row pairs it with the selection. The pair is ordered
# older-first so `git diff A B` reads forward in time; the view lists
# changed files and renders the per-file diff through the shared widget.

func _on_compare_requested(first: Dictionary, second: Dictionary) -> void:
	if git_manager == null:
		return
	if bool(first.get("uncommitted", false)) or bool(second.get("uncommitted", false)):
		_set_status("Cannot compare uncommitted changes here — commit first, then pick two commits.", false)
		if renderer != null and is_instance_valid(renderer):
			renderer.clear_compare()
		return
	var ha := String(first.get("hash", ""))
	var hb := String(second.get("hash", ""))
	if ha.is_empty() or hb.is_empty() or ha == hb:
		return
	var ia: int = -1
	var ib: int = -1
	if renderer != null and is_instance_valid(renderer):
		ia = renderer.index_of_hash(ha)
		ib = renderer.index_of_hash(hb)
	# Smaller index = newer (topo order, newest first): A must be older.
	if ia != -1 and ib != -1 and ia < ib:
		_open_compare(hb, ha)
	else:
		_open_compare(ha, hb)


func _short_for_hash(hash_value: String) -> String:
	for c in _commits:
		if String((c as Dictionary).get("hash", "")) == hash_value:
			return PanelGraphUtils.commit_short(c as Dictionary)
	return PanelGraphUtils.short_hash(hash_value)


func _open_compare(hash_a: String, hash_b: String) -> void:
	if git_manager == null or compare_view == null or not is_instance_valid(compare_view):
		return
	_compare_a = String(hash_a)
	_compare_b = String(hash_b)
	_compare_path = ""
	compare_view.show_comparison(_compare_a, _compare_b, _short_for_hash(_compare_a), _short_for_hash(_compare_b))
	_apply_compare_visibility()
	# Plan section I merge-base: best common ancestor in the subtitle. The
	# worker answers in merge_base_ready and fills the subtitle then (it used
	# to run synchronously here, on the main thread).
	compare_view.set_merge_base("")
	if git_manager.has_method("get_merge_base"):
		git_manager.get_merge_base(_compare_a, _compare_b)
	_set_status("Comparing %s ↔ %s..." % [_short_for_hash(_compare_a), _short_for_hash(_compare_b)], false)
	git_manager.get_comparison_files(_compare_a, _compare_b)


# Merge base arrives asynchronously; ignore it once the comparison moved on.
func _on_merge_base_ready(rev_a: String, rev_b: String, base: String) -> void:
	if rev_a != _compare_a or rev_b != _compare_b:
		return
	if compare_view == null or not is_instance_valid(compare_view):
		return
	compare_view.set_merge_base(_short_for_hash(base) if not base.is_empty() else "")


func _apply_compare_visibility() -> void:
	var repo: bool = scroll != null and is_instance_valid(scroll) and bool(scroll.visible)
	var open := not _compare_a.is_empty() and not _compare_b.is_empty()
	if compare_sep != null and is_instance_valid(compare_sep):
		compare_sep.visible = repo and open
	if compare_view != null and is_instance_valid(compare_view):
		compare_view.visible = repo and open


func _close_compare_silent() -> void:
	_compare_a = ""
	_compare_b = ""
	_compare_path = ""
	if compare_view != null and is_instance_valid(compare_view):
		compare_view.clear()
		compare_view.visible = false
	if compare_sep != null and is_instance_valid(compare_sep):
		compare_sep.visible = false
	if renderer != null and is_instance_valid(renderer):
		renderer.clear_compare()


func _on_compare_closed() -> void:
	_compare_a = ""
	_compare_b = ""
	_compare_path = ""
	_apply_compare_visibility()
	if renderer != null and is_instance_valid(renderer):
		renderer.clear_compare()
	_set_status("Comparison closed.", false)


func _on_compare_swap() -> void:
	if _compare_a.is_empty() or _compare_b.is_empty():
		return
	_open_compare(_compare_b, _compare_a)


func _on_comparison_files_loaded(result: Dictionary) -> void:
	if compare_view == null or not is_instance_valid(compare_view):
		return
	if String(result.get("a", "")) != _compare_a or String(result.get("b", "")) != _compare_b:
		return
	compare_view.show_files(result.get("files", []))
	_set_status(
		"Comparing %s ↔ %s (%d files)." % [_short_for_hash(_compare_a), _short_for_hash(_compare_b), (result.get("files", []) as Array).size()],
		false
	)


func _on_compare_file_selected(path: String) -> void:
	if git_manager == null or _compare_a.is_empty() or _compare_b.is_empty():
		return
	_compare_path = String(path)
	git_manager.get_comparison_diff(_compare_a, _compare_b, _compare_path)


func _on_comparison_diff_loaded(result: Dictionary) -> void:
	if compare_view == null or not is_instance_valid(compare_view):
		return
	if String(result.get("a", "")) != _compare_a or String(result.get("b", "")) != _compare_b:
		return
	if String(result.get("path", "")) != _compare_path:
		return
	compare_view.set_diff(String(result.get("diff", "")), bool(result.get("truncated", false)))


# --- Phase 4: code review status (plan section V.18) ---

func _on_review_toggled(_commit_hash: String, path: String, reviewed: bool) -> void:
	_set_status(("Marked reviewed: " if reviewed else "Unmarked for review: ") + path, false)


# --- Phase 4: settings (plan section V.19) ---

# Settings dialog is rebuilt from its scene on every open so it always
# reflects live settings (replaces make_settings_dialog).
func _make_settings_dialog() -> void:
	if settings_dialog != null and is_instance_valid(settings_dialog):
		settings_dialog.queue_free()
	settings_dialog = SettingsDialogScene.instantiate()
	settings_dialog.name = "GraphSettingsDialog"
	settings_dialog.confirmed.connect(_on_settings_dialog_confirmed)
	add_child(settings_dialog)
	settings_dialog.setup(_settings)


func _on_settings_pressed() -> void:
	# Rebuilt on every open so the dialog always reflects live settings.
	_make_settings_dialog()
	settings_dialog.popup_centered()


func _on_settings_dialog_confirmed() -> void:
	if settings_dialog == null or not is_instance_valid(settings_dialog):
		return
	_settings = SettingsDialogScript.read_settings(settings_dialog)
	SettingsDialogScript.save_settings(_settings)
	_apply_settings()
	_set_status("Graph settings saved.", false)


func _apply_settings() -> void:
	if renderer != null and is_instance_valid(renderer):
		renderer.apply_settings(_settings)
	if inline_detail != null and is_instance_valid(inline_detail):
		inline_detail.apply_settings(_settings)
	_sync_glob_field()
	_rebuild_branch_filter()
	_rebuild_uncommitted_row()
	_renderer_commit_list()
	_rerun_find()
	_refresh_avatars()
	_resolve_pr_info()
	_maybe_fetch_prs()


# Column resize persistence: drag handles already applied the widths
# live; commit them so a restart keeps them.
func _on_lane_width_changed(width: float) -> void:
	_settings["lane_width"] = clampf(float(width), GraphRendererScript.LANE_W_MIN, GraphRendererScript.LANE_W_MAX)
	SettingsDialogScript.save_settings(_settings)


func _on_column_widths_changed(date_w: float, author_w: float, commit_w: float) -> void:
	_settings["date_col_w"] = maxf(float(date_w), 0.0)
	_settings["author_col_w"] = maxf(float(author_w), 0.0)
	_settings["commit_col_w"] = maxf(float(commit_w), 0.0)
	SettingsDialogScript.save_settings(_settings)


# --- Phase 5: pull-request provider integration (plan item 32) ---
#
# Browser-first: the overflow menu always offers the PR list page, the
# create-PR page, and a copy-link action derived locally from the remote
# URL (no network, works offline). When the host exposes a public REST
# endpoint (github/gitlab/bitbucket), the open-PR list is fetched in the
# background and offered as menu entries opening in the browser.

func _resolve_pr_info() -> void:
	_pr_info = {}
	if _remotes.is_empty():
		return
	var want := String(_settings.get("pr_remote", "origin")).strip_edges()
	var target := {}
	for r in _remotes:
		var info: Dictionary = r
		if String(info.get("name", "")) == want:
			target = info
			break
	if target.is_empty():
		target = _remotes[0]
	var url := String(target.get("fetch_url", String(target.get("push_url", ""))))
	if url.is_empty():
		return
	var parsed := PanelGraphUtils.parse_remote_url(url)
	if parsed.is_empty():
		return
	var override := String(_settings.get("pr_provider", "auto")).to_lower()
	if override != "" and override != "auto" and override != "none":
		parsed["provider"] = override
	_pr_info = parsed


func _pr_provider_active() -> String:
	if String(_settings.get("pr_provider", "auto")).to_lower() == "none":
		return "none"
	if _pr_info.is_empty():
		return ""
	return String(_pr_info.get("provider", ""))


func _maybe_fetch_prs() -> void:
	if pr_http == null or not is_instance_valid(pr_http):
		return
	if _pr_fetching:
		return
	if git_manager == null or not git_manager.is_repo():
		return
	_resolve_pr_info()
	var provider := _pr_provider_active()
	if provider.is_empty() or provider == "none" or provider == "generic":
		return
	var api := PanelGraphUtils.pr_api_url(_pr_info)
	if api.is_empty():
		return
	_pr_fetching = true
	if pr_http.request(api, PackedStringArray(["Accept: application/json", "User-Agent: gdit-graph"])) != OK:
		_pr_fetching = false


func _on_prs_fetched(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_pr_fetching = false
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200 or body == null or body.is_empty():
		return
	var provider := _pr_provider_active()
	if provider.is_empty() or provider == "none":
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	var entries: Array = []
	if parsed is Array:
		entries = parsed
	elif parsed is Dictionary and (parsed as Dictionary).get("values") is Array:
		entries = (parsed as Dictionary)["values"]
	var out: Array = []
	for e in entries:
		if out.size() >= OV_PR_CAP:
			break
		if not (e is Dictionary):
			continue
		var pr := PanelGraphUtils.parse_pr_entry(e, provider)
		if pr.is_empty() or String(pr.get("url", "")).is_empty():
			continue
		out.append(pr)
	_prs = out


func _pr_label(pr: Dictionary) -> String:
	var title := _ellipsize(String(pr.get("title", "")), "", 52)
	var num := int(pr.get("number", 0))
	var author := String(pr.get("author", ""))
	if num > 0 and not author.is_empty():
		return "#%d %s (%s)" % [num, title, author]
	if num > 0:
		return "#%d %s" % [num, title]
	return title


func _add_overflow_pr_menu() -> void:
	var sub := _make_overflow_submenu("OverflowPrSubmenu")
	var setting := String(_settings.get("pr_provider", "auto")).to_lower()
	if setting == "none":
		sub.add_item("Pull requests disabled in settings", -1)
		sub.set_item_disabled(0, true)
		overflow_menu.add_submenu_item("Pull requests", sub.name)
		return
	_resolve_pr_info()
	if _pr_info.is_empty():
		sub.add_item("No git remote to link PRs to", -1)
		sub.set_item_disabled(0, true)
		overflow_menu.add_submenu_item("Pull requests", sub.name)
		return
	sub.add_item("Open pull requests page", OV_PR_OPEN)
	sub.add_item("Create pull request...", OV_PR_NEW)
	sub.add_item("Copy PR page link", OV_PR_COPY)
	sub.add_item("Refresh open-PR list", OV_PR_REFRESH)
	var provider := _pr_provider_active()
	if provider == "generic" or provider.is_empty():
		sub.add_item("(open-PR list needs a github/gitlab/bitbucket remote)", -1)
		sub.set_item_disabled(sub.item_count - 1, true)
	elif _pr_fetching:
		sub.add_item("Loading open PRs...", -1)
		sub.set_item_disabled(sub.item_count - 1, true)
	elif _prs.is_empty():
		sub.add_item("No open PRs found", -1)
		sub.set_item_disabled(sub.item_count - 1, true)
	else:
		sub.add_separator()
		for i in range(_prs.size()):
			sub.add_item(_pr_label(_prs[i]), OV_PR_BASE + i)
	var count := " (%d)" % _prs.size() if not _prs.is_empty() else ""
	overflow_menu.add_submenu_item("Pull requests" + count, sub.name)


func _do_pr_open_list() -> void:
	_resolve_pr_info()
	var url := PanelGraphUtils.pr_list_url(_pr_info)
	if url.is_empty():
		_set_status("Error: no PR page for the configured remote.", true)
		return
	OS.shell_open(url)


func _do_pr_new() -> void:
	_resolve_pr_info()
	var url := PanelGraphUtils.pr_new_url(_pr_info, _current_branch_name())
	if url.is_empty():
		_set_status("Error: no PR page for the configured remote.", true)
		return
	OS.shell_open(url)


func _do_pr_copy() -> void:
	_resolve_pr_info()
	var url := PanelGraphUtils.pr_list_url(_pr_info)
	if url.is_empty():
		_set_status("Error: no PR page for the configured remote.", true)
		return
	DisplayServer.clipboard_set(url)
	_set_status("Copied PR page link.", false)


func _do_pr_open_index(idx: int) -> void:
	if idx < 0 or idx >= _prs.size():
		return
	var url := String((_prs[idx] as Dictionary).get("url", ""))
	if url.is_empty():
		return
	OS.shell_open(url)


# --- Phase 4: stash keyboard navigation (plan section V.20) ---
#
# Stashes are not graph rows, so Ctrl+S walks the cached stash list and
# loads each entry through the normal details flow (resolved to its commit
# hash first, so the details stale-guard keeps working).

func _stash_nav_step(dir: int) -> void:
	if git_manager == null or _stashes.is_empty():
		_set_status("No stashes.", false)
		return
	_stash_nav = posmod(_stash_nav + dir, _stashes.size())
	var info: Dictionary = _stashes[_stash_nav]
	var idx := int(info.get("index", _stash_nav))
	var ref := PanelGraphUtils.stash_ref(idx)
	# Resolved from the cached hash list (filled by the worker query); the
	# selector itself is a valid details rev when the hash is unknown.
	var resolved := String(_stash_hash_cache.get(String(info.get("raw", "")), ""))
	var fake := {
		"hash": resolved if not resolved.is_empty() else ref,
		"short": ref,
		"author": String(info.get("branch", "")),
		"date": "",
		"subject": String(info.get("message", String(info.get("raw", ref)))),
	}
	_on_commit_selected(fake)
	_set_status("Stash %d of %d: %s" % [_stash_nav + 1, _stashes.size(), ref], false)


# --- Phase 4: avatars (plan section V.22) ---

func _refresh_avatars() -> void:
	if renderer == null or not is_instance_valid(renderer):
		return
	var seen := {}
	for c in _commits:
		var email := String((c as Dictionary).get("email", "")).strip_edges().to_lower()
		if email.is_empty() or seen.has(email):
			continue
		seen[email] = true
		# Skip disk reads for emails whose texture is already live: the
		# renderer keeps avatar textures across set_commits, so reloading
		# every refresh re-decoded every PNG for no visible change.
		if renderer.avatar_textures.has(email):
			continue
		var tex: Texture2D = PanelAvatars.load_cached_texture(email)
		if tex != null:
			renderer.set_avatar_texture(email, tex)
	_maybe_fetch_avatars(seen.keys())


func _maybe_fetch_avatars(emails: Array) -> void:
	if not bool(_settings.get("fetch_avatars", false)):
		return
	if avatar_http == null or not is_instance_valid(avatar_http):
		return
	_avatar_queue = []
	for email in emails:
		var addr := String(email)
		if addr.is_empty():
			continue
		if PanelAvatars.load_cached_texture(addr) != null:
			continue
		_avatar_queue.append(addr)
		if _avatar_queue.size() >= 20:
			break
	_pump_avatar_queue()


func _pump_avatar_queue() -> void:
	if _avatar_fetching:
		return
	if _avatar_queue.is_empty():
		return
	if avatar_http == null or not is_instance_valid(avatar_http):
		_avatar_queue = []
		return
	var email := String(_avatar_queue[0])
	var url := PanelAvatars.gravatar_url(email)
	if url.is_empty():
		_avatar_queue.pop_front()
		_pump_avatar_queue()
		return
	_avatar_fetching = true
	if avatar_http.request(url) != OK:
		_avatar_fetching = false
		_avatar_queue.pop_front()
		_pump_avatar_queue()


func _on_avatar_fetched(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_avatar_fetching = false
	if not _avatar_queue.is_empty():
		var email := String(_avatar_queue.pop_front())
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200 and body != null and not body.is_empty():
			if PanelAvatars.save_cached_png(email, body):
				var tex: Texture2D = PanelAvatars.load_cached_texture(email)
				if tex != null and renderer != null and is_instance_valid(renderer):
					renderer.set_avatar_texture(email, tex)
	_pump_avatar_queue()


# --- Phase 4: config export/import (plan section V.24) ---

func _do_export_config() -> void:
	if git_manager == null:
		return
	var extra := {"branch_filter": _current_rev, "details_open": inline_detail != null and is_instance_valid(inline_detail) and inline_detail.visible}
	var res: Dictionary = ExportConfigScript.export_to_repo(_settings, extra, String(git_manager.get_repo_path()))
	if bool(res.get("ok", false)):
		_set_status("Exported graph config to %s" % String(res.get("path", "")), false)
	else:
		_set_status("Error: %s" % String(res.get("error", "export failed")), true)


func _do_import_config() -> void:
	if git_manager == null:
		return
	var res: Dictionary = ExportConfigScript.import_from_repo(String(git_manager.get_repo_path()))
	if not bool(res.get("ok", false)):
		_set_status("Error: %s" % String(res.get("error", "import failed")), true)
		return
	_settings = SettingsDialogScript.apply_settings(res.get("settings", {}))
	SettingsDialogScript.save_settings(_settings)
	_apply_settings()
	var extra: Dictionary = res.get("extra", {})
	if extra.has("branch_filter"):
		_current_rev = String(extra.get("branch_filter", ""))
		# The dropdown must follow the rev: _apply_settings() above already
		# rebuilt it (preserving the previous label), so without this the
		# filter reads "All branches" over a branch-scoped log, and the next
		# dropdown interaction silently discards the imported rev.
		_rebuild_branch_filter()
	if bool(extra.get("details_open", true)) and not _details_hash.is_empty() and not _inline_uncommitted:
		# Re-open the details panel for the commit it was exported with.
		git_manager.get_commit_details(_details_hash)
	elif not bool(extra.get("details_open", true)):
		_close_inline_detail()
	_set_status("Imported graph config.", false)
	refresh()
