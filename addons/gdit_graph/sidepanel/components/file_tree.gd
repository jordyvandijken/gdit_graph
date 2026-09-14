# Three-column file tree for the sidepanel (staged + unstaged lists).
#
# Replaces the `_make_file_tree()` factory. Columns mirror the sidepanel
# mock (design/Sidepanel.png; rows in design/sidepanel/staged.md and
# design/sidepanel/changes.md): file name (+ icon), muted directory, narrow
# right-aligned status letter. Column expand/width calls cannot be expressed
# in .tscn, so they live here in _ready(); static flags live in file_tree.tscn.
#
# Hover pills stay owned by the panel (overlay draw callback is panel logic),
# so this component only configures the tree itself.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/sidepanel/components/file_tree.gd").
@tool
extends Tree


func _ready() -> void:
	_apply_columns()


func _apply_columns() -> void:
	columns = 3
	column_titles_visible = false
	hide_root = true
	select_mode = Tree.SELECT_MULTI
	set_column_expand(0, true)
	set_column_expand(1, true)
	set_column_expand(2, false)
	set_column_custom_minimum_width(2, 28)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(0, 120)
