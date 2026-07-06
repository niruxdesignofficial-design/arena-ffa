# Settings.gd (autoload "GameSettings")
# Ajustes persistidos localmente en user://settings.cfg:
# sensibilidad, volumen, calidad gráfica, controles y perfil del jugador.
extends Node

signal changed

const PATH := "user://settings.cfg"
const BASE_MOUSE_SENS := 0.002

# Acciones que se pueden reasignar desde Ajustes (solo teclas).
const REBINDABLE: Array[String] = [
	"move_forward", "move_back", "move_left", "move_right",
	"jump", "sprint", "crouch", "reload", "scoreboard",
]
const ACTION_LABELS := {
	"move_forward": "Forward",
	"move_back": "Back",
	"move_left": "Left",
	"move_right": "Right",
	"jump": "Jump",
	"sprint": "Sprint",
	"crouch": "Crouch",
	"reload": "Reload",
	"scoreboard": "Scoreboard",
}

var mouse_sens_mult := 1.0 # 0.2 .. 3.0
var volume := 80.0 # 0 .. 100
var quality := 1 # 0 Baja, 1 Media, 2 Alta
var fov := 90.0 # 70 .. 110
var show_stats := true # ping/FPS en el HUD
var player_name := "Player"
var character_id := ""
var last_server := "" # última dirección usada en JOIN (ej. wss://xxx.onrender.com)
var binds := {} # action -> physical_keycode (int)

func _ready() -> void:
	load_settings()
	apply_all()

func mouse_sensitivity() -> float:
	return BASE_MOUSE_SENS * mouse_sens_mult

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	mouse_sens_mult = float(cfg.get_value("input", "mouse_sens_mult", 1.0))
	volume = float(cfg.get_value("audio", "volume", 80.0))
	quality = int(cfg.get_value("video", "quality", 1))
	fov = float(cfg.get_value("video", "fov", 90.0))
	show_stats = bool(cfg.get_value("video", "show_stats", true))
	player_name = String(cfg.get_value("profile", "name", "Player"))
	character_id = String(cfg.get_value("profile", "character", ""))
	last_server = String(cfg.get_value("profile", "last_server", ""))
	for action in REBINDABLE:
		var key := int(cfg.get_value("binds", action, 0))
		if key != 0:
			binds[action] = key

func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("input", "mouse_sens_mult", mouse_sens_mult)
	cfg.set_value("audio", "volume", volume)
	cfg.set_value("video", "quality", quality)
	cfg.set_value("video", "fov", fov)
	cfg.set_value("video", "show_stats", show_stats)
	cfg.set_value("profile", "name", player_name)
	cfg.set_value("profile", "character", character_id)
	cfg.set_value("profile", "last_server", last_server)
	for action in binds.keys():
		cfg.set_value("binds", action, binds[action])
	cfg.save(PATH)

func apply_all() -> void:
	apply_volume()
	apply_quality()
	apply_binds()
	changed.emit()

func apply_volume() -> void:
	var master := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(master, linear_to_db(clampf(volume / 100.0, 0.0001, 1.0)))
	AudioServer.set_bus_mute(master, volume <= 0.5)

func apply_quality() -> void:
	var root := get_tree().root
	match quality:
		0:
			root.msaa_3d = Viewport.MSAA_DISABLED
			root.scaling_3d_scale = 0.75
		1:
			root.msaa_3d = Viewport.MSAA_2X
			root.scaling_3d_scale = 1.0
		_:
			root.msaa_3d = Viewport.MSAA_4X
			root.scaling_3d_scale = 1.0

func shadows_enabled() -> bool:
	return quality >= 1

func apply_binds() -> void:
	for action in binds.keys():
		if not InputMap.has_action(action):
			continue
		InputMap.action_erase_events(action)
		var ev := InputEventKey.new()
		ev.physical_keycode = binds[action] as Key
		InputMap.action_add_event(action, ev)

func rebind(action: String, physical_keycode: int) -> void:
	binds[action] = physical_keycode
	apply_binds()
	save_settings()

func bind_label(action: String) -> String:
	var events := InputMap.action_get_events(action)
	for ev in events:
		if ev is InputEventKey:
			var code: Key = ev.physical_keycode if ev.physical_keycode != KEY_NONE else ev.keycode
			return OS.get_keycode_string(code)
		if ev is InputEventMouseButton:
			return "Mouse %d" % ev.button_index
	return "—"
