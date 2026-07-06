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
	{"type": "weapon", "windex": 2, "pos": Vector3(-8, 0.5, -3)}, # MAC-10
	{"type": "weapon", "windex": 3, "pos": Vector3(8, 0.5, 3)}, # Shotgun
	{"type": "weapon", "windex": 4, "pos": Vector3(0, 4.6, 0)}, # AK-47 (plataforma)
	{"type": "weapon", "windex": 5, "pos": Vector3(13, 4.0, -13)}, # AWP (techo)
	{"type": "medkit", "pos": Vector3(10, 0.5, 16)},
	{"type": "medkit", "pos": Vector3(-10, 0.5, -16)},
	{"type": "medkit", "pos": Vector3(-18, 2.7, -18)}, # plataforma esquina
]
const PICKUP_RESPAWN_SECONDS := 20.0
const AMMO_RESPAWN_SECONDS := 15.0
const PICKUP_DIST := 1.6
const MEDKIT_HEAL := 40

var _ammo_boxes: Array[Node3D] = []
var _box_active: Array[bool] = []

@onready var spawner: MultiplayerSpawner = $Spawner
@onready var players_root: Node3D = $Players

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
		Net.players_changed.connect(_despawn_missing)
	Net.notify_arena_ready.call_deferred()

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

## Llamado por Net (solo en el server) cuando todos los peers cargaron.
func spawn_all_players() -> void:
	if not multiplayer.is_server():
		return
	var i := 0
	for id in Net.players:
		var entry: Dictionary = Net.players[id]
		spawner.spawn({
			"id": id,
			"name": entry["name"],
			"character": entry["character"],
			"bot": bool(entry.get("bot", false)),
			"pos": SPAWN_POINTS[i % SPAWN_POINTS.size()],
		})
		i += 1

func _spawn_player(data: Dictionary) -> Node:
	var p: NetPlayer = PLAYER_SCENE.instantiate()
	var id := int(data["id"])
	p.name = ("P%d" % id) if id > 0 else ("B%d" % absi(id))
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

func _despawn_missing() -> void:
	if not multiplayer.is_server():
		return
	for child in players_root.get_children():
		if child is NetPlayer and not Net.players.has(child.peer_id):
			child.queue_free()

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
	sun.light_energy = 0.9
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

## Instancia una pieza del kit con colisión trimesh y el material del pack.
func _place(piece: String, pos: Vector3, rot_y_deg: float, scale := 1.0) -> void:
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
		if mi.mesh:
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
