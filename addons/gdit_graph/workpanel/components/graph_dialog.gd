# Shared behavior for graph input dialogs (branch/rename/tag/stash).
#
# Replaces the graph_dialogs.gd static factories: each dialog's layout now
# lives in its own .tscn (DialogBox/DialogInput/DialogCheck/DialogMessage
# names preserved, so the line_text/checked/clear_inputs readers keep
# working unchanged). This script wires the live validation (OK stays
# disabled until the name validates via GitRefs) and the tag dialog's
# annotated-toggle → message-field coupling.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/workpanel/components/graph_dialog.gd").
@tool
extends ConfirmationDialog

const GitRefs = preload("res://addons/gdit_graph/git_refs.gd")

# Stash messages are free-form: stash_dialog.tscn sets this false.
@export var validate_name = true

var _input = null


func _ready() -> void:
	_input = get_node_or_null("DialogBox/DialogInput")
	var check = get_node_or_null("DialogBox/DialogCheck")
	var message = get_node_or_null("DialogBox/DialogMessage")
	if check != null and message != null:
		check.toggled.connect(func(pressed: bool) -> void:
			message.editable = pressed
		)
	if validate_name and _input != null:
		_gate_ok()


func _is_ok() -> bool:
	if _input == null:
		return true
	return GitRefs.is_valid_ref_name(_input.text)


# OK is enabled only while the current inputs are submittable. The OK
# button is resolved lazily (AcceptDialog buttons are only guaranteed once
# the dialog is in the tree): _ready sets the initial state, and
# text_changed + about_to_popup refresh it.
func _gate_ok() -> void:
	var refresh := func() -> void:
		var ok := get_ok_button()
		if ok != null:
			ok.disabled = not _is_ok()
	refresh.call()
	_input.text_changed.connect(func(_new_text: String) -> void:
		refresh.call()
	)
	about_to_popup.connect(func() -> void:
		refresh.call()
	)
