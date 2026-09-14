# Gray empty-state label for the sidepanel sections.
#
# Replaces the two hand-built Labels (staged_empty_label, changes_empty_label).
# Static style lives in empty_state_label.tscn; callers set text/visibility.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/sidepanel/components/empty_state_label.gd").
@tool
extends Label


func setup(label_text: String) -> void:
	text = label_text
