# GitOperations contract (DIP Phase 3).
#
# GDScript has no interfaces, so the panels depend on this documented
# duck-typed contract instead of the concrete GitManager class: any manager
# exposing the required methods and signals works (base GitManager for the
# side panel, GraphManager — which extends GitManager — for the graph tab,
# or a fake in tests). Use is_compatible() / missing_methods() to validate
# an injected manager; use create_default_manager() for the panels'
# fallback path so they never instantiate the concrete class themselves.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/git_operations.gd").
extends RefCounted


# Signals both panels rely on. Static (not const): PackedStringArray()
# construction is not a constant expression in GDScript.
static var REQUIRED_SIGNALS := PackedStringArray(["status_changed", "operation_complete"])

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
	"rev_parse",
	"merge_base",
])


static func missing_methods(candidate: Variant, required: PackedStringArray) -> PackedStringArray:
	if not (candidate is Object):
		return required.duplicate()
	var missing := PackedStringArray()
	for method_name in required:
		if not (candidate as Object).has_method(String(method_name)):
			missing.append(String(method_name))
	return missing


static func missing_signals(candidate: Variant) -> PackedStringArray:
	if not (candidate is Object):
		return REQUIRED_SIGNALS.duplicate()
	var missing := PackedStringArray()
	for signal_name in REQUIRED_SIGNALS:
		if not (candidate as Object).has_signal(String(signal_name)):
			missing.append(String(signal_name))
	return missing


static func is_compatible(candidate: Variant, required: PackedStringArray) -> bool:
	return missing_methods(candidate, required).is_empty() and missing_signals(candidate).is_empty()


# Fallback factory for the side panel: a base manager with the default
# OS-backed executor. Keeps the concrete GitManager reference in this one
# composition helper instead of in the panel.
static func create_default_manager(repo_path: String):
	var manager_script := load("res://addons/gdit_graph/git_manager.gd") as Script
	var executor_script := load("res://addons/gdit_graph/git_executor.gd") as Script
	var manager = manager_script.new()
	manager.set_repo_path(String(repo_path))
	manager.set_executor(executor_script.new())
	return manager
