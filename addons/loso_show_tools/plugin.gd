@tool
extends EditorPlugin
## Loso Show Tools — adds the "Light Show" dock (show_dock.gd) to the editor:
## live LED preview of a light show while you play or scrub its timeline, and
## "Add cue at playhead". Our own plugin (not third party): enable it under
## Project > Project Settings > Plugins. See Docs/lighting.md.

const ShowDock := preload("res://addons/loso_show_tools/show_dock.gd")

var _dock: EditorDock
var _panel: ShowDock


func _enter_tree() -> void:
	_panel = ShowDock.new()
	_panel.undo_redo = get_undo_redo()
	var scroll := ScrollContainer.new()   # the dock can be short; let it scroll
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_panel)
	_dock = EditorDock.new()
	_dock.title = "Light Show"
	_dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_UL
	_dock.add_child(scroll)
	add_dock(_dock)
	scene_changed.connect(_panel.set_show)
	_panel.set_show(EditorInterface.get_edited_scene_root())


func _exit_tree() -> void:
	scene_changed.disconnect(_panel.set_show)
	remove_dock(_dock)
	_dock.queue_free()
