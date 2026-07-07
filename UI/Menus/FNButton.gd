# FNButton.gd
# Botón estilo "battle-royale" (Fortnite-like) dibujado 100% por código:
# paralelogramo inclinado, relleno con gradiente vertical, franja de brillo
# (gloss) arriba, borde brillante y sombra proyectada. Reacciona a hover/press.
# No usa ningún asset externo — todo es draw_* nativo de Godot.
extends Button

const SKEW := 12.0        # inclinación horizontal (look angular)
const SHADOW := 5.0       # desplazamiento de la sombra

var _font: Font
var _fsize := 20
# Colores base del relleno (arriba claro -> abajo oscuro) y del borde/acento.
var _fill_top := Color(0.13, 0.55, 1.0)
var _fill_bot := Color(0.06, 0.28, 0.7)
var _edge := Color(0.55, 0.85, 1.0)
var _text_col := Color.WHITE

var _hover := false
var _down := false

func setup(font: Font, fsize: int, fill_top: Color, fill_bot: Color, edge: Color, text_col := Color.WHITE) -> void:
	_font = font
	_fsize = fsize
	_fill_top = fill_top
	_fill_bot = fill_bot
	_edge = edge
	_text_col = text_col
	queue_redraw()

func _ready() -> void:
	flat = true
	focus_mode = Control.FOCUS_NONE
	if _font == null:
		_font = get_theme_default_font()
	var empty := StyleBoxEmpty.new()
	for s in ["normal", "hover", "pressed", "focus", "hover_pressed", "disabled"]:
		add_theme_stylebox_override(s, empty)
	# El texto lo dibujamos nosotros: apagamos el que pinta el engine.
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color", "font_disabled_color"]:
		add_theme_color_override(c, Color(0, 0, 0, 0))
	mouse_entered.connect(func(): _hover = true; queue_redraw())
	mouse_exited.connect(func(): _hover = false; _down = false; queue_redraw())
	button_down.connect(func(): _down = true; queue_redraw())
	button_up.connect(func(): _down = false; queue_redraw())

func _shape(dx: float, dy: float) -> PackedVector2Array:
	var w := size.x
	var h := size.y
	return PackedVector2Array([
		Vector2(SKEW + dx, dy),
		Vector2(w + dx, dy),
		Vector2(w - SKEW + dx, h + dy),
		Vector2(dx, h + dy),
	])

func _draw() -> void:
	var w := size.x
	var h := size.y
	var lift := 0.0
	var boost := 0.0
	if _hover:
		boost = 0.16
	if _down:
		boost = -0.08
		lift = 2.0

	# Sombra proyectada (paralelogramo oscuro desplazado hacia abajo).
	draw_colored_polygon(_shape(2.0, SHADOW + lift), Color(0, 0, 0, 0.45))

	# Relleno con gradiente vertical (2 triángulos, colores por vértice).
	var top := _fill_top.lightened(boost) if boost > 0 else _fill_top.darkened(-boost)
	var bot := _fill_bot.lightened(boost) if boost > 0 else _fill_bot.darkened(-boost)
	var pts := _shape(0, lift)
	draw_polygon(pts, PackedColorArray([top, top, bot, bot]))

	# Gloss: banda clara semitransparente en la mitad superior.
	var gloss_h := h * 0.5
	var gloss := PackedVector2Array([
		Vector2(SKEW, lift),
		Vector2(w, lift),
		Vector2(w - SKEW * (1.0 - gloss_h / h), gloss_h + lift),
		Vector2(SKEW * (gloss_h / h), gloss_h + lift),
	])
	draw_colored_polygon(gloss, Color(1, 1, 1, 0.12))

	# Borde brillante (más intenso en hover).
	var edge := _edge if not _hover else _edge.lightened(0.25)
	var border := pts.duplicate()
	border.append(pts[0])
	draw_polyline(border, edge, 2.5, true)

	# Texto centrado, dibujado a mano sobre todo lo demás.
	var tcol := _text_col
	if not disabled and _hover:
		tcol = Color.WHITE
	var asc := _font.get_ascent(_fsize)
	var th := _font.get_height(_fsize)
	var y := (h - th) * 0.5 + asc + lift
	draw_string(_font, Vector2(0, y), text, HORIZONTAL_ALIGNMENT_CENTER, w, _fsize, tcol)
