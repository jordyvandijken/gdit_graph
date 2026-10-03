# Remotes dialog for the sidepanel (push with no remote, ⋯ menu → Remotes…).
#
# Two modes over one form: show_add() hides the existing-remotes list for
# the first-run "publish" flow, show_manage() lists them with Remove/Save
# support. Host presets (GitHub/GitLab/Bitbucket) build the URL from the
# owner + repo fields; "Custom URL" leaves the URL field as the only
# input. Validation lives in remote_url_utils.gd; git calls stay in the
# panel — this component only owns layout and forwards intents.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/sidepanel/components/remote_dialog.gd").
@tool
extends PopupPanel

signal add_requested(name, url, push_after)
signal save_requested(name, url)
signal remove_requested(name)
signal new_repo_requested(host_id)
signal create_requested(is_private)
signal retry_requested

const RemoteUrls = preload("res://addons/gdit_graph/sidepanel/remote_url_utils.gd")

# Member fields are intentionally UNTYPED (AGENTS.md #242/#244/#245).
var _title = null
var _list_label = null
var _list = null
var _list_row = null
var _separator = null
var _name_field = null
var _host_picker = null
var _protocol_picker = null
var _owner_field = null
var _owner_label = null
var _repo_field = null
var _repo_label = null
var _url_field = null
var _error_label = null
var _new_repo_button = null
var _add_button = null
var _add_push_button = null
var _save_button = null
var _remove_button = null
var _create_label = null
var _visibility_row = null
var _visibility_picker = null
var _create_push_button = null
var _retry_push_button = null
var _name_row = null
var _host_row = null
var _owner_row = null
var _url_label = null
var _remotes = []
var _url_manual = false
var _can_push = false
# Create mode (push failed with "repository not found"): the form and list
# give way to a create-the-missing-repo flow for one parsed host.
var _create_mode = false
var _create_host = ""


func _ready() -> void:
	_title = get_node_or_null("RemoteBox/RemoteTitle")
	_list_label = get_node_or_null("RemoteBox/RemoteListLabel")
	_list = get_node_or_null("RemoteBox/RemoteList")
	_list_row = get_node_or_null("RemoteBox/RemoteListRow")
	_separator = get_node_or_null("RemoteBox/Separator")
	_name_field = get_node_or_null("RemoteBox/RemoteNameRow/RemoteName")
	_host_picker = get_node_or_null("RemoteBox/RemoteHostRow/RemoteHost")
	_protocol_picker = get_node_or_null("RemoteBox/RemoteHostRow/RemoteProtocol")
	_owner_field = get_node_or_null("RemoteBox/RemoteOwnerRow/RemoteOwner")
	_owner_label = get_node_or_null("RemoteBox/RemoteOwnerRow/RemoteOwnerLabel")
	_repo_field = get_node_or_null("RemoteBox/RemoteOwnerRow/RemoteRepo")
	_repo_label = get_node_or_null("RemoteBox/RemoteOwnerRow/RemoteRepoLabel")
	_url_field = get_node_or_null("RemoteBox/RemoteUrl")
	_error_label = get_node_or_null("RemoteBox/RemoteError")
	_new_repo_button = get_node_or_null("RemoteBox/RemoteButtons/RemoteNewRepoButton")
	_add_button = get_node_or_null("RemoteBox/RemoteButtons/RemoteAddButton")
	_add_push_button = get_node_or_null("RemoteBox/RemoteButtons/RemoteAddPushButton")
	_save_button = get_node_or_null("RemoteBox/RemoteButtons/RemoteSaveButton")
	_remove_button = get_node_or_null("RemoteBox/RemoteListRow/RemoteRemoveButton")
	_create_label = get_node_or_null("RemoteBox/RemoteCreateLabel")
	_visibility_row = get_node_or_null("RemoteBox/RemoteVisibilityRow")
	_visibility_picker = get_node_or_null("RemoteBox/RemoteVisibilityRow/RemoteVisibility")
	_create_push_button = get_node_or_null("RemoteBox/RemoteButtons/RemoteCreatePushButton")
	_retry_push_button = get_node_or_null("RemoteBox/RemoteButtons/RemoteRetryPushButton")
	_name_row = get_node_or_null("RemoteBox/RemoteNameRow")
	_host_row = get_node_or_null("RemoteBox/RemoteHostRow")
	_owner_row = get_node_or_null("RemoteBox/RemoteOwnerRow")
	_url_label = get_node_or_null("RemoteBox/RemoteUrlLabel")
	_fill_host_picker()
	_fill_protocol_picker()
	_fill_visibility_picker()
	if _host_picker != null:
		_host_picker.item_selected.connect(_on_preset_changed)
	if _protocol_picker != null:
		_protocol_picker.item_selected.connect(_on_preset_changed)
	if _owner_field != null:
		_owner_field.text_changed.connect(_on_preset_changed)
	if _repo_field != null:
		_repo_field.text_changed.connect(_on_preset_changed)
	if _url_field != null:
		_url_field.text_changed.connect(_on_url_edited)
	if _list != null:
		_list.item_selected.connect(_on_list_selected)
	if _add_button != null:
		_add_button.pressed.connect(_on_add_pressed.bind(false))
	if _add_push_button != null:
		_add_push_button.pressed.connect(_on_add_pressed.bind(true))
	if _save_button != null:
		_save_button.pressed.connect(_on_save_pressed)
	if _remove_button != null:
		_remove_button.pressed.connect(_on_remove_pressed)
	if _new_repo_button != null:
		_new_repo_button.pressed.connect(_on_new_repo_pressed)
	if _create_push_button != null:
		_create_push_button.pressed.connect(_on_create_pressed)
	if _retry_push_button != null:
		_retry_push_button.pressed.connect(_on_retry_pressed)
	var cancel_btn = get_node_or_null("RemoteBox/RemoteButtons/RemoteCancelButton")
	if cancel_btn != null:
		cancel_btn.pressed.connect(func() -> void: hide())
	_update_new_repo_button()


func _fill_host_picker() -> void:
	if _host_picker == null:
		return
	_host_picker.clear()
	for host_id in RemoteUrls.host_ids():
		_host_picker.add_item(RemoteUrls.host_display_name(host_id))
	_host_picker.select(0)


func _fill_protocol_picker() -> void:
	if _protocol_picker == null:
		return
	_protocol_picker.clear()
	_protocol_picker.add_item("HTTPS")
	_protocol_picker.add_item("SSH")
	_protocol_picker.select(0)


func _fill_visibility_picker() -> void:
	if _visibility_picker == null:
		return
	_visibility_picker.clear()
	_visibility_picker.add_item("Private")
	_visibility_picker.add_item("Public")
	_visibility_picker.select(0)


func _current_host_id() -> String:
	var ids := RemoteUrls.host_ids()
	var index := 0
	if _host_picker != null:
		index = _host_picker.selected
	if index < 0 or index >= ids.size():
		return "github"
	return ids[index]


func _current_protocol() -> String:
	if _protocol_picker != null and _protocol_picker.selected == 1:
		return "ssh"
	return "https"


# First-run flow: no list, just the form. can_push is false on a repo with
# no commits yet (there is nothing to push), so Add & Push is disabled.
func show_add(can_push: bool) -> void:
	_can_push = can_push
	_create_mode = false
	_set_list_visible(false)
	_set_form_visible(true)
	_set_create_visible(false)
	if _save_button != null:
		_save_button.visible = false
	if _add_button != null:
		_add_button.visible = true
	_set_add_push_visible(true)
	_reset_form()
	if _title != null:
		_title.text = "Add remote to publish"
	popup_centered()


# Full manager flow: list existing remotes above the same form.
func show_manage(remotes: Array, can_push: bool) -> void:
	_can_push = can_push
	_create_mode = false
	_set_list_visible(true)
	_set_form_visible(true)
	_set_create_visible(false)
	if _save_button != null:
		_save_button.visible = true
	if _add_button != null:
		_add_button.visible = true
	_set_add_push_visible(true)
	set_remotes(remotes)
	_reset_form()
	if _title != null:
		_title.text = "Git remotes"
	popup_centered()


# Recovery flow: the push failed because owner/repo does not exist on the
# host yet. info carries {remote, host, host_display, owner, repo}; cli
# carries {supported, available, authed} for the host's helper CLI. The
# one-click Create & Push button only appears when all three are true AND
# owner/repo are known — otherwise the browser + "Push again" path is
# the whole flow (Bitbucket, custom URLs, missing CLI, CLI logged out).
func show_create(info: Dictionary, cli: Dictionary) -> void:
	_create_mode = true
	_create_host = String(info.get("host", ""))
	_set_list_visible(false)
	_set_form_visible(false)
	if _save_button != null:
		_save_button.visible = false
	if _add_button != null:
		_add_button.visible = false
	_set_add_push_visible(false)
	var owner := String(info.get("owner", ""))
	var repo := String(info.get("repo", ""))
	var host_display := String(info.get("host_display", "the host"))
	if _create_label != null:
		if not owner.is_empty() and not repo.is_empty():
			_create_label.text = "Repository \"%s/%s\" doesn't exist on %s yet." % [owner, repo, host_display]
		else:
			_create_label.text = "The remote repository for \"%s\" was not found on %s. Create it there first, then push again." % [String(info.get("remote", "origin")), host_display]
	var can_create := bool(cli.get("supported", false)) and bool(cli.get("available", false)) and bool(cli.get("authed", false)) and not owner.is_empty() and not repo.is_empty()
	if _visibility_row != null:
		_visibility_row.visible = can_create
		if can_create and _visibility_picker != null:
			_visibility_picker.select(0)
	if _create_push_button != null:
		_create_push_button.visible = can_create
	if _retry_push_button != null:
		_retry_push_button.visible = true
	if _new_repo_button != null and not String(_create_host).is_empty():
		_new_repo_button.text = "Create on %s..." % host_display
		_new_repo_button.tooltip_text = "Open %s's new-repository page in a browser, then press Push again" % host_display
	_set_error("")
	if _title != null:
		_title.text = "Repository not found"
	popup_centered()


# Re-showable error line for the create flow (e.g. re-opened after a
# failed creation attempt with the raw CLI output attached).
func show_error(text: String) -> void:
	_set_error(text)


func set_remotes(remotes: Array) -> void:
	_remotes = remotes.duplicate()
	if _list == null:
		return
	_list.clear()
	for r in _remotes:
		var info: Dictionary = r
		var label := String(info.get("name", ""))
		var url := String(info.get("fetch_url", info.get("push_url", "")))
		if not url.is_empty():
			label += " — " + url
		_list.add_item(label)
	if _list_label != null:
		_list_label.text = "Existing remotes" if not _remotes.is_empty() else "Existing remotes (none yet)"


func _set_list_visible(visible: bool) -> void:
	for node in [_list_label, _list, _list_row, _separator]:
		if node != null and is_instance_valid(node):
			(node as Control).visible = visible


func _set_add_push_visible(visible: bool) -> void:
	if _add_push_button != null and is_instance_valid(_add_push_button):
		_add_push_button.visible = visible
		_add_push_button.disabled = not _can_push
		if not _can_push:
			_add_push_button.tooltip_text = "Nothing to push yet — commit first"
		else:
			_add_push_button.tooltip_text = "Add the remote and push the current branch, setting it as upstream"


func _reset_form() -> void:
	_url_manual = false
	if _name_field != null and String(_name_field.text).strip_edges().is_empty():
		_name_field.text = "origin"
	if _host_picker != null:
		_host_picker.select(0)
	if _protocol_picker != null:
		_protocol_picker.select(0)
	if _owner_field != null:
		_owner_field.text = ""
	if _repo_field != null:
		_repo_field.text = ""
	if _url_field != null:
		_url_field.text = ""
	_set_error("")
	_update_new_repo_button()
	_update_preset_fields_visible()
	_refresh_url_from_preset()


func _set_form_visible(visible: bool) -> void:
	for node in [_name_row, _host_row, _owner_row, _url_label, _url_field]:
		if node != null and is_instance_valid(node):
			(node as Control).visible = visible


func _set_create_visible(visible: bool) -> void:
	for node in [_create_label, _visibility_row, _create_push_button, _retry_push_button]:
		if node != null and is_instance_valid(node):
			(node as Control).visible = visible


func _set_error(text: String) -> void:
	if _error_label != null:
		_error_label.text = text


func _on_preset_changed(_unused: Variant) -> void:
	_url_manual = false
	_refresh_url_from_preset()
	_update_new_repo_button()
	_update_preset_fields_visible()


func _on_url_edited(_new_text: String) -> void:
	# The user typed a URL by hand: stop overwriting it until a preset
	# field (host/protocol/owner/repo) changes again.
	_url_manual = true


func _refresh_url_from_preset() -> void:
	if _url_manual or _url_field == null:
		return
	var host := _current_host_id()
	if host == "custom":
		return
	var owner := "" if _owner_field == null else String(_owner_field.text)
	var repo := "" if _repo_field == null else String(_repo_field.text)
	var built := RemoteUrls.build_url(host, _current_protocol(), owner, repo)
	if not built.is_empty():
		_url_field.text = built


func _update_preset_fields_visible() -> void:
	var custom := _current_host_id() == "custom"
	for node in [_owner_field, _owner_label, _repo_field, _repo_label]:
		if node != null and is_instance_valid(node):
			(node as Control).visible = not custom


func _update_new_repo_button() -> void:
	if _new_repo_button == null:
		return
	var host := _current_host_id()
	var page := RemoteUrls.new_repo_page(host)
	_new_repo_button.visible = not page.is_empty()
	# Restore the default caption: show_create() rewrites it for its host,
	# and the dialog instance is reused across modes.
	_new_repo_button.text = "New repo on…"
	_new_repo_button.tooltip_text = "Open %s's new-repository page in a browser, then paste the URL back here" % RemoteUrls.host_display_name(host)


func _read_validated() -> Dictionary:
	var name_check: Dictionary = RemoteUrls.validate_remote_name("" if _name_field == null else String(_name_field.text))
	if not bool(name_check.get("ok", false)):
		return {"ok": false, "error": String(name_check.get("error", ""))}
	var url_check: Dictionary = RemoteUrls.validate_remote_url("" if _url_field == null else String(_url_field.text))
	if not bool(url_check.get("ok", false)):
		return {"ok": false, "error": String(url_check.get("error", ""))}
	return {"ok": true, "name": String(name_check.get("clean", "")), "url": String(url_check.get("clean", "")), "error": ""}


func _on_add_pressed(push_after: bool) -> void:
	if push_after and not _can_push:
		return
	var checked := _read_validated()
	if not bool(checked.get("ok", false)):
		_set_error(String(checked.get("error", "")))
		return
	_set_error("")
	add_requested.emit(String(checked.get("name", "")), String(checked.get("url", "")), push_after)


func _on_save_pressed() -> void:
	var checked := _read_validated()
	if not bool(checked.get("ok", false)):
		_set_error(String(checked.get("error", "")))
		return
	_set_error("")
	save_requested.emit(String(checked.get("name", "")), String(checked.get("url", "")))


func _selected_remote_name() -> String:
	if _list == null or _remotes.is_empty():
		return ""
	var selected: PackedInt32Array = _list.get_selected_items()
	if selected.is_empty():
		return ""
	var index: int = selected[0]
	if index < 0 or index >= _remotes.size():
		return ""
	return String((_remotes[index] as Dictionary).get("name", ""))


func _on_remove_pressed() -> void:
	var target := _selected_remote_name()
	if target.is_empty():
		_set_error("Select a remote from the list to remove.")
		return
	_set_error("")
	remove_requested.emit(target)


func _on_list_selected(index: int) -> void:
	if index < 0 or index >= _remotes.size():
		return
	var info: Dictionary = _remotes[index]
	if _name_field != null:
		_name_field.text = String(info.get("name", ""))
	# Prefill the URL for editing; presets no longer apply, so mark it
	# manual and switch the picker to Custom URL.
	_url_manual = true
	var url := String(info.get("fetch_url", ""))
	if url.is_empty():
		url = String(info.get("push_url", ""))
	if _url_field != null:
		_url_field.text = url
	if _host_picker != null:
		_host_picker.select(RemoteUrls.host_ids().find("custom"))
	_update_new_repo_button()
	_update_preset_fields_visible()


func _on_new_repo_pressed() -> void:
	# In create mode the host is the parsed one from the failing remote,
	# not the (hidden) picker — the button text says so too.
	if _create_mode and not String(_create_host).is_empty():
		new_repo_requested.emit(String(_create_host))
		return
	new_repo_requested.emit(_current_host_id())


func _on_create_pressed() -> void:
	# Private is picker index 0 (see _fill_visibility_picker).
	var is_private := true
	if _visibility_picker != null:
		is_private = _visibility_picker.selected != 1
	_set_error("")
	create_requested.emit(is_private)


func _on_retry_pressed() -> void:
	_set_error("")
	retry_requested.emit()
