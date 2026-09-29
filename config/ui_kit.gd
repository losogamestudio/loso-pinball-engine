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


## Remove and free every child now (so a rebuilt list never shows old + new
## rows together for a frame).
static func free_children(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()
