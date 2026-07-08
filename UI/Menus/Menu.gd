# Menu.gd
# Menú BÁSICO sobre el wallpaper del juego: elegís identidad (wallet o
# guest), tu personaje, y entrás a la partida comunitaria (una sola,
# infinita, poblada por el server). Ajustes en un botón chico.
extends Control

enum Screen { MAIN, SETTINGS, RESULTS }

const FONT_PATH := "res://UI/Share_Tech_Mono_Font/ShareTechMono-Regular.ttf"
const WALLPAPER := "res://UI/Menus/wallpaper.png"
const TWITTER_URL := "https://x.com/CZshooterbnb"
const FN_BUTTON := preload("res://UI/Menus/FNButton.gd")
# Server canónico del juego (la ÚNICA sala compartida). Se usa por defecto en
# web sin importar el dominio del sitio (czshooter.xyz, onrender, etc.).
const DEFAULT_SERVER := "arena-ffa-server.onrender.com"
# Paleta neón moderna.
const GOLD := Color(0.99, 0.78, 0.16)   # dorado neón (acento primario)
const NEON := Color(0.16, 0.88, 1.0)    # cyan neón (acento secundario)
const BLUE := Color(0.16, 0.88, 1.0)
const GLASS := Color(0.03, 0.04, 0.06, 0.9) # vidrio oscuro de los paneles

var _font: FontFile
var _screens := {}
var _current: int = Screen.MAIN

# Identidad + personaje.
var _char_ids: Array[String] = []
var _char_index := 0
var _name_edit: LineEdit
var _char_label: Label
var _wallet_btn: Button
var _server_edit: LineEdit
var _toast: Label

# Ajustes.
var _awaiting_rebind := ""
var _rebind_buttons := {}

# Resultados (solo se usa si alguna vez corre una sala por rondas).
var _results_box: VBoxContainer

func _ready() -> void:
	add_to_group("menu")
	_font = load(FONT_PATH)
	_char_ids = CharacterLib.get_ids()
	if not GameSettings.character_id.is_empty():
		var idx := _char_ids.find(GameSettings.character_id)
		if idx >= 0:
			_char_index = idx
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_build_background()
	_screens[Screen.MAIN] = _build_main()
	_screens[Screen.SETTINGS] = _build_settings()
	_screens[Screen.RESULTS] = _build_results()
	_build_toast()
	Net.session_closed.connect(func(reason): _show_toast(reason))
	if not Net.last_error.is_empty():
		_show_toast.call_deferred(Net.last_error)
		Net.last_error = ""
	if not Net.last_results.is_empty():
		goto(Screen.RESULTS)
	else:
		if Net.session_active():
			Net.leave()
		goto(Screen.MAIN)
	# Keepalive: mientras alguien tenga el menú abierto, pinguea el server
	# cada 4 min para que Render no lo duerma (así el PLAY conecta rápido).
	if OS.has_feature("web"):
		_ping_server()
		var t := Timer.new()
		t.wait_time = 240.0
		t.autostart = true
		t.timeout.connect(_ping_server)
		add_child(t)

func _ping_server() -> void:
	if not OS.has_feature("web"):
		return
	var addr := _server_edit.text.strip_edges() if _server_edit else GameSettings.last_server
	if addr.is_empty() or addr.begins_with("127.") or addr == "localhost":
		return
	JavaScriptBridge.eval("fetch('https://%s', {mode:'no-cors'}).catch(()=>{});" % addr, true)

func goto(screen: int) -> void:
	_current = screen
	for key in _screens:
		_screens[key].visible = (key == screen)
	if screen == Screen.RESULTS:
		_fill_results()

# HELPERS DE UI

func _label(size: int, color := Color.WHITE) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

## Stylebox de botón neón: vidrio oscuro + borde fino que brilla. En hover
## el borde y el glow se encienden.
func _neon_box(accent: Color, glow: float, border_w: int, bg_a: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.09, bg_a)
	sb.border_color = accent
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	sb.shadow_color = Color(accent.r, accent.g, accent.b, glow)
	sb.shadow_size = 10 if glow > 0.01 else 0
	sb.anti_aliasing = true
	return sb

## Botón secundario estilo battle-royale: paralelogramo navy con borde cyan.
func _button(text: String, size := 22) -> Button:
	var b: Button = FN_BUTTON.new()
	b.text = text
	b.custom_minimum_size = Vector2(340, 48)
	b.setup(_font, size,
		Color(0.17, 0.24, 0.38), Color(0.07, 0.10, 0.20),
		Color(0.32, 0.78, 1.0), Color(0.90, 0.96, 1.0))
	b.pressed.connect(func(): Sfx.play("ui", -6.0))
	return b

## Botón primario (PLAY): paralelogramo dorado brillante con texto oscuro.
func _gold_button(text: String, size := 24) -> Button:
	var b: Button = FN_BUTTON.new()
	b.text = text
	b.custom_minimum_size = Vector2(340, 60)
	b.setup(_font, size,
		Color(1.0, 0.86, 0.30), Color(0.86, 0.55, 0.05),
		Color(1.0, 0.97, 0.72), Color(0.16, 0.10, 0.0))
	b.pressed.connect(func(): Sfx.play("ui", -6.0))
	return b

func _panel_style(border := GOLD) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.06, 0.11, 0.93)
	sb.border_color = border
	sb.set_border_width_all(2)
	# Barra de acento gruesa arriba (firma del look battle-royale).
	sb.border_width_top = 6
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(28)
	sb.shadow_color = Color(border.r, border.g, border.b, 0.30)
	sb.shadow_size = 20
	sb.anti_aliasing = true
	return sb

## Panel de vidrio con borde neón (ya no usa marcos Kenney).
func _framed_panel(border := NEON) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_style(border))
	return p

## Aplica estilo neón a un LineEdit (campos de nombre / server).
func _style_edit(e: LineEdit) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.02, 0.03, 0.05, 0.7)
	box.border_color = Color(NEON.r, NEON.g, NEON.b, 0.35)
	box.set_border_width_all(1)
	box.set_corner_radius_all(6)
	box.set_content_margin_all(8)
	var focus := box.duplicate()
	focus.border_color = NEON
	focus.set_border_width_all(2)
	focus.shadow_color = Color(NEON.r, NEON.g, NEON.b, 0.3)
	focus.shadow_size = 8
	e.add_theme_stylebox_override("normal", box)
	e.add_theme_stylebox_override("focus", focus)
	e.add_theme_color_override("font_color", Color(0.9, 0.97, 1.0))
	e.add_theme_color_override("caret_color", NEON)

func _screen_root() -> Control:
	var c := Control.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.visible = false
	add_child(c)
	return c

func _build_background() -> void:
	# Wallpaper del juego (cover, recorta lo que sobre) + oscurecido abajo.
	var bg := TextureRect.new()
	bg.texture = load(WALLPAPER)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var grad := Gradient.new()
	grad.colors = PackedColorArray([Color(0, 0, 0, 0.15), Color(0, 0, 0, 0.78)])
	grad.offsets = PackedFloat32Array([0.35, 1.0])
	var grad_tex := GradientTexture2D.new()
	grad_tex.gradient = grad
	grad_tex.fill_from = Vector2(0, 0)
	grad_tex.fill_to = Vector2(0, 1)
	var shade := TextureRect.new()
	shade.texture = grad_tex
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)

func _build_toast() -> void:
	_toast = _label(17, Color(1, 0.6, 0.4))
	_toast.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast.anchor_left = 0.5
	_toast.anchor_right = 0.5
	_toast.offset_top = -40
	_toast.offset_left = -400
	_toast.offset_right = 400
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_toast.add_theme_constant_override("outline_size", 6)
	_toast.text = ""
	add_child(_toast)

func _show_toast(text: String) -> void:
	_toast.text = text
	_toast.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(3.0)
	tw.tween_property(_toast, "modulate:a", 0.0, 1.0)

# PANTALLA PRINCIPAL (todo en una)

func _build_main() -> Control:
	var root := _screen_root()

	# Glow neón detrás del título (varias copias tinte cyan desenfocadas).
	for i in 3:
		var glow := _label(84, Color(NEON.r, NEON.g, NEON.b, 0.20))
		glow.text = "CZ SHOOTER"
		glow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		glow.set_anchors_preset(Control.PRESET_CENTER_TOP)
		glow.anchor_left = 0.5
		glow.anchor_right = 0.5
		glow.offset_left = -400
		glow.offset_right = 400
		glow.offset_top = 40
		glow.scale = Vector2.ONE * (1.0 + 0.012 * (i + 1))
		glow.pivot_offset = Vector2(400, 50)
		glow.add_theme_color_override("font_outline_color", Color(NEON.r, NEON.g, NEON.b, 0.15))
		glow.add_theme_constant_override("outline_size", 10 + i * 8)
		root.add_child(glow)
	var title := _label(84, GOLD)
	title.text = "CZ SHOOTER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_outline_color", Color(0.5, 0.35, 0.05, 0.9))
	title.add_theme_constant_override("outline_size", 6)
	title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title.anchor_left = 0.5
	title.anchor_right = 0.5
	title.offset_left = -400
	title.offset_right = 400
	title.offset_top = 40
	root.add_child(title)
	var subtitle := _label(18, Color(1, 1, 1, 0.85))
	subtitle.text = "one endless community match — drop in, most kills wins"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	subtitle.add_theme_constant_override("outline_size", 6)
	subtitle.set_anchors_preset(Control.PRESET_CENTER_TOP)
	subtitle.anchor_left = 0.5
	subtitle.anchor_right = 0.5
	subtitle.offset_left = -400
	subtitle.offset_right = 400
	subtitle.offset_top = 138
	root.add_child(subtitle)

	# Link a X / Twitter (clickeable, abre en pestaña nueva en web).
	var x_btn := _button("X  ·  Follow @CZshooterbnb", 16)
	x_btn.custom_minimum_size = Vector2(320, 38)
	x_btn.set_anchors_preset(Control.PRESET_CENTER_TOP)
	x_btn.anchor_left = 0.5
	x_btn.anchor_right = 0.5
	x_btn.offset_left = -160
	x_btn.offset_right = 160
	x_btn.offset_top = 174
	x_btn.pressed.connect(func(): OS.shell_open(TWITTER_URL))
	root.add_child(x_btn)

	var panel := _framed_panel(GOLD)
	panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.offset_left = -270
	panel.offset_right = 270
	panel.offset_bottom = -40
	panel.offset_top = -368
	root.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	# Identidad: wallet o guest.
	var id_row := HBoxContainer.new()
	id_row.alignment = BoxContainer.ALIGNMENT_CENTER
	id_row.add_theme_constant_override("separation", 10)
	box.add_child(id_row)
	_wallet_btn = _button("CONNECT WALLET", 16)
	_wallet_btn.custom_minimum_size = Vector2(228, 42)
	_wallet_btn.pressed.connect(_connect_wallet)
	id_row.add_child(_wallet_btn)
	var guest := _button("PLAY AS GUEST", 16)
	guest.custom_minimum_size = Vector2(228, 42)
	guest.pressed.connect(_play_as_guest)
	id_row.add_child(guest)

	_name_edit = LineEdit.new()
	_name_edit.text = GameSettings.player_name
	_name_edit.max_length = 18
	_name_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_edit.add_theme_font_override("font", _font)
	_name_edit.custom_minimum_size = Vector2(0, 38)
	_style_edit(_name_edit)
	box.add_child(_name_edit)

	var char_row := HBoxContainer.new()
	char_row.alignment = BoxContainer.ALIGNMENT_CENTER
	char_row.add_theme_constant_override("separation", 14)
	box.add_child(char_row)
	var prev := _button("<", 20)
	prev.custom_minimum_size = Vector2(52, 38)
	prev.pressed.connect(func(): _shift_character(-1))
	char_row.add_child(prev)
	_char_label = _label(20)
	_char_label.custom_minimum_size = Vector2(240, 0)
	_char_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	char_row.add_child(_char_label)
	var next := _button(">", 20)
	next.custom_minimum_size = Vector2(52, 38)
	next.pressed.connect(func(): _shift_character(1))
	char_row.add_child(next)
	_refresh_char_label()

	# Botón principal: entrar al server real (partida en vivo; los amigos
	# pueden caer en la MISMA sala). Con carga estilo juego real.
	var play := _gold_button("PLAY", 26)
	play.pressed.connect(_join_community)
	box.add_child(play)

	# Estado del server: una sola sala online donde entran todos.
	var status := _label(13, Color(0.4, 0.9, 0.5))
	status.text = "LIVE SERVER  ·  one shared arena — everyone joins here"
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(status)

	var srv_row := HBoxContainer.new()
	srv_row.alignment = BoxContainer.ALIGNMENT_CENTER
	srv_row.add_theme_constant_override("separation", 8)
	box.add_child(srv_row)
	var srv_lbl := _label(12, Color(1, 1, 1, 0.5))
	srv_lbl.text = "SERVER:"
	srv_row.add_child(srv_lbl)
	_server_edit = LineEdit.new()
	_server_edit.text = _default_server_address()
	_server_edit.add_theme_font_override("font", _font)
	_server_edit.add_theme_font_size_override("font_size", 12)
	_server_edit.custom_minimum_size = Vector2(320, 30)
	_style_edit(_server_edit)
	srv_row.add_child(_server_edit)

	var small_row := HBoxContainer.new()
	small_row.alignment = BoxContainer.ALIGNMENT_CENTER
	small_row.add_theme_constant_override("separation", 10)
	box.add_child(small_row)
	var settings := _button("SETTINGS", 13)
	settings.custom_minimum_size = Vector2(150, 32)
	settings.pressed.connect(func(): goto(Screen.SETTINGS))
	small_row.add_child(settings)
	if not OS.has_feature("web"):
		var host_btn := _button("HOST LOCAL", 13)
		host_btn.custom_minimum_size = Vector2(150, 32)
		host_btn.pressed.connect(_on_host_pressed)
		small_row.add_child(host_btn)
		var quit := _button("QUIT", 13)
		quit.custom_minimum_size = Vector2(150, 32)
		quit.pressed.connect(func(): get_tree().quit())
		small_row.add_child(quit)

	var version := _label(12, Color(1, 1, 1, 0.4))
	version.text = "v1.1"
	version.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	version.offset_left = -64
	version.offset_top = -30
	root.add_child(version)
	return root

func _refresh_char_label() -> void:
	if _char_ids.is_empty():
		_char_label.text = "NO CHARACTERS"
		return
	var id := _char_ids[_char_index]
	_char_label.text = CharacterLib.display_name(id)
	_char_label.add_theme_color_override("font_color", CharacterLib.accent_color(id))

func _shift_character(dir: int) -> void:
	if _char_ids.is_empty():
		return
	_char_index = wrapi(_char_index + dir, 0, _char_ids.size())
	_refresh_char_label()

## Identidad wallet EVM (MetaMask u otra wallet inyectada; solo web).
## La dirección 0x... se usa como identidad y como clave del ranking global
## por wallet (para repartir fees). Sin firmar transacciones ni lógica on-chain.
func _connect_wallet() -> void:
	if not OS.has_feature("web"):
		_show_toast("Wallet connect works in the browser version.")
		return
	_wallet_btn.text = "CONNECTING..."
	# MetaMask / EVM: pedimos la cuenta (0x...) que se usa como identidad y
	# para repartir fees en BNB Chain. Mejor esfuerzo: cambiar a BNB (0x38).
	JavaScriptBridge.eval("""
		window._wallet_result = '';
		(async () => {
			try {
				const eth = window.ethereum;
				if (!eth) { window._wallet_result = 'ERR:no_wallet'; return; }
				const accounts = await eth.request({ method: 'eth_requestAccounts' });
				if (!accounts || !accounts.length) { window._wallet_result = 'ERR:rejected'; return; }
				try { await eth.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0x38' }] }); } catch (e) {}
				window._wallet_result = accounts[0];
			} catch (e) { window._wallet_result = 'ERR:' + (e.message || 'rejected'); }
		})();
	""", true)
	_poll_wallet(0)

func _poll_wallet(tries: int) -> void:
	if tries > 40: # ~12s
		_wallet_btn.text = "CONNECT WALLET"
		_show_toast("Wallet connection timed out.")
		return
	var res = JavaScriptBridge.eval("window._wallet_result", true)
	var text := String(res) if res != null else ""
	if text.is_empty():
		get_tree().create_timer(0.3).timeout.connect(func(): _poll_wallet(tries + 1))
		return
	if text.begins_with("ERR:"):
		_wallet_btn.text = "CONNECT WALLET"
		if text == "ERR:no_wallet":
			_show_toast("No wallet found — install MetaMask, or play as guest.")
		else:
			_show_toast("Wallet connection rejected.")
		return
	GameSettings.wallet = text
	var short := text.substr(0, 6) + ".." + text.substr(text.length() - 4)
	_name_edit.text = short
	_wallet_btn.text = "✓ " + short
	GameSettings.save_settings()
	_show_toast("Wallet connected.")

func _play_as_guest() -> void:
	GameSettings.wallet = ""
	if _name_edit.text.strip_edges().is_empty() or _name_edit.text.contains(".."):
		_name_edit.text = "Guest_%d" % (randi() % 900 + 100)
	_show_toast("Playing as guest.")

func _save_identity() -> void:
	GameSettings.player_name = _name_edit.text.strip_edges()
	if GameSettings.player_name.is_empty():
		GameSettings.player_name = "Guest_%d" % (randi() % 900 + 100)
	if not _char_ids.is_empty():
		GameSettings.character_id = _char_ids[_char_index]
	GameSettings.save_settings()

## Jugar YA: partida local contra bots, arranca al instante (sin server).
func _play_offline() -> void:
	_save_identity()
	Net.host_offline()
	Net.begin_infinite()

## Online con amigos: entrás a jugar YA (partida local instantánea) y en
## segundo plano se conecta al server real; cuando despierta te pasa a la
## sala compartida sin que esperes ninguna pantalla de carga.
func _join_community() -> void:
	_save_identity()
	Net.instant_warmup = true
	_join_flow(_server_edit.text)

func _on_host_pressed() -> void:
	GameSettings.player_name = _name_edit.text.strip_edges()
	if not _char_ids.is_empty():
		GameSettings.character_id = _char_ids[_char_index]
	GameSettings.save_settings()
	var err := Net.host()
	if not err.is_empty():
		_show_toast(err)
		return
	Net.begin_infinite()

## Guardar la dirección y cargar la Arena; la conexión se hace desde adentro
## (necesario para que el drop-in reciba el estado de la partida en curso).
func _join_flow(address: String) -> void:
	address = address.strip_edges()
	if address.is_empty():
		_show_toast("Type a server address first.")
		return
	GameSettings.last_server = address
	GameSettings.save_settings()
	Net.pending_join = address
	Transition.change_scene(Net.ARENA_SCENE)

func _default_server_address() -> String:
	var saved := GameSettings.last_server.strip_edges()
	if OS.has_feature("web"):
		var host := ""
		var host_str = JavaScriptBridge.eval("location.hostname", true)
		if host_str != null:
			host = String(host_str)
		# Usar el server real del juego cuando lo guardado está vacío o apunta a
		# la PROPIA web (sitio estático): czshooter.xyz, *-web.onrender.com, o el
		# mismo hostname de la página. Así nunca se conecta al front por error.
		var points_to_front := saved == host or saved.contains("-web.") or saved.contains("czshooter.xyz")
		if saved.is_empty() or points_to_front:
			return DEFAULT_SERVER
		return saved
	# Nativo (desarrollo local).
	if not saved.is_empty():
		return saved
	return "127.0.0.1"

# AJUSTES

func _build_settings() -> Control:
	var root := _screen_root()
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var panel := _framed_panel(GOLD)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.custom_minimum_size = Vector2(620, 0)
	panel.add_child(box)
	var title := _label(30, GOLD)
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	box.add_child(_settings_row_label("MOUSE SENSITIVITY"))
	var sens := HSlider.new()
	sens.min_value = 0.2
	sens.max_value = 3.0
	sens.step = 0.1
	sens.value = GameSettings.mouse_sens_mult
	sens.custom_minimum_size = Vector2(400, 24)
	sens.value_changed.connect(func(v):
		GameSettings.mouse_sens_mult = v
		GameSettings.save_settings())
	box.add_child(sens)

	box.add_child(_settings_row_label("VOLUME"))
	var vol := HSlider.new()
	vol.min_value = 0
	vol.max_value = 100
	vol.step = 1
	vol.value = GameSettings.volume
	vol.custom_minimum_size = Vector2(400, 24)
	vol.value_changed.connect(func(v):
		GameSettings.volume = v
		GameSettings.apply_volume()
		GameSettings.save_settings())
	box.add_child(vol)

	box.add_child(_settings_row_label("GRAPHICS QUALITY"))
	var quality := OptionButton.new()
	quality.add_theme_font_override("font", _font)
	for opt in ["LOW", "MEDIUM", "HIGH"]:
		quality.add_item(opt)
	quality.select(GameSettings.quality)
	quality.item_selected.connect(func(i):
		GameSettings.quality = i
		GameSettings.apply_quality()
		GameSettings.save_settings())
	box.add_child(quality)

	box.add_child(_settings_row_label("FIELD OF VIEW (FOV)"))
	var fov := HSlider.new()
	fov.min_value = 70
	fov.max_value = 110
	fov.step = 1
	fov.value = GameSettings.fov
	fov.custom_minimum_size = Vector2(400, 24)
	fov.value_changed.connect(func(v):
		GameSettings.fov = v
		GameSettings.save_settings())
	box.add_child(fov)

	var stats := CheckButton.new()
	stats.text = "SHOW PING / FPS"
	stats.add_theme_font_override("font", _font)
	stats.add_theme_font_size_override("font_size", 15)
	stats.button_pressed = GameSettings.show_stats
	stats.toggled.connect(func(v):
		GameSettings.show_stats = v
		GameSettings.save_settings())
	box.add_child(stats)

	box.add_child(_settings_row_label("CONTROLS (click to rebind)"))
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 6)
	box.add_child(grid)
	for action in GameSettings.REBINDABLE:
		var lbl := _label(15)
		lbl.text = GameSettings.ACTION_LABELS.get(action, action)
		grid.add_child(lbl)
		var btn := Button.new()
		btn.add_theme_font_override("font", _font)
		btn.add_theme_font_size_override("font_size", 14)
		btn.text = GameSettings.bind_label(action)
		btn.custom_minimum_size = Vector2(110, 30)
		btn.pressed.connect(_begin_rebind.bind(action))
		_rebind_buttons[action] = btn
		grid.add_child(btn)

	var back := _button("BACK", 18)
	back.pressed.connect(func():
		GameSettings.save_settings()
		goto(Screen.MAIN))
	box.add_child(back)
	return root

func _settings_row_label(text: String) -> Label:
	var l := _label(16, Color(1, 1, 1, 0.65))
	l.text = text
	return l

func _begin_rebind(action: String) -> void:
	if not _awaiting_rebind.is_empty() and _rebind_buttons.has(_awaiting_rebind):
		_rebind_buttons[_awaiting_rebind].text = GameSettings.bind_label(_awaiting_rebind)
	_awaiting_rebind = action
	_rebind_buttons[action].text = "PRESS A KEY..."

func _input(event: InputEvent) -> void:
	if _awaiting_rebind.is_empty():
		if event.is_action_pressed("ui_cancel") and _current == Screen.SETTINGS:
			GameSettings.save_settings()
			goto(Screen.MAIN)
		return
	if event is InputEventKey and event.is_pressed():
		var key_event := event as InputEventKey
		var code: int = key_event.physical_keycode if key_event.physical_keycode != KEY_NONE else key_event.keycode
		GameSettings.rebind(_awaiting_rebind, code)
		_rebind_buttons[_awaiting_rebind].text = GameSettings.bind_label(_awaiting_rebind)
		_awaiting_rebind = ""
		get_viewport().set_input_as_handled()

# RESULTADOS (solo para salas por rondas; la comunitaria nunca termina)

func _build_results() -> Control:
	var root := _screen_root()
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style(GOLD))
	center.add_child(panel)
	_results_box = VBoxContainer.new()
	_results_box.add_theme_constant_override("separation", 10)
	_results_box.custom_minimum_size = Vector2(640, 0)
	panel.add_child(_results_box)
	return root

func _fill_results() -> void:
	for c in _results_box.get_children():
		c.queue_free()
	var res: Dictionary = Net.last_results
	if res.is_empty():
		goto(Screen.MAIN)
		return
	var final_players: Dictionary = res["players"]
	var winner_id: int = res["winner"]
	var my_id: int = res["my_id"]
	var ids := Net.sorted_ids(final_players)
	var title := _label(34, GOLD)
	title.text = "ROUND OVER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_results_box.add_child(title)
	if final_players.has(winner_id):
		var win := _label(26)
		win.text = "🏆 WINNER: %s (%d kills)" % [final_players[winner_id]["name"], int(final_players[winner_id]["kills"])]
		win.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_results_box.add_child(win)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 30)
	_results_box.add_child(grid)
	for header in ["PLAYER", "KILLS", "DEATHS", "SCORE"]:
		var h := _label(15, Color(1, 1, 1, 0.55))
		h.text = header
		grid.add_child(h)
	var rank := 0
	for id in ids:
		rank += 1
		var pl: Dictionary = final_players[id]
		var color := GOLD if id == winner_id else (BLUE if id == my_id else Color.WHITE)
		for text in ["%d. %s" % [rank, pl["name"]], str(int(pl["kills"])),
				str(int(pl["deaths"])), str(int(pl.get("score", 0)))]:
			var cell := _label(18, color)
			cell.text = String(text)
			grid.add_child(cell)
	var to_menu := _button("BACK TO MENU", 20)
	to_menu.pressed.connect(func():
		Net.leave()
		Net.last_results = {}
		goto(Screen.MAIN))
	_results_box.add_child(to_menu)
