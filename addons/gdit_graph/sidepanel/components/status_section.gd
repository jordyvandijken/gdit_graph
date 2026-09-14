# Bottom status area for the sidepanel: status/error row + branch row.
#
# Replaces the hand-built StatusLabel and StatusBar HBoxContainer (branch
# label opens the branch switcher popup). Both rows always stay visible —
# they report "Not a Git repository" / "Git not found" states too — so the
# panel never repo-gates this section. The panel keeps all behavior (status
# colors, branch clicks, checkout flows) via the exposed node refs.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/sidepanel/components/status_section.gd").
@tool
extends VBoxContainer

var status_label = null
var branch_label = null


func _ready() -> void:
	status_label = get_node_or_null("StatusLabel")
	branch_label = get_node_or_null("StatusBar/BranchLabel")
