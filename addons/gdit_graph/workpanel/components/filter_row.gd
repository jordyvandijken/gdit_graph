# Branch filter row for the graph tab (branch dropdown + glob field).
#
# Replaces the hand-built GraphFilterRow: "Branch:" label, the branch
# OptionButton (filled by the panel via _rebuild_branch_filter), and the
# inline glob pattern field. The panel keeps all behavior (filter
# selection, glob syncing, repo gating) via the exposed node refs.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/components/filter_row.gd").
@tool
extends HBoxContainer

var branch_filter = null
var branch_glob_field = null


func _ready() -> void:
	branch_filter = get_node_or_null("GraphBranchFilter")
	branch_glob_field = get_node_or_null("GraphBranchGlob")
