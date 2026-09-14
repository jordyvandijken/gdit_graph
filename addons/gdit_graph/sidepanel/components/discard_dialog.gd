# Discard-changes confirmation dialog for the sidepanel.
#
# A plain ConfirmationDialog whose text the panel rewrites per target
# (tracked vs untracked, single vs many) before popup. The panel connects
# `confirmed` itself; this script only documents the component contract.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/sidepanel/components/discard_dialog.gd").
@tool
extends ConfirmationDialog


func setup(dialog_text_value: String) -> void:
	dialog_text = dialog_text_value
