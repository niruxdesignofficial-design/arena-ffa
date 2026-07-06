# Menu.gd
# Marco completo del juego: pantalla de inicio, selección de personaje
# (con preview 3D girando), sala/lobby (crear, buscar LAN, unirse por IP),
# ajustes persistidos y pantalla de fin de ronda con revancha.
extends Control

enum Screen { MAIN, CHARACTER, LOBBY, SETTINGS, RESULTS }

const FONT_PATH := "res://UI/Share_Tech_Mono_Font/ShareTechMono-Regular.ttf"
const GOLD := Color(0.953, 0.729, 0.184)
const BLUE := Color(0.235, 0.604, 0.831)
const PANEL_BG := Color(0.086, 0.09, 0.102, 0.92)

var _font: FontFile
var _screens := {}
var _current: int = Screen.MAIN

# Selección de personaje.
var _char_ids: Array[String] = []
var _char_index := 0
var _preview_viewport: SubViewport
var _preview_rig_holder: Node3D
var _char_name_label: Label
var _name_edit: LineEdit

# Lobby.
var _lobby_pre: VBoxContainer
var _lobby_room: VBoxContainer
var _lobby_players_box: VBoxContainer
var _lobby_status: Label
var _lobby_start_btn: Button
var _ip_edit: LineEdit
var _search_results: VBoxContainer
var _toast: Label

# Ajustes.
var _awaiting_rebind := ""
var _rebind_buttons := {}

# Resultados.
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
	_screens[Screen.CHARACTER] = _build_character()
	_screens[Screen.LOBBY] = _build_lobby()
	_screens[Screen.SETTINGS] = _build_settings()
	_screens[Screen.RESULTS] = _build_results()
	_build_toast()
	Net.players_changed.connect(_refresh_lobby)
	Net.session_closed.connect(_on_session_closed)
	Net.lan_search_done.connect(_on_lan_results)
	if not Net.last_error.is_empty():
		_show_toast.call_deferred(Net.last_error)
		Net.last_error = ""
	if not Net.last_results.is_empty():
		goto(Screen.RESULTS)
	else:
		if Net.session_active():
			Net.leave()
		goto(Screen.MAIN)

func goto(screen: int) -> void:
	_current = screen
	for key in _screens:
		_screens[key].visible = (key == screen)
	if screen == Screen.CHARACTER:
		_rebuild_preview()
	if screen == Screen.RESULTS:
		_fill_results()
	if screen == Screen.LOBBY:
		if Net.session_active():
			_show_room()
		else:
			_show_pre_lobby()

# HELPERS DE UI

func _label(size: int, color := Color.WHITE) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

func _button(text: String, size := 22) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", size)
	b.custom_minimum_size = Vector2(340, 46)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.10, 0.12, 0.155)
	normal.border_color = Color(BLUE.r, BLUE.g, BLUE.b, 0.35)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(8)
	normal.set_content_margin_all(10)
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color(0.135, 0.175, 0.225)
	hover.border_color = BLUE
	hover.set_border_width_all(2)
	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.bg_color = Color(0.08, 0.09, 0.11)
	pressed.border_color = GOLD
	pressed.set_border_width_all(2)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", hover.duplicate())
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_color_override("font_pressed_color", GOLD)
	b.pressed.connect(func(): Sfx.play("ui", -6.0))
	return b

func _panel_style(border := BLUE) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.border_color = Color(border.r, border.g, border.b, 0.45)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(26)
	sb.shadow_color = Color(0, 0, 0, 0.5)
	sb.shadow_size = 18
	return sb

func _screen_root() -> CenterContainer:
	var c := CenterContainer.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.visible = false
	add_child(c)
	return c

func _build_background() -> void:
	# Gradiente azul profundo -> casi negro, con una banda dorada sutil.
	var grad := Gradient.new()
	grad.colors = PackedColorArray([
		Color(0.075, 0.10, 0.155), Color(0.045, 0.055, 0.08), Color(0.03, 0.035, 0.05),
	])
	grad.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	var grad_tex := GradientTexture2D.new()
	grad_tex.gradient = grad
	grad_tex.fill_from = Vector2(0, 0)
	grad_tex.fill_to = Vector2(0, 1)
	var bg := TextureRect.new()
	bg.texture = grad_tex
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var line := ColorRect.new()
	line.color = Color(GOLD.r, GOLD.g, GOLD.b, 0.25)
	line.set_anchors_preset(Control.PRESET_FULL_RECT)
	line.anchor_top = 0.328
	line.anchor_bottom = 0.331
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(line)

func _build_toast() -> void:
	_toast = _label(17, Color(1, 0.6, 0.4))
	_toast.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast.anchor_left = 0.5
	_toast.anchor_right = 0.5
	_toast.offset_top = -60
	_toast.offset_left = -400
	_toast.offset_right = 400
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.text = ""
	add_child(_toast)

func _show_toast(text: String) -> void:
	_toast.text = text
	_toast.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(3.0)
	tw.tween_property(_toast, "modulate:a", 0.0, 1.0)

# PANTALLA PRINCIPAL

func _build_main() -> Control:
	var root := _screen_root()
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 14)
	root.add_child(box)
	var title := _label(76, GOLD)
	title.text = "ARENA FFA"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_outline_color", Color(0.25, 0.16, 0.02))
	title.add_theme_constant_override("outline_size", 10)
	box.add_child(title)
	var subtitle := _label(20, Color(1, 1, 1, 0.55))
	subtitle.text = "free-for-all — most kills wins"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(subtitle)
	box.add_child(_spacer(30))
	var play := _button("PLAY")
	play.pressed.connect(func(): goto(Screen.CHARACTER))
	box.add_child(play)
	var settings := _button("SETTINGS")
	settings.pressed.connect(func(): goto(Screen.SETTINGS))
	box.add_child(settings)
	var quit := _button("QUIT")
	quit.pressed.connect(func(): get_tree().quit())
	box.add_child(quit)
	var version := _label(13, Color(1, 1, 1, 0.35))
	version.text = "v1.0"
	version.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	version.offset_left = -70
	version.offset_top = -34
	root.add_child(version)
	return root

func _spacer(h: float) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	return s

# SELECCIÓN DE PERSONAJE

func _build_character() -> Control:
	var root := _screen_root()
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	root.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	var title := _label(30, GOLD)
	title.text = "CHOOSE YOUR CHARACTER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 10)
	box.add_child(name_row)
	var name_lbl := _label(18)
	name_lbl.text = "YOUR NAME:"
	name_row.add_child(name_lbl)
	_name_edit = LineEdit.new()
	_name_edit.text = GameSettings.player_name
	_name_edit.max_length = 18
	_name_edit.add_theme_font_override("font", _font)
	_name_edit.custom_minimum_size = Vector2(280, 36)
	name_row.add_child(_name_edit)

	var carousel := HBoxContainer.new()
	carousel.add_theme_constant_override("separation", 16)
	carousel.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(carousel)
	var prev := _button("<", 30)
	prev.custom_minimum_size = Vector2(60, 300)
	prev.pressed.connect(func(): _shift_character(-1))
	carousel.add_child(prev)

	var vp_container := SubViewportContainer.new()
	vp_container.stretch = true
	vp_container.custom_minimum_size = Vector2(380, 400)
	carousel.add_child(vp_container)
	_preview_viewport = SubViewport.new()
	_preview_viewport.own_world_3d = true
	_preview_viewport.transparent_bg = true
	_preview_viewport.msaa_3d = Viewport.MSAA_2X
	vp_container.add_child(_preview_viewport)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.05, 2.6)
	cam.look_at_from_position(cam.position, Vector3(0, 0.85, 0))
	_preview_viewport.add_child(cam)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, -25, 0)
	_preview_viewport.add_child(light)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 140, 0)
	fill.light_energy = 0.5
	_preview_viewport.add_child(fill)
	_preview_rig_holder = Node3D.new()
	_preview_viewport.add_child(_preview_rig_holder)

	var next := _button(">", 30)
	next.custom_minimum_size = Vector2(60, 300)
	next.pressed.connect(func(): _shift_character(1))
	carousel.add_child(next)

	_char_name_label = _label(26)
	_char_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_char_name_label)

	if not CharacterLib.issues.is_empty():
		var warn := _label(13, Color(1, 0.75, 0.35, 0.9))
		warn.text = "⚠ " + "\n⚠ ".join(CharacterLib.issues.slice(0, 3))
		warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(warn)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 16)
	box.add_child(buttons)
	var back := _button("BACK", 18)
	back.custom_minimum_size = Vector2(200, 44)
	back.pressed.connect(func(): goto(Screen.MAIN))
	buttons.add_child(back)
	var go := _button("CONTINUE", 18)
	go.custom_minimum_size = Vector2(200, 44)
	go.pressed.connect(_confirm_character)
	buttons.add_child(go)
	return root

func _shift_character(dir: int) -> void:
	if _char_ids.is_empty():
		return
	_char_index = wrapi(_char_index + dir, 0, _char_ids.size())
	_rebuild_preview()

func _rebuild_preview() -> void:
	for c in _preview_rig_holder.get_children():
		c.queue_free()
	if _char_ids.is_empty():
		_char_name_label.text = "NO CHARACTERS IN MANIFEST"
		return
	var id := _char_ids[_char_index]
	var rig := CharacterLib.build_rig(id)
	if rig:
		_preview_rig_holder.add_child(rig)
		rig.set_state(CharacterRig.State.WALK) # que se lo vea animado
	_char_name_label.text = CharacterLib.display_name(id)
	_char_name_label.add_theme_color_override("font_color", CharacterLib.accent_color(id))

func _confirm_character() -> void:
	GameSettings.player_name = _name_edit.text.strip_edges()
	if GameSettings.player_name.is_empty():
		GameSettings.player_name = "Player"
	if not _char_ids.is_empty():
		GameSettings.character_id = _char_ids[_char_index]
	GameSettings.save_settings()
	goto(Screen.LOBBY)

func _process(delta: float) -> void:
	if _current == Screen.CHARACTER and _preview_rig_holder:
		_preview_rig_holder.rotation.y += delta * 0.9

# LOBBY / SALA

func _build_lobby() -> Control:
	var root := _screen_root()
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	root.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	box.custom_minimum_size = Vector2(560, 0)
	panel.add_child(box)

	# Pre-sala: crear / buscar / unirse.
	_lobby_pre = VBoxContainer.new()
	_lobby_pre.add_theme_constant_override("separation", 12)
	box.add_child(_lobby_pre)
	var title := _label(30, GOLD)
	title.text = "ONLINE MATCH"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lobby_pre.add_child(title)
	var on_web := OS.has_feature("web")
	if on_web:
		# En el navegador no se puede abrir un puerto: solo unirse al server.
		var find_btn := _button("FIND MATCH")
		find_btn.pressed.connect(_on_join_pressed)
		_lobby_pre.add_child(find_btn)
	else:
		var host_btn := _button("CREATE ROOM")
		host_btn.pressed.connect(_on_host_pressed)
		_lobby_pre.add_child(host_btn)
		var search_btn := _button("FIND MATCH (LAN)")
		search_btn.pressed.connect(_on_search_pressed)
		_lobby_pre.add_child(search_btn)
	_search_results = VBoxContainer.new()
	_lobby_pre.add_child(_search_results)
	var ip_row := HBoxContainer.new()
	ip_row.add_theme_constant_override("separation", 10)
	_lobby_pre.add_child(ip_row)
	_ip_edit = LineEdit.new()
	_ip_edit.text = _default_server_address()
	_ip_edit.add_theme_font_override("font", _font)
	_ip_edit.custom_minimum_size = Vector2(240, 40)
	ip_row.add_child(_ip_edit)
	var join_btn := _button("JOIN BY IP", 18)
	join_btn.custom_minimum_size = Vector2(220, 40)
	join_btn.pressed.connect(_on_join_pressed)
	ip_row.add_child(join_btn)
	var back := _button("BACK", 18)
	back.pressed.connect(func(): goto(Screen.CHARACTER))
	_lobby_pre.add_child(back)

	# Sala armada: lista de jugadores conectados.
	_lobby_room = VBoxContainer.new()
	_lobby_room.add_theme_constant_override("separation", 12)
	_lobby_room.visible = false
	box.add_child(_lobby_room)
	_lobby_status = _label(26, GOLD)
	_lobby_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lobby_room.add_child(_lobby_status)
	_lobby_players_box = VBoxContainer.new()
	_lobby_players_box.add_theme_constant_override("separation", 6)
	_lobby_room.add_child(_lobby_players_box)
	_lobby_start_btn = _button("START MATCH")
	_lobby_start_btn.pressed.connect(func(): Net.request_start())
	_lobby_room.add_child(_lobby_start_btn)
	var leave_btn := _button("LEAVE ROOM", 18)
	leave_btn.pressed.connect(_leave_room)
	_lobby_room.add_child(leave_btn)
	return root

func _default_server_address() -> String:
	# Prioridad: último server usado > host de la página (web) > localhost.
	if not GameSettings.last_server.is_empty():
		return GameSettings.last_server
	if OS.has_feature("web"):
		var host_str = JavaScriptBridge.eval("location.hostname", true)
		if host_str != null and not String(host_str).is_empty():
			return String(host_str)
	return "127.0.0.1"

func _show_pre_lobby() -> void:
	_lobby_pre.visible = true
	_lobby_room.visible = false

func _show_room() -> void:
	_lobby_pre.visible = false
	_lobby_room.visible = true
	_refresh_lobby()

func _on_host_pressed() -> void:
	var err := Net.host()
	if not err.is_empty():
		_show_toast(err)
		return
	# Sin lobby: el host entra a jugar ya, con bots hasta que lleguen amigos.
	Net.begin_infinite()

## Entrar a un server: guardar la dirección y cargar la Arena; la conexión
## se hace desde adentro (necesario para el drop-in).
func _join_flow(address: String) -> void:
	address = address.strip_edges()
	if address.is_empty():
		_show_toast("Type a server address first.")
		return
	GameSettings.last_server = address
	GameSettings.save_settings()
	Net.pending_join = address
	Transition.change_scene(Net.ARENA_SCENE)

func _on_join_pressed() -> void:
	_join_flow(_ip_edit.text)

func _on_search_pressed() -> void:
	for c in _search_results.get_children():
		c.queue_free()
	var status := _label(16, Color(1, 1, 1, 0.6))
	status.text = "Searching for rooms on the local network..."
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_search_results.add_child(status)
	Net.search_lan()

func _on_lan_results(hosts: Array) -> void:
	for c in _search_results.get_children():
		c.queue_free()
	if hosts.is_empty():
		var none := _label(16, Color(1, 1, 1, 0.6))
		none.text = "No rooms found."
		none.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_search_results.add_child(none)
		return
	for h in hosts:
		var b := _button("JOIN %s'S ROOM (%s)" % [String(h["name"]).to_upper(), h["ip"]], 16)
		b.pressed.connect(func(): _join_flow(String(h["ip"])))
		_search_results.add_child(b)

func _refresh_lobby() -> void:
	if _current != Screen.LOBBY or not _lobby_room.visible:
		return
	for c in _lobby_players_box.get_children():
		c.queue_free()
	var count := Net.players.size()
	_lobby_status.text = "ROOM — %d player%s" % [count, "" if count == 1 else "s"]
	for id in Net.players:
		var p: Dictionary = Net.players[id]
		var row := _label(18)
		var tags := ""
		if id == Net.leader_id and not Net.dedicated:
			tags += "  [LEADER]"
		if id == Net.my_id():
			tags += "  (you)"
		row.text = "• %s — %s%s" % [p["name"], CharacterLib.display_name(String(p["character"])), tags]
		_lobby_players_box.add_child(row)
	_lobby_start_btn.visible = Net.i_am_leader()
	if not Net.i_am_leader():
		var waiting := _label(15, Color(1, 1, 1, 0.5))
		waiting.text = "Waiting for the leader to start the match..."
		_lobby_players_box.add_child(waiting)

func _leave_room() -> void:
	Net.leave()
	_show_pre_lobby()

func _on_session_closed(reason: String) -> void:
	_show_toast(reason)
	if _current == Screen.LOBBY:
		_show_pre_lobby()
	elif _current == Screen.RESULTS:
		_fill_results()

# AJUSTES

func _build_settings() -> Control:
	var root := _screen_root()
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	root.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.custom_minimum_size = Vector2(620, 0)
	panel.add_child(box)
	var title := _label(30, GOLD)
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	# Sensibilidad.
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

	# Volumen.
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

	# Calidad gráfica.
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

	# Campo de visión.
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

	# Ping/FPS en el HUD.
	var stats := CheckButton.new()
	stats.text = "SHOW PING / FPS"
	stats.add_theme_font_override("font", _font)
	stats.add_theme_font_size_override("font_size", 15)
	stats.button_pressed = GameSettings.show_stats
	stats.toggled.connect(func(v):
		GameSettings.show_stats = v
		GameSettings.save_settings())
	box.add_child(stats)

	# Controles.
	box.add_child(_settings_row_label("CONTROLS (click to rebind)"))
	var grid := GridContainer.new()
	grid.columns = 5
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
	# Cancelar cualquier rebind previo colgado.
	if not _awaiting_rebind.is_empty() and _rebind_buttons.has(_awaiting_rebind):
		_rebind_buttons[_awaiting_rebind].text = GameSettings.bind_label(_awaiting_rebind)
	_awaiting_rebind = action
	_rebind_buttons[action].text = "PRESS A KEY..."

func _input(event: InputEvent) -> void:
	if _awaiting_rebind.is_empty():
		if event.is_action_pressed("ui_cancel"):
			match _current:
				Screen.CHARACTER:
					goto(Screen.MAIN)
				Screen.SETTINGS:
					GameSettings.save_settings()
					goto(Screen.MAIN)
				Screen.LOBBY:
					if not Net.session_active():
						goto(Screen.CHARACTER)
		return
	if event is InputEventKey and event.is_pressed():
		var key_event := event as InputEventKey
		var code: int = key_event.physical_keycode if key_event.physical_keycode != KEY_NONE else key_event.keycode
		GameSettings.rebind(_awaiting_rebind, code)
		_rebind_buttons[_awaiting_rebind].text = GameSettings.bind_label(_awaiting_rebind)
		_awaiting_rebind = ""
		get_viewport().set_input_as_handled()

# FIN DE RONDA

func _build_results() -> Control:
	var root := _screen_root()
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style(GOLD))
	root.add_child(panel)
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
		var wname: String = final_players[winner_id]["name"]
		var win := _label(26)
		win.text = "🏆 WINNER: %s (%d kills)" % [wname, int(final_players[winner_id]["kills"])]
		win.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_results_box.add_child(win)
	if final_players.has(my_id):
		var my_rank := ids.find(my_id) + 1
		var me: Dictionary = final_players[my_id]
		var mine := _label(18, Color(1, 1, 1, 0.75))
		mine.text = "You finished #%d — %d kills / %d deaths" % [my_rank, int(me["kills"]), int(me["deaths"])]
		mine.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_results_box.add_child(mine)

	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 30)
	grid.add_theme_constant_override("v_separation", 4)
	_results_box.add_child(grid)
	for header in ["PLAYER", "CHARACTER", "KILLS", "DEATHS", "SCORE"]:
		var h := _label(15, Color(1, 1, 1, 0.55))
		h.text = header
		grid.add_child(h)
	var rank := 0
	for id in ids:
		rank += 1
		var p: Dictionary = final_players[id]
		var color := Color.WHITE
		if id == winner_id:
			color = GOLD
		elif id == my_id:
			color = BLUE
		for text in ["%d. %s%s" % [rank, p["name"], " 🏆" if id == winner_id else ""],
				CharacterLib.display_name(String(p["character"])),
				str(int(p["kills"])), str(int(p["deaths"])), str(int(p.get("score", 0)))]:
			var cell := _label(18, color)
			cell.text = String(text)
			grid.add_child(cell)

	_results_box.add_child(_spacer(10))
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 16)
	_results_box.add_child(buttons)
	if Net.i_am_leader():
		var rematch := _button("REMATCH", 20)
		rematch.custom_minimum_size = Vector2(240, 46)
		rematch.pressed.connect(func(): Net.request_start())
		buttons.add_child(rematch)
	elif Net.session_active():
		var waiting := _label(16, Color(1, 1, 1, 0.6))
		waiting.text = "The leader can start a rematch..."
		buttons.add_child(waiting)
	var to_menu := _button("BACK TO MENU", 20)
	to_menu.custom_minimum_size = Vector2(240, 46)
	to_menu.pressed.connect(func():
		Net.leave()
		Net.last_results = {}
		goto(Screen.MAIN))
	buttons.add_child(to_menu)
