extends VBoxContainer
## DraftEditor — the shared shell for one-page editors on the Hardware tab
## (LED chain, light). Each editor extends this file and fills in the
## "virtual" functions below; the shell does the rest:
##
##   title, a scrolling gray card for the fields, an error line,
##   Cancel / Send to board to test / Save,
##   and draft handling: the edit goes into MachineConfig only when you test
##   it or save it, and Cancel (or leaving the menu) puts everything back.
##
## Like a parent Blueprint class in Unreal: the children override a few
## functions instead of copying this code. Usage, same as the other editors:
##     var e := ChainEditorScript.new(); e.open(&"led_chain_0"); add_child(e)
## Listen to `closed`.

signal closed(saved: bool)   ## the editor is done; the parent should free it

var _snapshot: Dictionary
var _original_name: StringName = &""   ## &"" = adding a new item
var _applied := false
var _finished := false

var _body: VBoxContainer
var _error_label: Label
var _save_button: Button
var _status_label: Label


# ---------------------------------------------------------------- for the editors to override

## The page title.
func _title() -> String:
	return ""


## Add the editor's rows to _body. Called again whenever the page is rebuilt.
func _build_fields() -> void:
	pass


## What's wrong with the draft in plain words, or "" if it can be saved.
func _draft_error() -> String:
	return ""


## Put the draft into MachineConfig. Called right after the layout is restored
## to how it was when the editor opened, so it can just add or replace.
func _put_draft() -> void:
	pass


## The board this item is on, for the "connected?" status line.
func _draft_board() -> StringName:
	return &""


# ---------------------------------------------------------------- shell

## Call before adding to the tree, after the editor's own open() has set up its draft.
func _begin(item_name: StringName) -> void:
	_snapshot = MachineConfig.snapshot()
	_original_name = item_name


func _ready() -> void:
	add_theme_constant_override("separation", 12)
	size_flags_vertical = SIZE_EXPAND_FILL
	add_child(UiKit.title(_title(), 24))

	# Scrolls, so bigger text on a small screen never pushes Save off the bottom.
	var scroll := UiKit.scroll_container()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(scroll)
	var card := PanelContainer.new()
	card.theme_type_variation = &"SectionPanel"
	card.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(card)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 12)
	_body.size_flags_horizontal = SIZE_EXPAND_FILL
	card.add_child(_body)

	_error_label = UiKit.colored("", UiKit.BAD_COLOR)
	add_child(_error_label)

	var footer := HBoxContainer.new()
	add_child(footer)
	footer.add_child(UiKit.button("Cancel", _cancel))
	var spacer := Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	footer.add_child(spacer)
	footer.add_child(UiKit.button("Send to board to test", _try_on_board, UiKit.TEST))
	_save_button = UiKit.button("Save", _save, UiKit.PRIMARY)
	footer.add_child(_save_button)

	PinballIO.board_ready.connect(_on_board_event)
	PinballIO.board_lost.connect(_on_board_event)
	_build()


func _exit_tree() -> void:
	if not _finished:
		_unapply()


func _build() -> void:
	UiKit.free_children(_body)
	_build_fields()
	_status_label = UiKit.colored("", UiKit.WARN_COLOR)
	_body.add_child(_status_label)
	_update_status()
	_refresh()


## Re-check the draft and enable Save if it's fine. Call after every edit.
func _refresh() -> void:
	var error := _draft_error()
	_error_label.text = error
	_save_button.disabled = error != ""


## The usual name rules. [param kind] is for the message, e.g. "light".
func _name_problem(item_name: StringName, kind: String) -> String:
	var text := String(item_name)
	if text.is_empty():
		return "Give the %s a name." % kind
	if text.contains(" "):
		return "Names can't contain spaces (use _ instead)."
	if MachineConfig.is_name_taken(item_name, _original_name):
		return "Something is already called '%s'." % text
	return ""


func _update_status() -> void:
	if _status_label == null:
		return
	var board := _draft_board()
	if PinballIO.get_port_for_board(board).is_empty():
		_status_label.text = "Board '%s' isn't connected, so this can't be tested right now. You can still save it." % board
		_status_label.add_theme_color_override("font_color", UiKit.WARN_COLOR)
	elif _applied:
		_status_label.text = "Board '%s' is running this draft now (nothing is saved yet)." % board
		_status_label.add_theme_color_override("font_color", UiKit.OK_COLOR)
	else:
		_status_label.text = "Press \"Send to board to test\" to try it on the board before saving."
		_status_label.add_theme_color_override("font_color", UiKit.WARN_COLOR)


## Put the draft into MachineConfig (from the layout as it was when opened).
## Returns problems; empty = applied and sent to the boards.
func _apply_draft() -> PackedStringArray:
	MachineConfig.restore(_snapshot, false)
	_put_draft()
	var problems := MachineConfig.validate()
	if problems.is_empty():
		MachineConfig.apply()
		_applied = true
	else:
		MachineConfig.restore(_snapshot, _applied)
		_applied = false
	return problems


func _try_on_board() -> void:
	if _draft_error() != "":
		return
	_error_label.text = "\n".join(_apply_draft())
	_update_status()


func _save() -> void:
	if _draft_error() != "":
		return
	var problems := _apply_draft()
	if not problems.is_empty():
		_error_label.text = "\n".join(problems)
		return
	var err := MachineConfig.save_config()
	if err != OK:
		_error_label.text = "Couldn't save the machine config (error %d)." % err
		return
	_finished = true
	closed.emit(true)


func _cancel() -> void:
	_unapply()
	_finished = true
	closed.emit(false)


func _unapply() -> void:
	if _applied:
		MachineConfig.restore(_snapshot)
		_applied = false


func _on_board_event(_board_id: StringName) -> void:
	_update_status()
