class_name UiKit
## Tiny helpers for the service/setup screens, which build their widgets in
## code. Static, so call them as UiKit.button("Save", _on_save).

const LAMP_OFF := Color(0.05, 0.05, 0.06)   # darker than the gray cards, so an unlit lamp still shows
const LAMP_ON := Color(1.0, 0.75, 0.1)
const OK_COLOR := Color.PALE_GREEN
const WARN_COLOR := Color.KHAKI
const BAD_COLOR := Color.SALMON

## Colors shared with the game screens: cyan for titles and main actions,
## purple for test actions (they make hardware move), salmon for destructive ones.
const ACCENT_COLOR := Color(0.0, 1.0, 1.0)
const TEST_COLOR := Color(0.75, 0.6, 1.0)
const DANGER_COLOR := Color.SALMON

## Button roles for button(): the text color says what kind of action it is.
const PLAIN := ""
const PRIMARY := "primary"   ## the main way forward: Add, Save, Next, Burn
const TEST := "test"         ## fires something on the board: Fire once, Send to board
const DANGER := "danger"     ## throws something away: Delete, Reset, Quit

## Background grays (darkest to lightest): page < section card < row card < button.
const SECTION_BG := Color(0.13, 0.13, 0.16)
const ROW_BG := Color(0.18, 0.18, 0.22)
const BUTTON_BG := Color(0.26, 0.27, 0.32)
const BUTTON_HOVER_BG := Color(0.33, 0.34, 0.40)
const BUTTON_PRESSED_BG := Color(0.10, 0.35, 0.40)
const FIELD_BG := Color(0.08, 0.08, 0.10)

## Base sizes (before the Text size setting) for the smaller kinds of text.
const NOTE_SIZE := 12      ## explanations
const DETAIL_SIZE := 11    ## the second line of a coil/switch row


static func button(text: String, on_press: Callable, role := PLAIN) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(on_press)
	var color: Variant = {PRIMARY: ACCENT_COLOR, TEST: TEST_COLOR, DANGER: DANGER_COLOR}.get(role)
	if color != null:
		for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(state, color)
	return b


static func heading(text: String, size := 20) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", DisplaySettings.font_size(size))   # grows with Text size
	l.add_theme_color_override("font_color", ACCENT_COLOR)
	return l


## A section of a service page: a darker gray card with a cyan heading and
## optional buttons next to it. Adds itself to [param parent] and returns the
## box to put the section's rows in.
static func section(parent: Node, title_text: String, head_buttons: Array[Control] = []) -> VBoxContainer:
	var card := PanelContainer.new()
	card.theme_type_variation = &"SectionPanel"
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(card)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	card.add_child(body)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	head.add_child(heading(title_text))
	for b in head_buttons:
		head.add_child(b)
	body.add_child(head)
	return body


## One item in a section (a coil, a switch, a board): a lighter gray card.
## Returns the card's row to fill; add it with parent.add_child(row.get_parent()).
static func row_card(parent: Node) -> HBoxContainer:
	var card := PanelContainer.new()
	card.theme_type_variation = &"RowPanel"
	parent.add_child(card)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	card.add_child(row)
	return row


## A name on top and small detail text under it, taking the free width of a row.
static func name_block(name_text: String, detail_text: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_label := Label.new()
	name_label.text = name_text
	box.add_child(name_label)
	if detail_text != "":
		box.add_child(detail(detail_text))
	return box


## Small, dim, wrapping text for the details of an item.
static func detail(text: String) -> Label:
	var l := _wrapping_label(text)
	l.add_theme_font_size_override("font_size", DisplaySettings.font_size(DETAIL_SIZE))
	l.modulate = Color(1, 1, 1, 0.65)
	return l


## Fill [param theme] with the service screens' look: gray button and field
## backgrounds and the section/row card styles. Called once by
## DisplaySettings.text_theme(), so every screen using that theme gets it.
static func style_theme(theme: Theme) -> void:
	# Buttons. OptionButton and CheckBox fall back to these (theme lookup walks
	# the class chain: OptionButton -> Button), so dropdowns match.
	theme.set_stylebox("normal", "Button", _box(BUTTON_BG))
	theme.set_stylebox("hover", "Button", _box(BUTTON_HOVER_BG))
	theme.set_stylebox("pressed", "Button", _box(BUTTON_PRESSED_BG))
	theme.set_stylebox("hover_pressed", "Button", _box(BUTTON_PRESSED_BG))
	theme.set_stylebox("disabled", "Button", _box(SECTION_BG))
	theme.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	theme.set_color("font_disabled_color", "Button", Color(1, 1, 1, 0.3))
	# Text fields (LineEdit, and the one inside every SpinBox) and the log.
	var field := _box(FIELD_BG, 4, 10, 6)
	field.border_color = Color(0.35, 0.36, 0.42)
	field.set_border_width_all(1)
	theme.set_stylebox("normal", "LineEdit", field)
	theme.set_stylebox("normal", "TextEdit", field)
	theme.set_stylebox("normal", "RichTextLabel", field)
	# Tabs (Setup / Diagnostics): gray tabs, the open one lighter with cyan text.
	theme.set_stylebox("tab_unselected", "TabContainer", _box(SECTION_BG, 6, 18, 6))
	theme.set_stylebox("tab_hovered", "TabContainer", _box(BUTTON_HOVER_BG, 6, 18, 6))
	theme.set_stylebox("tab_selected", "TabContainer", _box(BUTTON_BG, 6, 18, 6))
	theme.set_stylebox("tab_focus", "TabContainer", StyleBoxEmpty.new())
	theme.set_stylebox("panel", "TabContainer", StyleBoxEmpty.new())
	theme.set_color("font_selected_color", "TabContainer", ACCENT_COLOR)
	theme.set_color("font_unselected_color", "TabContainer", Color(1, 1, 1, 0.7))
	theme.set_constant("side_margin", "TabContainer", 0)
	# Cards.
	theme.set_type_variation(&"SectionPanel", &"PanelContainer")
	theme.set_stylebox("panel", &"SectionPanel", _box(SECTION_BG, 8, 14, 10))
	theme.set_type_variation(&"RowPanel", &"PanelContainer")
	theme.set_stylebox("panel", &"RowPanel", _box(ROW_BG, 6, 10, 6))


static func _box(color: Color, radius := 6, margin_x := 14, margin_y := 6) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.content_margin_left = margin_x
	s.content_margin_right = margin_x
	s.content_margin_top = margin_y
	s.content_margin_bottom = margin_y
	return s


## A big page title that wraps onto more lines instead of pushing the page
## wider than the screen (big text on a small screen).
static func title(text: String, size := 24) -> Label:
	var l := heading(text, size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size.x = 160
	return l


## A smaller, dimmer, wrapping paragraph for explanations.
static func note(text: String) -> Label:
	var l := _wrapping_label(text)
	l.add_theme_font_size_override("font_size", DisplaySettings.font_size(NOTE_SIZE))
	l.modulate = Color(1, 1, 1, 0.7)
	return l


static func colored(text: String, color: Color) -> Label:
	var l := _wrapping_label(text)
	l.add_theme_color_override("font_color", color)
	return l


## A label that wraps long text onto more lines. Gotcha: a wrapping label
## asks for (almost) zero width, so in an HBoxContainer it gets squeezed to one
## letter per line unless it's told to expand, which is why EXPAND_FILL is set
## here. The min width keeps it readable even when the row is crowded.
static func _wrapping_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size.x = 160
	return l


## A small square that shows on/off, for live switch state.
static func lamp(on := false, size := 20.0) -> ColorRect:
	var r := ColorRect.new()
	r.custom_minimum_size = Vector2(size, size)
	r.color = LAMP_ON if on else LAMP_OFF
	return r


static func spin(min_value: float, max_value: float, value: float, suffix: String, on_change: Callable) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_value
	s.max_value = max_value
	s.value = value
	s.suffix = suffix
	s.custom_minimum_size.x = 140
	s.value_changed.connect(on_change)
	return s


## "Label: [control]" on one row.
static func field(label_text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size.x = 200
	row.add_child(l)
	row.add_child(control)
	return row


## How much wider than Godot's default the vertical scroll bar is, so it's
## easy to grab with a finger on a touch screen.
const SCROLLBAR_WIDTH_SCALE := 3.0


## A vertical scroll area for service screens: the bar is always shown (so
## it's obvious there's more below) and extra wide for touch. No sideways
## scrolling: rows wrap instead.
static func scroll_container() -> ScrollContainer:
	var s := ScrollContainer.new()
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	s.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	# The bar's normal width comes from the theme, which only applies once it's
	# in the scene tree, so widen it on `ready`.
	s.ready.connect(_widen_scrollbar.bind(s))
	return s


## Widen the bar through its "scroll" (track) style, not custom_minimum_size:
## the ScrollContainer only makes room for the style's width, so a bigger
## custom size would just overlap the content. The grabber styles get the same
## padding so the thumb you drag is wide too.
static func _widen_scrollbar(s: ScrollContainer) -> void:
	var bar := s.get_v_scroll_bar()
	var extra := bar.get_minimum_size().x * (SCROLLBAR_WIDTH_SCALE - 1.0)
	for style_name: String in ["scroll", "scroll_focus", "grabber", "grabber_highlight", "grabber_pressed"]:
		var style := bar.get_theme_stylebox(style_name).duplicate() as StyleBox
		style.content_margin_left = maxf(style.content_margin_left, 0.0) + extra / 2.0
		style.content_margin_right = maxf(style.content_margin_right, 0.0) + extra / 2.0
		bar.add_theme_stylebox_override(style_name, style)
	s.queue_sort()   # lay the content out again around the wider bar


## Remove and free every child now (so a rebuilt list never shows old + new
## rows together for a frame).
static func free_children(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()
