# Arena.gd
# Mapa free-for-all. La geometría se genera acá (misma en todos los peers);
# los jugadores los spawnea SOLO el server via MultiplayerSpawner cuando
# todos los peers avisaron que la escena cargó.
extends Node3D

const PLAYER_SCENE := preload("res://Actors/Player/NetPlayer.tscn")
const HUD_SCENE := preload("res://UI/HUD/HUD.tscn")
const MATCH_HUD := preload("res://UI/HUD/MatchHUD.gd")

const SPAWN_POINTS: Array[Vector3] = [
	Vector3(-16, 1.2, -16), Vector3(16, 1.2, -16),
	Vector3(-16, 1.2, 16), Vector3(16, 1.2, 16),
	Vector3(0, 1.2, -18), Vector3(0, 1.2, 18),
	Vector3(-18, 1.2, 0), Vector3(18, 1.2, 0),
	Vector3(0, 5.2, 0),
]

# Pickups (server-authoritative). Tipos: "ammo", "weapon" (desbloquea el
# arma del pad; arrancás solo con cuchillo+pistola), "medkit" (+40 HP).
const PICKUPS: Array[Dictionary] = [
	{"type": "ammo", "pos": Vector3(-13, 0.5, 13)}, # adentro de los edificios
	{"type": "ammo", "pos": Vector3(13, 0.5, -13)},
	{"type": "ammo", "pos": Vector3(-19.5, 0.5, 0)},
	{"type": "ammo", "pos": Vector3(19.5, 0.5, 0)},
	{"type": "ammo", "pos": Vector3(0, 4.6, 0)}, # plataforma central
	{"type": "ammo", "pos": Vector3(13, 4.0, -13)}, # techo (recompensa por subir)
	{"type": "medkit", "pos": Vector3(10, 0.5, 16)},
	{"type": "medkit", "pos": Vector3(-10, 0.5, -16)},
	{"type": "medkit", "pos": Vector3(-8, 0.5, -3)},
	{"type": "medkit", "pos": Vector3(8, 0.5, 3)},
	{"type": "medkit", "pos": Vector3(-18, 2.7, -18)}, # plataforma esquina
]
const PICKUP_RESPAWN_SECONDS := 20.0
const AMMO_RESPAWN_SECONDS := 15.0
const PICKUP_DIST := 1.6
const MEDKIT_HEAL := 40

var _ammo_boxes: Array[Node3D] = []
var _box_active: Array[bool] = []

# Los jugadores se replican con MultiplayerSpawner (handshake nativo de
# Godot). Para el drop-in, los clientes se conectan DESPUÉS de cargar esta
# escena (Net.pending_join): así el spawner ya existe cuando el server les
# manda el estado de la partida en curso al conectar.
var _initialized := false
var _countdown_done := false

@onready var players_root: Node3D = $Players
@onready var spawner: MultiplayerSpawner = $Spawner

func _ready() -> void:
	_build_environment()
	_build_geometry()
	_build_ammo_boxes()
	# El server dedicado (headless) no tiene jugador propio: sin HUD.
	if not Net.dedicated:
		var hud := HUD_SCENE.instantiate()
		add_child(hud)
		var match_hud: CanvasLayer = MATCH_HUD.new()
		add_child(match_hud)
	spawner.spawn_function = _spawn_player
	if Net.is_session_server():
		Net.players_changed.connect(_reconcile_players)
	Net.session_closed.connect(_on_session_lost)
	if not Net.session_active() and not Net.pending_join.is_empty():
		# Cliente entrando a un server remoto: pantalla de carga + conectar.
		_build_connect_overlay()
		Net.connecting_changed.connect(_on_connecting)
		var addr := Net.pending_join
		Net.pending_join = ""
		var err := Net.join(addr)
		if not err.is_empty():
			_fallback_offline()
	else:
		# Ya hay sesión (host local / práctica offline): arrancar directo.
		Net.notify_arena_ready.call_deferred()

# Pantalla de carga estilo juego real mientras conecta al server.
var _connect_overlay: Control
var _connect_label: Label
var _connect_sub: Label
var _offline_btn: Button
var _connect_started_at := 0.0

const AUTO_OFFLINE_AFTER := 8.0 # si el server no conecta en 8s, jugar offline

func _build_connect_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	_connect_overlay = ColorRect.new()
	_connect_overlay.color = Color(0.03, 0.035, 0.05, 1.0)
	_connect_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_connect_overlay)
	var font := load("res://UI/Share_Tech_Mono_Font/ShareTechMono-Regular.ttf")
	# Todo apilado y centrado con un VBox (sin pelear con anchors).
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 22)
	_connect_overlay.add_child(vb)
	var title := Label.new()
	title.add_theme_font_override("font", font)
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", Color(0.953, 0.729, 0.184))
	title.text = "CZ SHOOTER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	_connect_label = Label.new()
	_connect_label.add_theme_font_override("font", font)
	_connect_label.add_theme_font_size_override("font_size", 22)
	_connect_label.text = "CONNECTING TO SERVER..."
	_connect_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_connect_label)
	_connect_sub = Label.new()
	_connect_sub.add_theme_font_override("font", font)
	_connect_sub.add_theme_font_size_override("font_size", 15)
	_connect_sub.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	_connect_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_connect_sub.text = ""
	vb.add_child(_connect_sub)
	_offline_btn = Button.new()
	_offline_btn.add_theme_font_override("font", font)
	_offline_btn.add_theme_font_size_override("font_size", 20)
	_offline_btn.text = "▶  PLAY NOW"
	_offline_btn.custom_minimum_size = Vector2(280, 48)
	_offline_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_offline_btn.pressed.connect(_fallback_offline)
	vb.add_child(_offline_btn)
	# Link a X / Twitter en la pantalla de carga.
	var x_btn := Button.new()
	x_btn.add_theme_font_override("font", font)
	x_btn.add_theme_font_size_override("font_size", 15)
	x_btn.flat = true
	x_btn.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	x_btn.text = "X · @CZshooterbnb"
	x_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	x_btn.pressed.connect(func(): OS.shell_open("https://x.com/CZshooterbnb"))
	vb.add_child(x_btn)
	_connect_started_at = Time.get_ticks_msec() / 1000.0

func _on_connecting(message: String) -> void:
	if _connect_overlay == null:
		return
	if message.is_empty():
		# Conectó: mostrar pasos finales y ocultar la pantalla de carga.
		_connect_label.text = "JOINING MATCH..."
		_connect_sub.text = ""
		_offline_btn.visible = false
		var tw := create_tween()
		tw.tween_interval(0.5)
		tw.tween_property(_connect_overlay, "modulate:a", 0.0, 0.4)
		tw.tween_callback(func():
			if is_instance_valid(_connect_overlay):
				_connect_overlay.visible = false)
		return
	var elapsed := Time.get_ticks_msec() / 1000.0 - _connect_started_at
	# Si el server tarda (dormido en Render), caemos a jugar YA automáticamente.
	if elapsed > AUTO_OFFLINE_AFTER:
		_fallback_offline()
		return
	_connect_label.text = "LOADING MATCH..."
	_connect_sub.text = "starting in %d..." % int(ceil(AUTO_OFFLINE_AFTER - elapsed))

var _fell_back := false

func _fallback_offline() -> void:
	# Jugar YA sin server: partida local con jugadores simulados.
	if _fell_back:
		return
	_fell_back = true
	Net.leave()
	Net.host_offline()
	Net.begin_infinite()
	_on_connecting("") # ocultar la pantalla de carga

func _on_session_lost(_reason: String) -> void:
	# Si el server no respondió, en vez de volver al menú arrancamos offline
	# para que SIEMPRE se pueda jugar.
	if is_inside_tree() and not Net.session_active():
		_fallback_offline()

func _physics_process(_delta: float) -> void:
	if multiplayer.is_server():
		_srv_check_ammo_pickups()

# PICKUPS (munición / armas / medkits)

func _build_ammo_boxes() -> void:
	var ammo_scene: PackedScene = load("res://Assets/Guns/ammobox_low.glb")
	for i in PICKUPS.size():
		var spec := PICKUPS[i]
		var holder := Node3D.new()
		add_child(holder)
		holder.global_position = spec["pos"]
		match String(spec["type"]):
			"ammo":
				if ammo_scene:
					var box: Node3D = ammo_scene.instantiate()
					box.scale = Vector3.ONE * 2.4
					box.position.y = 0.25
					holder.add_child(box)
			"weapon":
				var def := WeaponDefs.get_def(int(spec["windex"]))
				var gun_scene: PackedScene = load(String(def["model"]))
				if gun_scene:
					var gun: Node3D = gun_scene.instantiate()
					gun.scale = Vector3.ONE * float(def.get("scale", 1.0)) * 1.4
					gun.position.y = 0.75
					holder.add_child(gun)
				_pad_base(holder)
			"medkit":
				_medkit_visual(holder)
		_ammo_boxes.append(holder)
		_box_active.append(true)
		# Giro constante para que se note que es un pickup.
		var tw := holder.create_tween().set_loops()
		tw.tween_property(holder, "rotation:y", TAU, 4.0).as_relative()

## Base circular para los pads de armas.
func _pad_base(holder: Node3D) -> void:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.8
	cyl.bottom_radius = 0.9
	cyl.height = 0.12
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.75, 0.2)
	mat.emission_enabled = true
	mat.emission = Color(0.9, 0.7, 0.15)
	mat.emission_energy_multiplier = 0.6
	cyl.material = mat
	mi.mesh = cyl
	mi.position.y = 0.06
	holder.add_child(mi)

func _medkit_visual(holder: Node3D) -> void:
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.55, 0.35, 0.55)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.95, 0.95)
	box.material = mat
	body.mesh = box
	body.position.y = 0.35
	holder.add_child(body)
	var cross_mat := StandardMaterial3D.new()
	cross_mat.albedo_color = Color(0.85, 0.1, 0.1)
	cross_mat.emission_enabled = true
	cross_mat.emission = Color(0.7, 0.05, 0.05)
	for size in [Vector3(0.4, 0.36, 0.14), Vector3(0.14, 0.36, 0.4)]:
		var c := MeshInstance3D.new()
		var cb := BoxMesh.new()
		cb.size = size
		cb.material = cross_mat
		c.mesh = cb
		c.position.y = 0.35
		holder.add_child(c)

func _srv_check_ammo_pickups() -> void:
	for i in _ammo_boxes.size():
		if not _box_active[i]:
			continue
		var spec := PICKUPS[i]
		for p in get_tree().get_nodes_in_group("net_players"):
			var np := p as NetPlayer
			if np.is_bot or np.is_dead:
				continue # los bots no usan pickups
			if np.global_position.distance_to(spec["pos"]) >= PICKUP_DIST:
				continue
			# Reglas por tipo: no consumir si no te aporta nada.
			match String(spec["type"]):
				"weapon":
					if np.srv_has_weapon(int(spec["windex"])):
						continue
				"medkit":
					if np._srv_health >= NetPlayer.MAX_HEALTH:
						continue
			_srv_consume_box(i, np)
			break

func _srv_consume_box(i: int, np: NetPlayer) -> void:
	var spec := PICKUPS[i]
	_set_box_active(i, false)
	cl_box_state.rpc(i, false)
	match String(spec["type"]):
		"ammo":
			if np.peer_id == 1:
				np.give_ammo()
			else:
				np.cl_give_ammo.rpc_id(np.peer_id)
		"weapon":
			np._srv_unlock(int(spec["windex"]))
		"medkit":
			np._srv_heal(MEDKIT_HEAL)
			if np.peer_id == 1:
				np.cl_medkit(MEDKIT_HEAL)
			else:
				np.cl_medkit.rpc_id(np.peer_id, MEDKIT_HEAL)
	var respawn := AMMO_RESPAWN_SECONDS if String(spec["type"]) == "ammo" else PICKUP_RESPAWN_SECONDS
	get_tree().create_timer(respawn).timeout.connect(func():
		if is_inside_tree():
			_set_box_active(i, true)
			cl_box_state.rpc(i, true))

@rpc("authority", "reliable")
func cl_box_state(i: int, active: bool) -> void:
	_set_box_active(i, active)

func _set_box_active(i: int, active: bool) -> void:
	if i < 0 or i >= _ammo_boxes.size():
		return
	_box_active[i] = active
	_ammo_boxes[i].visible = active

## Llamado por Net en el SERVER cuando un peer (o el propio server) tiene
## la Arena cargada. Maneja tanto el arranque como el drop-in a mitad de
## partida: los jugadores ya spawneados le llegan al peer nuevo por el
## flush automático del MultiplayerSpawner al conectarse.
func on_peer_ready(_peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	_initialized = true
	_reconcile_players()
	if not _countdown_done:
		_countdown_done = true
		Net.begin_countdown()

## SERVER: iguala los nodos spawneados con Net.players (altas y bajas de
## humanos y bots, incluso a mitad de partida).
func _reconcile_players() -> void:
	if not multiplayer.is_server() or not _initialized:
		return
	for id in Net.players:
		if not players_root.has_node(_node_name(id)):
			spawner.spawn({
				"id": id,
				"name": Net.players[id]["name"],
				"character": Net.players[id]["character"],
				"bot": bool(Net.players[id].get("bot", false)),
				"pos": pick_spawn_point(),
			})
	for child in players_root.get_children():
		if child is NetPlayer and not Net.players.has(child.peer_id):
			child.queue_free() # el spawner replica la baja

func _node_name(id: int) -> String:
	return ("P%d" % id) if id > 0 else ("B%d" % absi(id))

func _spawn_player(data: Dictionary) -> Node:
	var id := int(data["id"])
	var p: NetPlayer = PLAYER_SCENE.instantiate()
	p.name = _node_name(id)
	p.peer_id = id
	p.display_name = String(data["name"])
	p.character_id = String(data["character"])
	p.is_bot = bool(data.get("bot", false))
	p.position = data["pos"]
	p.sync_pos = data["pos"]
	# El movimiento lo replica el peer dueño (o el server, si es bot); el
	# nodo raíz queda con autoridad del server (RPCs de combate = solo server).
	if id > 0:
		p.get_node("Sync").set_multiplayer_authority(id)
	return p

func pick_spawn_point() -> Vector3:
	# Elegí el punto más lejos del enemigo vivo más cercano.
	var alive: Array[Vector3] = []
	for p in get_tree().get_nodes_in_group("net_players"):
		if not p.is_dead:
			alive.append(p.global_position)
	var best := SPAWN_POINTS[randi() % SPAWN_POINTS.size()]
	var best_score := -1.0
	for point in SPAWN_POINTS:
		var nearest := INF
		for a in alive:
			nearest = minf(nearest, point.distance_to(a))
		if alive.is_empty():
			nearest = randf() * 100.0
		if nearest > best_score:
			best_score = nearest
			best = point
	return best

# GEOMETRÍA

func _build_environment() -> void:
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.25, 0.45, 0.66)
	sky_mat.sky_horizon_color = Color(0.72, 0.68, 0.6)
	sky_mat.ground_bottom_color = Color(0.2, 0.17, 0.13)
	sky_mat.ground_horizon_color = Color(0.72, 0.68, 0.6)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.95
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	env.fog_enabled = true
	env.fog_density = 0.0012
	env.fog_light_color = Color(0.62, 0.58, 0.52)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -30, 0)
	sun.light_energy = 0.95
	sun.light_color = Color(1.0, 0.95, 0.85)
	sun.shadow_enabled = GameSettings.shadows_enabled()
	add_child(sun)

const COL_FLOOR := Color(0.38, 0.33, 0.26)
const COL_WALL := Color(0.42, 0.38, 0.33)
const COL_PLATFORM := Color(0.35, 0.37, 0.4)
const COL_RAMP := Color(0.45, 0.42, 0.38)

const KIT := "res://Assets/MapKit/"
var _kit_material: StandardMaterial3D

func _build_geometry() -> void:
	# Material del kit (el Read Me del pack recomienda roughness 1 / metallic 0).
	_kit_material = StandardMaterial3D.new()
	_kit_material.albedo_texture = load(KIT + "FPSLite_Texture_01.png")
	_kit_material.roughness = 1.0
	_kit_material.metallic = 0.0

	# Piso 44x44 + anillo de contención invisible (garantiza que nadie se caiga
	# del mapa aunque las paredes del kit dejen huecos).
	_box(Vector3(0, -0.5, 0), Vector3(44, 1, 44), COL_FLOOR)
	for wall_col in [
		[Vector3(0, 6, -22.3), Vector3(46, 14, 1)],
		[Vector3(0, 6, 22.3), Vector3(46, 14, 1)],
		[Vector3(-22.3, 6, 0), Vector3(1, 14, 46)],
		[Vector3(22.3, 6, 0), Vector3(1, 14, 46)],
	]:
		_box(wall_col[0], wall_col[1], COL_WALL, false)

	# Perímetro visual con las paredes del kit (Wall_03: 10m x 5m).
	for x in [-15.0, -5.0, 5.0, 15.0]:
		_place("Wall_03.fbx", Vector3(x, 0, -21.7), 0.0)
		_place("Wall_03.fbx", Vector3(x, 0, 21.7), 0.0)
		_place("Wall_03.fbx", Vector3(-21.7, 0, x), 90.0)
		_place("Wall_03.fbx", Vector3(21.7, 0, x), 90.0)
	for cx in [-21.4, 21.4]:
		for cz in [-21.4, 21.4]:
			_place("WallPart_01.fbx", Vector3(cx, 0, cz), 0.0)

	# Edificios del kit en dos esquinas opuestas.
	_place("Building_01.fbx", Vector3(-13, 0, 13), 180.0)
	_place("Building_01.fbx", Vector3(13, 0, -13), 0.0)

	# Plataforma central elevada con rampas (verticalidad).
	_box(Vector3(0, 3.8, 0), Vector3(10, 0.6, 10), COL_PLATFORM)
	_box(Vector3(0, 1.9, 0), Vector3(2.2, 3.8, 2.2), COL_PLATFORM)
	_ramp(Vector3(0, 1.85, 8.6), Vector3(4, 0.5, 9), -24.0, COL_RAMP)
	_ramp(Vector3(0, 1.85, -8.6), Vector3(4, 0.5, 9), 24.0, COL_RAMP)

	# Coberturas con cajas del kit.
	for crate in [
		Vector3(-10, 0, -6), Vector3(-11, 0, 7), Vector3(9, 0, -9),
		Vector3(12, 0, 5), Vector3(-5, 0, 13), Vector3(6, 0, -14),
		Vector3(-14, 0, -13), Vector3(14, 0, 14),
	]:
		_place("Box_01.fbx", crate + Vector3(0, 1.0, 0), randf() * 360.0, 2.6)
		_place("Box_01.fbx", crate + Vector3(1.5, 0.55, 0.9), randf() * 360.0, 1.5)
		_place("Jug_01.fbx", crate + Vector3(-0.4, 1.95, 0.2), randf() * 360.0, 1.0)
	# Muretes intermedios del kit como cobertura media.
	_place("Wall_01.fbx", Vector3(-8, 0, 0), 90.0)
	_place("Wall_01.fbx", Vector3(8, 0, 0), 90.0)
	_place("Wall_02.fbx", Vector3(0, 0, -12), 0.0)
	_place("Wall_02.fbx", Vector3(0, 0, 12), 0.0)
	for i in 5:
		_place("Brick_01.fbx", Vector3(-7.8, 0.11 + 0.22 * i, -1.5 + 0.4 * i), randf_range(-20, 20))

	# Plataformas en esquinas libres.
	_box(Vector3(-18, 2.2, -18), Vector3(7, 0.5, 7), COL_PLATFORM)
	_ramp(Vector3(-13.8, 1.05, -18), Vector3(6, 0.4, 3.4), 0.0, COL_RAMP, 24.0)
	_box(Vector3(18, 2.2, 18), Vector3(7, 0.5, 7), COL_PLATFORM)
	_ramp(Vector3(13.8, 1.05, 18), Vector3(6, 0.4, 3.4), 0.0, COL_RAMP, -24.0)
	_place("WoodPlank_01.fbx", Vector3(-16.5, 2.5, -18), 0.0, 2.0)
	_place("WoodPlank_02.fbx", Vector3(18, 2.5, 16.5), 90.0, 2.0)
	# Escaleras de cajas a los techos de los edificios (hay munición arriba).
	_box(Vector3(8.9, 0.6, -13), Vector3(1.8, 1.2, 1.8), COL_PLATFORM)
	_box(Vector3(8.9, 1.2, -15.0), Vector3(1.8, 2.4, 1.8), COL_PLATFORM)
	_box(Vector3(-8.9, 0.6, 13), Vector3(1.8, 1.2, 1.8), COL_PLATFORM)
	_box(Vector3(-8.9, 1.2, 15.0), Vector3(1.8, 2.4, 1.8), COL_PLATFORM)
	_decorate()

## Detalle visual: postes de luz, pilas de ladrillos, tablones apoyados,
## bidones y guardas emisivas. Nada de esto tiene colisión.
func _decorate() -> void:
	# Postes de luz cálida alrededor del centro.
	for post_pos in [
		Vector3(-10.5, 0, -10.5), Vector3(10.5, 0, 10.5),
		Vector3(-10.5, 0, 10.5), Vector3(10.5, 0, -10.5),
		Vector3(0, 0, -19.5), Vector3(0, 0, 19.5),
	]:
		_light_post(post_pos)
	# Guarda emisiva dorada en el borde de la plataforma central.
	var trim_mat := StandardMaterial3D.new()
	trim_mat.albedo_color = Color(0.95, 0.75, 0.2)
	trim_mat.emission_enabled = true
	trim_mat.emission = Color(0.9, 0.65, 0.15)
	trim_mat.emission_energy_multiplier = 0.8
	for trim in [
		[Vector3(0, 4.13, 5.0), Vector3(10.2, 0.08, 0.12)],
		[Vector3(0, 4.13, -5.0), Vector3(10.2, 0.08, 0.12)],
		[Vector3(5.0, 4.13, 0), Vector3(0.12, 0.08, 10.2)],
		[Vector3(-5.0, 4.13, 0), Vector3(0.12, 0.08, 10.2)],
	]:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = trim[1]
		bm.material = trim_mat
		mi.mesh = bm
		add_child(mi)
		mi.position = trim[0]
	# Pilas de ladrillos.
	for pile in [Vector3(-5, 0, -9), Vector3(11, 0, -3), Vector3(-12, 0, 3), Vector3(4, 0, 15), Vector3(16, 0, -8)]:
		for i in 5:
			_place("Brick_01.fbx", pile + Vector3(randf_range(-0.4, 0.4), 0.11 + 0.21 * (i / 2), randf_range(-0.4, 0.4)), randf() * 360.0, 1.0, false)
	# Bidones y tablones apoyados contra coberturas.
	for jug in [Vector3(-9.4, 0, -5.2), Vector3(12.8, 0, 5.9), Vector3(-4.2, 0, 13.8), Vector3(7.1, 0, -13.3), Vector3(-14.8, 0, -12.2)]:
		_place("Jug_02.fbx" if randf() > 0.5 else "Jug_01.fbx", jug, randf() * 360.0, 1.1, false)
	for plank in [
		[Vector3(-10.9, 0.55, -6.9), 20.0], [Vector3(9.8, 0.55, -8.2), 110.0],
		[Vector3(11.2, 0.55, 5.9), 200.0], [Vector3(-5.9, 0.55, 12.2), 290.0],
	]:
		_place("WoodPlank_03.fbx", plank[0], plank[1], 1.6, false)

## Poste con lámpara emisiva y luz omni cálida.
func _light_post(pos: Vector3) -> void:
	var pole := MeshInstance3D.new()
	var pole_mesh := BoxMesh.new()
	pole_mesh.size = Vector3(0.14, 3.4, 0.14)
	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.16, 0.16, 0.18)
	pole_mesh.material = pole_mat
	pole.mesh = pole_mesh
	add_child(pole)
	pole.position = pos + Vector3(0, 1.7, 0)
	var lamp := MeshInstance3D.new()
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3(0.32, 0.24, 0.32)
	var lamp_mat := StandardMaterial3D.new()
	lamp_mat.albedo_color = Color(1.0, 0.85, 0.55)
	lamp_mat.emission_enabled = true
	lamp_mat.emission = Color(1.0, 0.8, 0.45)
	lamp_mat.emission_energy_multiplier = 1.6
	lamp_mesh.material = lamp_mat
	lamp.mesh = lamp_mesh
	add_child(lamp)
	lamp.position = pos + Vector3(0, 3.5, 0)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.85, 0.55)
	light.light_energy = 1.1
	light.omni_range = 9.0
	add_child(light)
	light.position = pos + Vector3(0, 3.3, 0)

## Instancia una pieza del kit con colisión trimesh y el material del pack.
## collide=false para decoración pura (más barato y sin trabas raras).
func _place(piece: String, pos: Vector3, rot_y_deg: float, scale := 1.0, collide := true) -> void:
	var scene: PackedScene = load(KIT + piece)
	if scene == null:
		push_warning("[Arena] No se pudo cargar la pieza del kit: " + piece)
		return
	var inst: Node3D = scene.instantiate()
	var body := StaticBody3D.new()
	body.position = pos
	body.rotation_degrees = Vector3(0, rot_y_deg, 0)
	body.scale = Vector3.ONE * scale
	body.add_child(inst)
	for node in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		mi.material_override = _kit_material
		if collide and mi.mesh:
			var col := CollisionShape3D.new()
			col.shape = mi.mesh.create_trimesh_shape()
			col.transform = _relative_transform(mi, inst)
			body.add_child(col)
	add_child(body)

func _relative_transform(node: Node3D, ancestor: Node3D) -> Transform3D:
	var xform := node.transform
	var p := node.get_parent()
	while p != null and p != ancestor and p is Node3D:
		xform = (p as Node3D).transform * xform
		p = p.get_parent()
	return xform

func _box(pos: Vector3, size: Vector3, color: Color, visible_mesh := true) -> void:
	var body := StaticBody3D.new()
	body.position = pos
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	body.add_child(shape)
	if visible_mesh:
		var mesh := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = size
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.9
		box_mesh.material = mat
		mesh.mesh = box_mesh
		body.add_child(mesh)
	add_child(body)

func _ramp(pos: Vector3, size: Vector3, x_deg: float, color: Color, z_deg := 0.0) -> void:
	var body := StaticBody3D.new()
	body.position = pos
	body.rotation_degrees = Vector3(x_deg, 0, z_deg)
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	box_mesh.material = mat
	mesh.mesh = box_mesh
	body.add_child(mesh)
	add_child(body)
