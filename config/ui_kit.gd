class_name UiKit
## Tiny helpers for the service/setup screens, which build their widgets in
## code. Static, so call them as UiKit.button("Save", _on_save).

const LAMP_OFF := Color(0.18, 0.18, 0.2)
const LAMP_ON := Color(1.0, 0.75, 0.1)
const OK_COLOR := Color.PALE_GREEN
const WARN_COLOR := Color.KHAKI
const BAD_COLOR := Color.SALMON


static func button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(on_press)
	return b


static func heading(text: String, size := 20) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", DisplaySettings.font_size(size))   # grows with Text size
	return l


## A big page title that wraps onto more lines instead of pushing the page
## wider than the screen (big text on a small screen).
static func title(text: String, size := 24) -> Label:
	var l := heading(text, size)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size.x = 160
	return l


## A dimmer, wrapping paragraph for explanations.
static func note(text: String) -> Label:
	var l := _wrapping_label(text)
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
