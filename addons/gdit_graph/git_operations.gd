# GitOperations contract (DIP Phase 3).
#
# GDScript has no interfaces, so the panels depend on this documented
# duck-typed contract instead of the concrete GitManager class: any manager
# exposing the required methods and signals works (base GitManager for the
# side panel, GraphManager — which extends GitManager — for the graph tab,
# or a fake in tests). Validate an injected manager with is_compatible()
# (methods AND signals) and use create_default_manager() for the panels'
# fallback path so they never instantiate the concrete class themselves.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/git_operations.gd").
extends RefCounted


# Signals every manager must expose. Static (not const): PackedStringArray()
# construction is not a constant expression in GDScript.
static var BASE_SIGNALS := PackedStringArray([
	"status_changed",
	"operation_complete",
	# The cached repo/branch/remote snapshot; both panels re-run their
	# environment gate on it instead of polling synchronously.
	"env_changed",
])

# Extra signals the Git Graph tab needs (GraphManager provides them).
static var GRAPH_SIGNALS := PackedStringArray([
	"log_loaded",
	"branches_loaded",
	"head_loaded",
	"tags_loaded",
	"stashes_loaded",
	"stash_hashes_loaded",
	"remotes_loaded",
	"reflog_loaded",
	"uncommitted_loaded",
	"commit_details_loaded",
	"commit_diff_loaded",
	"comparison_files_loaded",
	"comparison_diff_loaded",
	"merge_base_ready",
])

# Methods the Source Control side panel calls.
static var SIDE_PANEL_METHODS := PackedStringArray([
	"set_repo_path",
	"get_repo_path",
	"shutdown",
	"is_repo",
	"is_git_available",
	"get_branch",
	"has_remote",
	"refresh_status",
	"init_repo",
	"pull",
	"fetch",
	"push",
	"push_upstream",
	"list_remotes",
	"add_remote",
	"set_remote_url",
	"remove_remote",
	"check_host_cli",
	"create_host_repo",
	"stage_files",
	"unstage_files",
	"revert_changes",
	"discard_untracked",
	"commit",
	"list_branches",
	"list_tags",
	"checkout_ref",
	"checkout_remote",
	"checkout_detached",
	"create_and_checkout_branch",
])

# Methods the Git Graph tab calls (shared core plus graph queries).
static var GRAPH_METHODS := PackedStringArray([
	"set_repo_path",
	"get_repo_path",
	"shutdown",
	"is_repo",
	"is_git_available",
	"get_branch",
	"has_remote",
	"pull",
	"fetch",
	"get_log",
	"get_branches",
	"get_head",
	"get_tags",
	"get_stashes",
	"get_remotes",
	"get_reflog",
	"get_uncommitted_count",
	"get_commit_details",
	"get_commit_diff",
	"checkout_ref",
	"merge_ref",
	"reset_ref",
	"rebase_ref",
	"cherry_pick",
	"create_branch",
	"delete_branch",
	"rename_branch",
	"stash_push",
	"stash_apply",
	"stash_pop",
	"stash_drop",
	"create_tag",
	"delete_tag",
	"push_ref",
	"fetch_remote",
	"fetch_ref",
	"get_comparison_files",
	"get_comparison_diff",
	"get_stash_hashes",
	"get_merge_base",
])


static func missing_methods(candidate: Variant, required: PackedStringArray) -> PackedStringArray:
	if not (candidate is Object):
		return required.duplicate()
	var missing := PackedStringArray()
	for method_name in required:
		if not (candidate as Object).has_method(String(method_name)):
			missing.append(String(method_name))
	return missing


static func missing_signals(candidate: Variant, required: PackedStringArray) -> PackedStringArray:
	if not (candidate is Object):
		return required.duplicate()
	var missing := PackedStringArray()
	for signal_name in required:
		if not (candidate as Object).has_signal(String(signal_name)):
			missing.append(String(signal_name))
	return missing


# Full contract check: methods AND signals. A manager that passes the method
# check but is missing signals still hard-errors at the first
# `manager.some_signal.connect(...)`, so callers must gate on this, not on
# missing_methods() alone.
static func is_compatible(candidate: Variant, required: PackedStringArray, required_signals: PackedStringArray) -> bool:
	return missing_methods(candidate, required).is_empty() and missing_signals(candidate, required_signals).is_empty()


# Fallback factory for the side panel: a base manager with the default
# OS-backed executor. Keeps the concrete GitManager reference in this one
# composition helper instead of in the panel (the plugin injects a shared
# worker into both of its managers).
#
# No explicit worker: set_repo_path() triggers the first env refresh, which
# makes the manager lazily create its OWN worker (_owns_worker = true), so
# shutdown() stops its thread. Handing one over via set_worker() would mark
# it injected (_owns_worker = false) and orphan the thread on shutdown.
static func create_default_manager(repo_path: String):
	var manager_script := load("res://addons/gdit_graph/git_manager.gd") as Script
	var executor_script := load("res://addons/gdit_graph/git_executor.gd") as Script
	# One executor for both roles: the (lazily created) worker runs commands
	# through it, the manager uses it for the memoized `git --version` probe.
	var executor = executor_script.new()
	var manager = manager_script.new()
	manager.set_executor(executor)
	manager.set_repo_path(String(repo_path))
	return manager


# Fallback factory for the Git Graph tab: same shape as
# create_default_manager but with the GraphManager subclass (extends
# GitManager), so the standalone graph panel gets the same owned-worker
# lifecycle instead of relying on ad-hoc construction in the panel.
static func create_default_graph_manager(repo_path: String):
	var manager_script := load("res://addons/gdit_graph/workpanel/graph_manager.gd") as Script
	var executor_script := load("res://addons/gdit_graph/git_executor.gd") as Script
	var executor = executor_script.new()
	var manager = manager_script.new()
	manager.set_executor(executor)
	manager.set_repo_path(String(repo_path))
	return manager
