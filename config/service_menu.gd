extends Control
## ServiceMenu — the service tabs, with touch-friendly Quit and Exit buttons
## in the top bar. Main opens it (Service button or P key) and closes it when
## `exit_requested` fires.
##
##   Monitor        LEDs for every input/output + the log (control.tscn, test_panel.gd)
##   Hardware       connection, boards, coils, switches, lamps (hardware_page.gd)
##   Audio & Video  screen settings, volumes, media library (av_page.gd)

signal exit_requested   ## the Exit button was pressed

var _quit_confirm: ConfirmationDialog


func _ready() -> void:
	theme = DisplaySettings.text_theme()   # the Text size setting, for everything in the menu
	$Tabs.set_tab_title(2, "Audio & Video")   # "&" doesn't belong in a node name
	$TopBar/ExitButton.pressed.connect(exit_requested.emit)
	var quit: Button = $TopBar/QuitButton
	quit.add_theme_color_override("font_color", UiKit.DANGER_COLOR)
	quit.add_theme_color_override("font_hover_color", UiKit.DANGER_COLOR)
	# On a touch screen with no keyboard, this is the only way out of fullscreen.
	_quit_confirm = ConfirmationDialog.new()
	_quit_confirm.dialog_text = "Quit Loso Pinball and go back to the desktop?"
	_quit_confirm.ok_button_text = "Quit"
	_quit_confirm.confirmed.connect(get_tree().quit)
	add_child(_quit_confirm)
	quit.pressed.connect(_quit_confirm.popup_centered)
