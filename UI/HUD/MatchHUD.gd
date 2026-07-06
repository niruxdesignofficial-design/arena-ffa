# MatchHUD.gd
# Capa de HUD de partida: scoreboard en vivo (Tab), líder actual, kills
# propios, reloj de ronda, kill feed, hitmarker, flash de daño, pantalla
# de muerte y menú de pausa. Todos los datos vienen de la réplica del
# server (Net.players): acá no se calcula ningún puntaje.
extends CanvasLayer

const FONT_PATH := "res://UI/Share_Tech_Mono_Font/ShareTechMono-Regular.ttf"
const GOLD := Color(0.953, 0.729, 0.184)
const PANEL_BG := Color(0.086, 0.09, 0.102, 0.86)

var _font: FontFile
var _timer_label: Label
var _leader_label: Label
var _kills_label: Label
var _feed_box: VBoxContainer
var _scoreboard: PanelContainer
var _score_grid: GridContainer
var _hitmarker: Label
var _damage_rect: ColorRect
var _death_panel: CenterContainer
var _death_label: Label
var _death_count: Label
var _death_left := 0.0
var _pause_panel: CenterContainer
var _vignette: ColorRect
var _countdown: Label
var _kill_popup: Label
var _pickup_label: Label
var _weapon_bar: HBoxContainer
var _weapon_slots: Array[Label] = []

func _ready() -> void:
	layer = 10
	add_to_group("match-ui")
	_font = load(FONT_PATH)
	_build()
	Net.players_changed.connect(_refresh_scores)
	Net.kill_feed.connect(_on_kill_feed)
	Net.round_time_changed.connect(_on_time)
	Net.countdown_started.connect(_on_countdown)
	Net.round_reset.connect(_on_round_reset)
	_refresh_scores()
	_on_time(Net.round_seconds_left)

func _label(size: int, color := Color.WHITE) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.border_color = Color(0.235, 0.604, 0.831, 0.4)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(14)
	return sb

func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# Viñeta roja permanente cuando la vida está baja.
	_vignette = ColorRect.new()
	_vignette.color = Color(0.7, 0.0, 0.0, 0.0)
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_vignette)

	# Flash de daño (pantalla completa).
	_damage_rect = ColorRect.new()
	_damage_rect.color = Color(0.8, 0.05, 0.05, 0.0)
	_damage_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_damage_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_damage_rect)

	# Reloj + líder, arriba al centro.
	var top := VBoxContainer.new()
	top.set_anchors_preset(Control.PRESET_CENTER_TOP)
	top.anchor_left = 0.5
	top.anchor_right = 0.5
	top.offset_top = 12
	top.offset_left = -220
	top.offset_right = 220
	top.alignment = BoxContainer.ALIGNMENT_BEGIN
	root.add_child(top)
	_timer_label = _label(30)
	_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(_timer_label)
	_leader_label = _label(17, GOLD)
	_leader_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(_leader_label)

	# Kills propios, arriba a la izquierda.
	_kills_label = _label(22)
	_kills_label.position = Vector2(20, 12)
	root.add_child(_kills_label)

	# Kill feed, arriba a la derecha.
	_feed_box = VBoxContainer.new()
	_feed_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_feed_box.anchor_left = 1.0
	_feed_box.offset_left = -460
	_feed_box.offset_right = -16
	_feed_box.offset_top = 12
	_feed_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	root.add_child(_feed_box)

	# Hitmarker.
	_hitmarker = _label(30, Color(1, 1, 1, 0))
	_hitmarker.text = "✕"
	_hitmarker.set_anchors_preset(Control.PRESET_CENTER)
	_hitmarker.position = Vector2.ZERO
	root.add_child(_hitmarker)
	_hitmarker.set_anchors_and_offsets_preset(Control.PRESET_CENTER)

	# Scoreboard (Tab).
	_scoreboard = PanelContainer.new()
	_scoreboard.add_theme_stylebox_override("panel", _panel_style())
	_scoreboard.set_anchors_preset(Control.PRESET_CENTER)
	_scoreboard.visible = false
	root.add_child(_scoreboard)
	var sb_box := VBoxContainer.new()
	sb_box.add_theme_constant_override("separation", 8)
	_scoreboard.add_child(sb_box)
	var title := _label(24, GOLD)
	title.text = "SCOREBOARD — FREE FOR ALL"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sb_box.add_child(title)
	_score_grid = GridContainer.new()
	_score_grid.columns = 6
	_score_grid.add_theme_constant_override("h_separation", 26)
	_score_grid.add_theme_constant_override("v_separation", 4)
	sb_box.add_child(_score_grid)

	# Pantalla de muerte.
	_death_panel = CenterContainer.new()
	_death_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_death_panel.visible = false
	_death_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_death_panel)
	var dp := PanelContainer.new()
	dp.add_theme_stylebox_override("panel", _panel_style())
	_death_panel.add_child(dp)
	var dv := VBoxContainer.new()
	dv.alignment = BoxContainer.ALIGNMENT_CENTER
	dp.add_child(dv)
	_death_label = _label(28, Color(0.9, 0.25, 0.25))
	_death_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dv.add_child(_death_label)
	_death_count = _label(20)
	_death_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dv.add_child(_death_count)

	# Countdown de arranque (3, 2, 1, ¡JUGÁ!).
	_countdown = _label(84, GOLD)
	_countdown.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_countdown.text = ""
	root.add_child(_countdown)

	# Aviso "CLICK TO PLAY" cuando el mouse no está capturado (clave en web).
	_click_hint = _label(26, GOLD)
	_click_hint.text = "CLICK TO PLAY"
	_click_hint.set_anchors_preset(Control.PRESET_CENTER)
	_click_hint.anchor_top = 0.72
	_click_hint.anchor_bottom = 0.72
	_click_hint.visible = false
	root.add_child(_click_hint)

	# "+1 KILL" al confirmar una baja.
	_kill_popup = _label(30, GOLD)
	_kill_popup.set_anchors_preset(Control.PRESET_CENTER)
	_kill_popup.anchor_top = 0.36
	_kill_popup.anchor_bottom = 0.36
	_kill_popup.modulate.a = 0.0
	_kill_popup.text = "+1 KILL"
	root.add_child(_kill_popup)

	# Aviso de pickup (munición).
	_pickup_label = _label(20, Color(0.6, 0.9, 1.0))
	_pickup_label.set_anchors_preset(Control.PRESET_CENTER)
	_pickup_label.anchor_top = 0.62
	_pickup_label.anchor_bottom = 0.62
	_pickup_label.modulate.a = 0.0
	root.add_child(_pickup_label)

	# Barra de armas (1-6) abajo al centro.
	_weapon_bar = HBoxContainer.new()
	_weapon_bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_weapon_bar.anchor_left = 0.5
	_weapon_bar.anchor_right = 0.5
	_weapon_bar.offset_top = -44
	_weapon_bar.offset_left = -320
	_weapon_bar.offset_right = 320
	_weapon_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	_weapon_bar.add_theme_constant_override("separation", 16)
	root.add_child(_weapon_bar)
	for i in WeaponDefs.count():
		var slot := _label(14, Color(1, 1, 1, 0.45))
		slot.text = "%d %s" % [i + 1, String(WeaponDefs.get_def(i)["name"]).to_upper()]
		_weapon_bar.add_child(slot)
		_weapon_slots.append(slot)

	# Menú de pausa (ESC).
	_pause_panel = CenterContainer.new()
	_pause_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_panel.visible = false
	root.add_child(_pause_panel)
	var pp := PanelContainer.new()
	pp.add_theme_stylebox_override("panel", _panel_style())
	_pause_panel.add_child(pp)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 10)
	pp.add_child(pv)
	var pt := _label(24)
	pt.text = "PAUSED"
	pt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pv.add_child(pt)
	var resume := Button.new()
	resume.text = "RESUME"
	resume.add_theme_font_override("font", _font)
	resume.pressed.connect(_toggle_pause)
	pv.add_child(resume)
	var quit := Button.new()
	quit.text = "LEAVE TO MENU"
	quit.add_theme_font_override("font", _font)
	quit.pressed.connect(_quit_match)
	pv.add_child(quit)
	var note := _label(12, Color(1, 1, 1, 0.5))
	note.text = "(leaving closes the room if you're the host)"
	pv.add_child(note)

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("scoreboard"):
		_scoreboard.visible = true
		_refresh_scores()
	elif event.is_action_released("scoreboard"):
		_scoreboard.visible = false
	elif event.is_action_pressed("ui_cancel"):
		_toggle_pause()

func _process(delta: float) -> void:
	_click_hint.visible = Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
		and not _pause_panel.visible and not _death_panel.visible
	if _click_hint.visible:
		_click_hint.modulate.a = 0.6 + 0.4 * sin(Time.get_ticks_msec() / 250.0)
	if _death_panel.visible and _death_left > 0:
		_death_left = maxf(0.0, _death_left - delta)
		_death_count.text = "Respawning in %d..." % int(ceil(_death_left))

func is_paused() -> bool:
	return _pause_panel.visible

func _toggle_pause() -> void:
	_pause_panel.visible = not _pause_panel.visible
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if _pause_panel.visible else Input.MOUSE_MODE_CAPTURED)

func _quit_match() -> void:
	Net.leave()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	Transition.change_scene(Net.MENU_SCENE)

# DATOS (réplica del server)

func _refresh_scores() -> void:
	var my_id := Net.my_id()
	var ids := Net.sorted_ids()
	# Kills propios + líder.
	if Net.players.has(my_id):
		_kills_label.text = "KILLS: %d" % int(Net.players[my_id]["kills"])
	if not ids.is_empty():
		var lead: Dictionary = Net.players[ids[0]]
		_leader_label.text = "LEADER: %s (%d)" % [lead["name"], int(lead["kills"])]
	# Tabla.
	for child in _score_grid.get_children():
		child.queue_free()
	for header in ["PLAYER", "CHARACTER", "KILLS", "DEATHS", "STREAK", "SCORE"]:
		var h := _label(16, Color(1, 1, 1, 0.6))
		h.text = header
		_score_grid.add_child(h)
	var rank := 0
	for id in ids:
		rank += 1
		var p: Dictionary = Net.players[id]
		var color := Color.WHITE
		if id == my_id:
			color = GOLD
		var crown := "👑 " if (rank == 1 and int(p["kills"]) > 0) else ""
		var cells := [
			"%d. %s%s" % [rank, crown, p["name"]],
			CharacterLib.display_name(String(p["character"])),
			str(int(p["kills"])),
			str(int(p["deaths"])),
			"x%d" % int(p["streak"]) if int(p["streak"]) > 1 else "—",
			str(int(p.get("score", 0))),
		]
		for text in cells:
			var c := _label(18, color)
			c.text = String(text)
			_score_grid.add_child(c)

func _on_kill_feed(text: String) -> void:
	var l := _label(16)
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_feed_box.add_child(l)
	var tw := l.create_tween()
	tw.tween_interval(3.2)
	tw.tween_property(l, "modulate:a", 0.0, 0.8)
	tw.tween_callback(l.queue_free)

func _on_time(seconds: int) -> void:
	seconds = maxi(seconds, 0)
	_timer_label.text = "%02d:%02d" % [seconds / 60, seconds % 60]

## Para AutoTest y otros: mostrar/ocultar el scoreboard programáticamente.
func set_scoreboard_visible(v: bool) -> void:
	_scoreboard.visible = v
	if v:
		_refresh_scores()

func _on_round_reset(winner_name: String, winner_kills: int) -> void:
	# Cierre de ciclo de 30 min: banner con el ganador y dashboard a cero.
	_countdown.add_theme_font_size_override("font_size", 40)
	_countdown.text = "ROUND WINNER: %s (%d kills)" % [winner_name, winner_kills]
	_countdown.modulate.a = 1.0
	Sfx.play("go")
	var tw := create_tween()
	tw.tween_interval(4.0)
	tw.tween_property(_countdown, "modulate:a", 0.0, 0.6)
	tw.tween_callback(func():
		_countdown.text = ""
		_countdown.modulate.a = 1.0
		_countdown.add_theme_font_size_override("font_size", 84))

func _on_countdown(seconds: float) -> void:
	_run_countdown(int(round(seconds)))

func _run_countdown(n: int) -> void:
	if not is_instance_valid(_countdown) or not is_inside_tree():
		return
	if n <= 0:
		_countdown.text = "GO!"
		Sfx.play("go")
		var tw := create_tween()
		tw.tween_interval(0.7)
		tw.tween_property(_countdown, "modulate:a", 0.0, 0.4)
		tw.tween_callback(func():
			_countdown.text = ""
			_countdown.modulate.a = 1.0)
		return
	_countdown.modulate.a = 1.0
	_countdown.text = str(n)
	Sfx.play("count")
	get_tree().create_timer(1.0).timeout.connect(func(): _run_countdown(n - 1))

# HOOKS que llama NetPlayer local

func update_health_fx(h: int, max_h: int) -> void:
	var frac := float(h) / float(max_h)
	_vignette.color.a = 0.0 if frac > 0.4 else (1.0 - frac / 0.4) * 0.38

var _current_weapon := 1
var _unlocked_slots: Array[bool] = []
var _click_hint: Label

func set_weapon_index(index: int) -> void:
	_current_weapon = index
	_refresh_weapon_bar()

## Las armas bloqueadas (pads del mapa que todavía no agarraste) se ven apagadas.
func set_slots_unlocked(unlocked: Array) -> void:
	_unlocked_slots.clear()
	for u in unlocked:
		_unlocked_slots.append(bool(u))
	_refresh_weapon_bar()

func _refresh_weapon_bar() -> void:
	for i in _weapon_slots.size():
		var locked: bool = i < _unlocked_slots.size() and not _unlocked_slots[i]
		if locked:
			_weapon_slots[i].add_theme_color_override("font_color", Color(1, 1, 1, 0.13))
			_weapon_slots[i].add_theme_font_size_override("font_size", 14)
		elif i == _current_weapon:
			_weapon_slots[i].add_theme_color_override("font_color", GOLD)
			_weapon_slots[i].add_theme_font_size_override("font_size", 16)
		else:
			_weapon_slots[i].add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
			_weapon_slots[i].add_theme_font_size_override("font_size", 14)

func show_kill_popup() -> void:
	_kill_popup.modulate.a = 1.0
	_kill_popup.scale = Vector2(1.3, 1.3)
	_kill_popup.pivot_offset = _kill_popup.size / 2
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_kill_popup, "scale", Vector2.ONE, 0.15)
	tw.chain().tween_interval(0.6)
	tw.chain().tween_property(_kill_popup, "modulate:a", 0.0, 0.35)

func show_pickup(text: String) -> void:
	_pickup_label.text = text
	_pickup_label.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(0.9)
	tw.tween_property(_pickup_label, "modulate:a", 0.0, 0.5)

func flash_damage() -> void:
	_damage_rect.color.a = 0.35
	var tw := create_tween()
	tw.tween_property(_damage_rect, "color:a", 0.0, 0.4)

func show_hitmarker(headshot := false) -> void:
	var col := Color(1.0, 0.25, 0.2) if headshot else Color(1, 1, 1)
	_hitmarker.add_theme_font_size_override("font_size", 42 if headshot else 30)
	_hitmarker.add_theme_color_override("font_color", col)
	var tw := create_tween()
	tw.tween_interval(0.08)
	tw.tween_method(func(a: float):
		_hitmarker.add_theme_color_override("font_color", Color(col.r, col.g, col.b, a)),
		1.0, 0.0, 0.25)

func show_death(killer_name: String, seconds: float) -> void:
	_death_label.text = "KILLED BY %s" % killer_name.to_upper()
	_death_left = seconds
	_death_panel.visible = true

func hide_death() -> void:
	_death_panel.visible = false
