# NetPlayer.gd
# Jugador multijugador (humano o BOT). El peer dueño controla movimiento y
# apuntado — replicados como sync_pos/sync_rot_y e interpolados en los demás
# peers —; el SERVER es el único que resuelve disparos, daño, headshots,
# muertes y respawn. El cliente jamás decide una kill: solo pide disparar
# (srv_fire) y recibe el resultado. Los bots los mueve y dispara el server.
class_name NetPlayer
extends CharacterBody3D

enum Anim { IDLE, WALK, RUN, AIR, DEAD }

const MAX_HEALTH := 100
const WALK_SPEED := 6.0
const SPRINT_SPEED := 8.8
const CROUCH_SPEED := 2.8
const JUMP_STRENGTH := 5.4
const GRAVITY := 9.8
const RESPAWN_SECONDS := 3.0
const SPAWN_PROTECT_SECONDS := 1.5
const HEADSHOT_HEIGHT := 1.30
const HEADSHOT_MULT := 1.5
const INTERP_SPEED := 16.0
const SNAP_DISTANCE := 6.0

# Datos de spawn (los setea la spawn_function de la Arena en todos los peers).
var peer_id := 1
var display_name := "Jugador"
var character_id := ""
var is_bot := false

# Replicados por el Synchronizer (autoridad = peer dueño; server para bots).
var sync_pos := Vector3.ZERO
var sync_rot_y := 0.0
var anim_state: int = Anim.IDLE
var weapon_index: int = 1

# Estado local por peer.
var is_dead := false
var health := MAX_HEALTH

# Estado que SOLO el server usa.
var _srv_health := MAX_HEALTH
var _srv_dead := false
var _srv_last_fire := -10.0
var _srv_protect_until := 0.0
var _srv_unlocked: Array[bool] = []
var _srv_prev_pos := Vector3.ZERO
var _srv_speed := 0.0 # velocidad vista por el server (para dispersión al moverse)

# IA de bots (solo server). El "skill" varía por bot para que se sientan
# personas distintas: puntería, cadencia y reflejos diferentes.
var _bot_windex := 1
var _bot_target: NetPlayer
var _bot_retarget_at := 0.0
var _bot_strafe_dir := 1.0
var _bot_jitter := 2.5
var _bot_cd_mult := 1.4
var _bot_turn := 5.0
var _bot_roam := Vector3.ZERO
var _bot_roam_until := 0.0

var _is_crouching := false
var _weapons: NetWeapons
var _rig: CharacterRig
var _hand_prop: Node3D
var _hand_meshes: Array[Node3D] = []
var _aim_pose: AimPose
var _auto_seed := 0.0
var _bob_time := 0.0
var _ads := false
var _fov_kick := 0.0
var _consec_shots := 0
var _last_shot_at := -10.0
var _step_accum := 0.0
var _remote_step_timer := 0.0
var _hand_flash: Node3D
# Para el radar: último momento en que este jugador disparó (visto localmente).
var radar_ping_at := -10.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var weapon_holder: Node3D = $Head/Camera3D/WeaponHolder
@onready var rig_holder: Node3D = $RigHolder
@onready var name_tag: Label3D = $NameTag

func is_local() -> bool:
	return not is_bot and peer_id == multiplayer.get_unique_id()

func _ready() -> void:
	add_to_group("net_players")
	_build_rig()
	name_tag.text = display_name
	name_tag.modulate = CharacterLib.accent_color(character_id)
	sync_pos = global_position
	sync_rot_y = rotation.y
	Net.players_changed.connect(_refresh_crown)
	_refresh_crown()
	if is_bot:
		_bot_windex = [1, 2, 4][absi(peer_id) % 3] # pistola / MAC-10 / AK-47
		weapon_index = _bot_windex
		_auto_seed = randf() * TAU
		var rng := RandomNumberGenerator.new()
		rng.seed = absi(peer_id) * 7919
		_bot_jitter = rng.randf_range(1.2, 4.5)
		_bot_cd_mult = rng.randf_range(1.0, 2.0)
		_bot_turn = rng.randf_range(3.0, 6.5)
	elif is_local():
		camera.current = true
		camera.fov = GameSettings.fov
		rig_holder.visible = false # en primera persona no ves tu propio cuerpo
		name_tag.visible = false
		_weapons = NetWeapons.new()
		weapon_holder.add_child(_weapons)
		_weapons.ammo_changed.connect(_on_ammo_changed)
		_weapons.weapon_changed.connect(_on_weapon_changed)
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		_init_hud.call_deferred()
		_auto_seed = randf() * TAU
	if multiplayer.is_server():
		_srv_protect_until = _now() + SPAWN_PROTECT_SECONDS
		_srv_reset_loadout()
	if _weapons:
		_weapons.loadout_changed.connect(_sync_hud_loadout)
		_sync_hud_loadout.call_deferred()

func _srv_reset_loadout() -> void:
	_srv_unlocked.clear()
	for i in WeaponDefs.count():
		_srv_unlocked.append(WeaponDefs.is_starter(i))
	if is_bot:
		_srv_unlocked[_bot_windex] = true

func _sync_hud_loadout() -> void:
	if not is_local() or _weapons == null:
		return
	var mhud := get_tree().get_first_node_in_group("match-ui")
	if mhud:
		mhud.set_slots_unlocked(_weapons.unlocked)

func _refresh_crown() -> void:
	# Corona en el nametag del que va primero.
	if not is_inside_tree():
		return
	var top: int = Net.top_player_id()
	var kills: int = int(Net.players.get(peer_id, {}).get("kills", 0))
	name_tag.text = ("👑 " + display_name) if (peer_id == top and kills > 0) else display_name

func _init_hud() -> void:
	var hud := get_tree().get_first_node_in_group("game-ui")
	if hud:
		hud.update_health(health, MAX_HEALTH, false)
	if _weapons:
		_on_weapon_changed(_weapons.current_index, String(_weapons.current_def()["name"]))
		_weapons._emit_ammo()

func _build_rig() -> void:
	_rig = CharacterLib.build_rig(character_id)
	if _rig == null:
		# Nunca dejar un modelo roto en silencio: placeholder + aviso.
		push_warning("[NetPlayer] Sin rig para '%s'; se usa cápsula placeholder." % character_id)
		var mi := MeshInstance3D.new()
		var capsule := CapsuleMesh.new()
		capsule.height = 1.7
		mi.mesh = capsule
		mi.position.y = 0.85
		rig_holder.add_child(mi)
		return
	# El GLB de Meshy mira hacia +Z; el frente del juego es -Z.
	_rig.rotation_degrees.y = 180.0
	rig_holder.add_child(_rig)
	_attach_hand_prop()
	_update_hand_prop()

func _attach_hand_prop() -> void:
	# Arma visible en la mano del modelo (tercera persona).
	var skel: Skeleton3D = _rig.find_child("Skeleton3D", true, false)
	if skel == null:
		return
	var hand_idx := -1
	for i in skel.get_bone_count():
		var bname := skel.get_bone_name(i).to_lower()
		if bname.contains("hand") and (bname.contains("r") or bname.contains("right")):
			hand_idx = i
			break
	if hand_idx == -1:
		for i in skel.get_bone_count():
			if skel.get_bone_name(i).to_lower().contains("hand"):
				hand_idx = i
				break
	if hand_idx == -1:
		push_warning("[NetPlayer] El rig de '%s' no tiene hueso de mano; el arma en 3ra persona no se muestra." % character_id)
		return
	# Pose de apuntado (levanta el brazo + retroceso). Debe ir DESPUÉS del
	# AnimationPlayer en el árbol para pisar la pose de la animación.
	_aim_pose = AimPose.new()
	skel.add_child(_aim_pose)
	_aim_pose.setup(skel)
	var attach := BoneAttachment3D.new()
	attach.bone_name = skel.get_bone_name(hand_idx)
	skel.add_child(attach)
	_hand_prop = Node3D.new()
	attach.add_child(_hand_prop)
	for i in WeaponDefs.count():
		var def := WeaponDefs.get_def(i)
		var prop: Node3D
		if String(def["model"]).is_empty():
			# Cuchillo: hoja simple.
			prop = MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(0.03, 0.22, 0.05)
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.75, 0.75, 0.78)
			box.material = mat
			(prop as MeshInstance3D).mesh = box
		else:
			prop = (load(String(def["model"])) as PackedScene).instantiate()
			# Más grande en 3ra persona para que se vea claro el arma.
			prop.scale = Vector3.ONE * float(def.get("scale", 1.0)) * 1.5
			prop.rotation_degrees = Vector3(0, 90, 0)
			prop.position = Vector3(0, 0.02, -0.06)
		prop.visible = false
		_hand_prop.add_child(prop)
		_hand_meshes.append(prop)
	# Fogonazo en la mano para que los disparos ajenos se VEAN.
	_hand_flash = NetWeapons.MiniFlash.new()
	_hand_flash.position = Vector3(0, 0.25, 0)
	_hand_prop.add_child(_hand_flash)

func _update_hand_prop() -> void:
	for i in _hand_meshes.size():
		_hand_meshes[i].visible = (i == weapon_index)

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

# INPUT (solo el peer dueño)

func _input(event: InputEvent) -> void:
	if not is_local() or is_dead or AutoTest.autopilot:
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		# En el navegador el pointer lock solo se puede pedir DENTRO de un
		# gesto del usuario: capturar al hacer click sobre el juego.
		if event is InputEventMouseButton and event.is_pressed():
			var mhud := get_tree().get_first_node_in_group("match-ui")
			if mhud == null or not mhud.is_paused():
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		return
	var mhud_chat := get_tree().get_first_node_in_group("match-ui")
	if mhud_chat and mhud_chat.is_chat_open():
		return
	if event is InputEventMouseMotion:
		var sens: float = GameSettings.mouse_sensitivity()
		if _ads:
			sens *= 0.35 if _is_scoped() else 0.7
		rotate_y(-event.relative.x * sens)
		head.rotation.x = clamp(head.rotation.x - event.relative.y * sens, -PI / 2, PI / 2)
		if _weapons:
			_weapons.add_sway(event.relative)
	elif event.is_action_pressed("fire"):
		_do_fire()
	elif event.is_action_pressed("reload"):
		_weapons.start_reload()
	elif event.is_action_pressed("weapon_scroll_up"):
		_weapons.switch_next()
	elif event.is_action_pressed("weapon_scroll_down"):
		_weapons.switch_prev()
	elif event.is_action_pressed("weapon_1"):
		_weapons.switch_to(0)
	elif event.is_action_pressed("weapon_2"):
		_weapons.switch_to(1)
	elif event.is_action_pressed("weapon_3"):
		_weapons.switch_to(2)
	elif event.is_action_pressed("weapon_4"):
		_weapons.switch_to(3)
	elif event.is_action_pressed("weapon_5"):
		_weapons.switch_to(4)
	elif event.is_action_pressed("weapon_6"):
		_weapons.switch_to(5)

func _do_fire() -> void:
	if is_dead or _weapons == null or Net.fire_locked():
		return
	if not _weapons.try_fire():
		return
	var def := _weapons.current_def()
	# Retroceso de cámara: sube la mira; en automáticas escala con la ráfaga
	# (el que controla el spray tiene ventaja — skill real).
	var now := _now()
	_consec_shots = _consec_shots + 1 if now - _last_shot_at < 0.4 else 1
	_last_shot_at = now
	var punch: float = float(def.get("cam_punch", 0.8)) \
		* (1.0 + float(def.get("climb", 0.0)) * (_consec_shots - 1))
	if _ads:
		punch *= 0.6
	head.rotation.x = clampf(head.rotation.x + deg_to_rad(punch * randf_range(0.85, 1.15)), -PI / 2, PI / 2)
	rotate_y(deg_to_rad(randf_range(-punch, punch) * 0.12))
	var hud := get_tree().get_first_node_in_group("game-ui")
	if hud and hud.crosshair:
		hud.crosshair.recoil += 0.25
	var origin: Vector3 = camera.global_position
	var dir: Vector3 = -camera.global_transform.basis.z
	if multiplayer.is_server():
		srv_fire(_weapons.current_index, origin, dir, _ads)
	else:
		srv_fire.rpc_id(1, _weapons.current_index, origin, dir, _ads)

# MOVIMIENTO + ANIMACIÓN

func _physics_process(delta: float) -> void:
	if multiplayer.is_server() and delta > 0.0:
		_srv_speed = (global_position - _srv_prev_pos).length() / delta
		_srv_prev_pos = global_position
		# Failsafe anti-bugs: nadie puede terminar fuera del mapa.
		if global_position.y < -4.0 and not _srv_dead:
			var arena := get_tree().current_scene
			var safe := Vector3(0, 1.5, 0)
			if arena and arena.has_method("pick_spawn_point"):
				safe = arena.pick_spawn_point()
			cl_respawn.rpc(safe)
			_local_respawn(safe)
	if is_bot:
		if multiplayer.is_server():
			_bot_physics(delta)
			sync_pos = global_position
			sync_rot_y = rotation.y
		else:
			_apply_remote_interp(delta)
	elif is_local():
		if AutoTest.autopilot:
			_autopilot_move(delta)
		elif not is_dead:
			_local_move(delta)
		else:
			velocity.x = 0
			velocity.z = 0
			if not is_on_floor():
				velocity.y -= GRAVITY * delta
			move_and_slide()
		sync_pos = global_position
		sync_rot_y = rotation.y
	else:
		_apply_remote_interp(delta)
	_drive_rig()

## Los peers que no controlan este jugador lo interpolan hacia el estado
## replicado (suaviza el movimiento en red; teletransportes hacen snap).
func _apply_remote_interp(delta: float) -> void:
	if global_position.distance_to(sync_pos) > SNAP_DISTANCE:
		global_position = sync_pos
	else:
		global_position = global_position.lerp(sync_pos, minf(1.0, delta * INTERP_SPEED))
	rotation.y = lerp_angle(rotation.y, sync_rot_y, minf(1.0, delta * INTERP_SPEED))

func _local_move(delta: float) -> void:
	# Armas automáticas: mantener apretado dispara.
	if _weapons and _weapons.is_auto() and Input.is_action_pressed("fire") \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_do_fire()
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	if Input.is_action_just_pressed("jump") and is_on_floor() and not _is_crouching:
		velocity.y = JUMP_STRENGTH
	if Input.is_action_just_pressed("crouch"):
		_is_crouching = not _is_crouching
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	var sprinting := Input.is_action_pressed("sprint") and is_on_floor() \
		and input_dir.y < 0 and not _is_crouching
	# ADS (click derecho): zoom suave; la AWP tiene mira 4x con overlay.
	_ads = Input.is_action_pressed("aim") and _weapons != null \
		and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if _weapons:
		_weapons.ads = _ads and not _is_scoped() # la AWP usa overlay, no viewmodel
	var target_fov := GameSettings.fov + (10.0 if sprinting else 0.0)
	if _ads:
		target_fov *= 0.25 if _is_scoped() else 0.72
	_fov_kick = lerpf(_fov_kick, 0.0, 8.0 * delta)
	camera.fov = lerpf(camera.fov, target_fov + _fov_kick, 12.0 * delta)
	var mhud := get_tree().get_first_node_in_group("match-ui")
	if mhud:
		mhud.set_scope(_ads and _is_scoped())
	var speed := WALK_SPEED
	if sprinting:
		speed = SPRINT_SPEED
	elif _is_crouching:
		speed = CROUCH_SPEED
	speed *= float(WeaponDefs.get_def(weapon_index).get("speed_mult", 1.0))
	if is_on_floor():
		# En el piso el control es instantáneo (snappy).
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		# En el aire hay control parcial: conservás el impulso del salto.
		velocity.x = lerpf(velocity.x, direction.x * speed, 5.5 * delta)
		velocity.z = lerpf(velocity.z, direction.z * speed, 5.5 * delta)
	move_and_slide()
	_head_feel(delta, direction, sprinting)
	_update_anim_state(direction, sprinting)

## Head bob sutil + altura de agachado, todo suavizado.
func _is_scoped() -> bool:
	return _weapons != null and _weapons.current_index == 5 # AWP

var _was_on_floor := true

func _head_feel(delta: float, direction: Vector3, sprinting: bool) -> void:
	# Dip de cámara al aterrizar; el lerp de abajo lo recupera solo.
	if is_on_floor() and not _was_on_floor:
		head.position.y -= 0.08
	_was_on_floor = is_on_floor()
	var target_y := 0.95 if _is_crouching else 1.55
	var bob := 0.0
	if is_on_floor() and direction.length() > 0.1:
		_bob_time += delta * (11.0 if sprinting else 8.0)
		bob = sin(_bob_time) * 0.045
		_step_accum += velocity.length() * delta
		if _step_accum > 2.4:
			_step_accum = 0.0
			Sfx.play("step", -16.0, randf_range(0.9, 1.1))
	head.position.y = lerpf(head.position.y, target_y + bob, 12.0 * delta)

func _update_anim_state(direction: Vector3, sprinting: bool) -> void:
	if is_dead:
		anim_state = Anim.DEAD
	elif not is_on_floor():
		anim_state = Anim.AIR
	elif direction.length() > 0.1:
		anim_state = Anim.RUN if sprinting else Anim.WALK
	else:
		anim_state = Anim.IDLE
	if _weapons:
		weapon_index = _weapons.current_index

var _last_rig_pos := Vector3.ZERO

func _drive_rig() -> void:
	if _rig == null:
		return
	# Velocidad horizontal observada -> escala de la animación (sin patinar).
	var dt := get_process_delta_time()
	if dt > 0.0:
		var moved := global_position - _last_rig_pos
		moved.y = 0
		_rig.set_move_speed(moved.length() / dt)
	_last_rig_pos = global_position
	# Pasos de los demás jugadores (sonido posicional).
	if not is_local() and (anim_state == Anim.WALK or anim_state == Anim.RUN):
		_remote_step_timer -= get_process_delta_time()
		if _remote_step_timer <= 0.0:
			_remote_step_timer = 0.34 if anim_state == Anim.RUN else 0.45
			Sfx.play3d("step", global_position, -14.0)
	match anim_state:
		Anim.DEAD:
			_rig.set_state(CharacterRig.State.DEAD)
		Anim.AIR:
			_rig.set_state(CharacterRig.State.AIR)
		Anim.RUN:
			_rig.set_state(CharacterRig.State.RUN)
		Anim.WALK:
			_rig.set_state(CharacterRig.State.WALK)
		_:
			_rig.set_state(CharacterRig.State.IDLE)
	_update_hand_prop()

# IA DE BOTS (corre SOLO en el server)

func _bot_physics(delta: float) -> void:
	if _srv_dead:
		velocity.x = 0
		velocity.z = 0
		if not is_on_floor():
			velocity.y -= GRAVITY * delta
		move_and_slide()
		anim_state = Anim.DEAD
		return
	var t := _now() + _auto_seed
	# Reelegir objetivo cada tanto.
	if _bot_target == null or not is_instance_valid(_bot_target) or _bot_target.is_dead \
			or t > _bot_retarget_at:
		_bot_target = _nearest_enemy()
		_bot_retarget_at = t + randf_range(2.0, 4.0)
		_bot_strafe_dir = 1.0 if randf() > 0.5 else -1.0
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	var has_los := _bot_target != null and _bot_has_los(_bot_target)
	var move_intent := Vector3.ZERO
	if _bot_target and has_los:
		var to := _bot_target.global_position - global_position
		to.y = 0
		var dist := to.length()
		if dist > 0.5:
			rotation.y = lerp_angle(rotation.y, atan2(-to.x, -to.z), _bot_turn * delta)
		# Acercarse si está lejos, mantener distancia media y strafear.
		var fwd := -1.0 if dist > 9.0 else (0.4 if dist < 4.0 else -0.25)
		move_intent = Vector3(_bot_strafe_dir * 0.8, 0, fwd)
	else:
		# Sin objetivo a la vista: patrullar hacia un punto del mapa.
		if t > _bot_roam_until or global_position.distance_to(_bot_roam) < 2.5:
			var arena := get_tree().current_scene
			if arena and "SPAWN_POINTS" in arena:
				_bot_roam = arena.SPAWN_POINTS[randi() % arena.SPAWN_POINTS.size()]
			else:
				_bot_roam = Vector3(randf_range(-16, 16), 1, randf_range(-16, 16))
			_bot_roam_until = t + randf_range(5.0, 9.0)
		var to_roam := _bot_roam - global_position
		to_roam.y = 0
		if to_roam.length() > 0.5:
			rotation.y = lerp_angle(rotation.y, atan2(-to_roam.x, -to_roam.z), _bot_turn * delta)
		move_intent = Vector3(0, 0, -1)
	# Esquivar paredes: si hay algo justo adelante, girar.
	var space := get_world_3d().direct_space_state
	var fwd_dir := -transform.basis.z
	var wall_query := PhysicsRayQueryParameters3D.create(
		global_position + Vector3.UP, global_position + Vector3.UP + fwd_dir * 1.6)
	wall_query.exclude = [get_rid()]
	if not space.intersect_ray(wall_query).is_empty():
		rotation.y += _bot_strafe_dir * 2.2 * delta
	var direction := (transform.basis * move_intent).normalized()
	velocity.x = lerpf(velocity.x, direction.x * WALK_SPEED, 8.0 * delta)
	velocity.z = lerpf(velocity.z, direction.z * WALK_SPEED, 8.0 * delta)
	var was_pos := global_position
	move_and_slide()
	# Si quedó trabado contra algo, saltar o cambiar de strafe.
	if is_on_floor() and (global_position - was_pos).length() < WALK_SPEED * delta * 0.3:
		if randf() < 0.25:
			velocity.y = JUMP_STRENGTH
		_bot_strafe_dir *= -1.0
	_update_anim_state(direction, false)
	weapon_index = _bot_windex
	# Disparo con puntería imperfecta (skill del bot), SOLO con línea de visión.
	if _bot_target and has_los and not Net.fire_locked():
		var eye := global_position + Vector3.UP * 1.55
		var aim := (_bot_target.global_position + Vector3.UP * 1.1 - eye).normalized()
		var jitter := deg_to_rad(randf_range(0.0, _bot_jitter))
		aim = aim.rotated(Vector3.UP, randf_range(-jitter, jitter))
		if _now() - _srv_last_fire >= WeaponDefs.cooldown_for(_bot_windex) * _bot_cd_mult * randf_range(0.9, 1.3):
			_srv_last_fire = _now()
			_srv_execute_fire(_bot_windex, eye, aim)

func _bot_has_los(target: NetPlayer) -> bool:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3.UP * 1.55
	var to := target.global_position + Vector3.UP * 1.1
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [get_rid()]
	var result := space.intersect_ray(query)
	return not result.is_empty() and result["collider"] == target

# Piloto automático para verificación (2 instancias sin humanos).
func _autopilot_move(delta: float) -> void:
	if is_dead:
		move_and_slide()
		return
	var t := _now() + _auto_seed
	var target := _nearest_enemy()
	if target:
		var to := target.global_position - global_position
		to.y = 0
		if to.length() > 0.5:
			var desired := atan2(-to.x, -to.z)
			rotation.y = lerp_angle(rotation.y, desired, 3.0 * delta)
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	var strafe := sin(t * 1.7)
	var direction := (transform.basis * Vector3(strafe, 0, -0.6)).normalized()
	velocity.x = direction.x * WALK_SPEED
	velocity.z = direction.z * WALK_SPEED
	move_and_slide()
	_update_anim_state(direction, false)
	if fmod(t, 0.6) < delta * 1.5 and _weapons:
		_do_autopilot_fire(target)

func _do_autopilot_fire(target: NetPlayer) -> void:
	if Net.fire_locked() or not _weapons.try_fire():
		return
	var origin: Vector3 = camera.global_position
	var dir: Vector3 = -camera.global_transform.basis.z
	if target:
		dir = (target.global_position + Vector3.UP * 1.2 - origin).normalized()
	if multiplayer.is_server():
		srv_fire(_weapons.current_index, origin, dir, false)
	else:
		srv_fire.rpc_id(1, _weapons.current_index, origin, dir, false)

func _nearest_enemy() -> NetPlayer:
	var best: NetPlayer = null
	var best_d := INF
	for p in get_tree().get_nodes_in_group("net_players"):
		if p == self or p.is_dead:
			continue
		var d: float = p.global_position.distance_squared_to(global_position)
		if d < best_d:
			best_d = d
			best = p
	return best

# COMBATE — TODO SE RESUELVE EN EL SERVER

@rpc("any_peer", "reliable")
func srv_fire(windex: int, origin: Vector3, dir: Vector3, ads := false) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1 # llamada directa del host local
	if sender != peer_id or _srv_dead or not Net.in_match or Net.fire_locked():
		return
	windex = clampi(windex, 0, WeaponDefs.count() - 1)
	if windex < _srv_unlocked.size() and not _srv_unlocked[windex]:
		return # no tenés esa arma (anticheat)
	# Anticheat básico: cadencia y origen validados contra el estado del server.
	var now := _now()
	if now - _srv_last_fire < WeaponDefs.cooldown_for(windex) * 0.85:
		return
	_srv_last_fire = now
	var server_eye := global_position + Vector3.UP * 1.7
	if origin.distance_to(server_eye) > 2.5:
		origin = server_eye
	_srv_execute_fire(windex, origin, dir.normalized(), ads)

## Resolución real del disparo (la usan srv_fire y los bots).
## La dispersión se decide ACÁ (server): hip vs ADS + penalidad por moverse.
func _srv_execute_fire(windex: int, origin: Vector3, dir: Vector3, ads := false) -> void:
	var def := WeaponDefs.get_def(windex)
	var reach := float(def["range"])
	var pellets := int(def["pellets"])
	var spread_deg := float(def.get("spread_ads" if ads else "spread_hip", 0.0))
	if _srv_speed > 2.0:
		spread_deg += float(def.get("spread_move", 0.0))
	if spread_deg > 0.01:
		var cone := deg_to_rad(spread_deg)
		var axis := dir.cross(Vector3.UP).normalized()
		if axis.length_squared() < 0.5:
			axis = Vector3.RIGHT
		dir = dir.rotated(axis, randf_range(-cone, cone))
		dir = dir.rotated(dir.normalized(), randf() * TAU).normalized()
	var fx: Array = []
	if pellets > 0:
		# Escopeta: perdigones con dispersión, decididos por el server.
		var pellet_damage := int(ceil(float(def["damage"]) / pellets))
		for i in pellets:
			var spread := deg_to_rad(WeaponDefs.SHOTGUN_SPREAD_DEG)
			var pdir := dir.rotated(dir.cross(Vector3.UP).normalized(), randf_range(-spread, spread))
			pdir = pdir.rotated(dir.normalized(), randf() * TAU)
			_srv_trace(origin, pdir, reach, pellet_damage, fx, windex)
	else:
		_srv_trace(origin, dir, reach, int(def["damage"]), fx, windex)
	if not fx.is_empty():
		cl_fire_fx.rpc(windex, origin, fx)
		_apply_fire_fx(windex, origin, fx)

func _srv_trace(origin: Vector3, dir: Vector3, reach: float, damage: int, fx: Array, windex := 1) -> void:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * reach)
	var exclusions: Array[RID] = [get_rid()]
	for p in get_tree().get_nodes_in_group("net_players"):
		if p != self and p._srv_dead:
			exclusions.append(p.get_rid())
	query.exclude = exclusions
	var result := space.intersect_ray(query)
	if result.is_empty():
		# Trazadora hasta el alcance máximo aunque no pegue.
		fx.append({"p": origin + dir * minf(reach, 60.0), "n": Vector3.UP, "blood": false, "miss": true})
		return
	var collider = result["collider"]
	var is_player: bool = collider is NetPlayer and collider != self
	var headshot := false
	var backstab := false
	if is_player and windex == 0:
		# Backstab: cuchillazo por la espalda = x3 (mata de una).
		var victim := collider as NetPlayer
		var to_attacker: Vector3 = (global_position - victim.global_position).normalized()
		if to_attacker.dot(-victim.transform.basis.z) < -0.35:
			backstab = true
			damage *= 3
	if is_player:
		# Caída de daño con la distancia (a partir de la mitad del alcance).
		if reach > 10.0:
			var dist: float = origin.distance_to(result["position"])
			if dist > reach * 0.5:
				var falloff: float = 1.0 - 0.45 * clampf((dist - reach * 0.5) / (reach * 0.5), 0.0, 1.0)
				damage = maxi(1, int(damage * falloff))
		headshot = result["position"].y > collider.global_position.y + HEADSHOT_HEIGHT
		if headshot:
			damage = int(damage * HEADSHOT_MULT)
	fx.append({"p": result["position"], "n": result["normal"], "blood": is_player, "miss": false})
	if is_player:
		collider._srv_apply_damage(damage, peer_id, headshot, windex, backstab)

func _srv_apply_damage(amount: int, attacker_id: int, headshot := false, windex := 1, backstab := false) -> void:
	if not multiplayer.is_server() or _srv_dead:
		return
	if _now() < _srv_protect_until:
		return # protección de spawn
	_srv_health -= amount
	var from_pos := Vector3.INF
	var attacker_node := _find_player(attacker_id)
	if attacker_node:
		from_pos = attacker_node.global_position
	_send_owner_health(from_pos)
	# Hitmarker para el atacante (si es humano).
	if attacker_id > 0:
		var attacker := _find_player(attacker_id)
		if attacker:
			if attacker_id == 1:
				attacker._local_hitmarker(headshot)
			else:
				attacker.cl_hitmarker.rpc_id(attacker_id, headshot)
	if _srv_health <= 0:
		_srv_die(attacker_id, headshot, windex, backstab)

func _send_owner_health(from_pos := Vector3.INF) -> void:
	if is_bot:
		return
	if peer_id == 1:
		_local_set_health(_srv_health, from_pos)
	else:
		cl_health.rpc_id(peer_id, _srv_health, from_pos)

func _srv_die(attacker_id: int, headshot := false, windex := 1, backstab := false) -> void:
	_srv_dead = true
	var killer_name: String = Net.players.get(attacker_id, {}).get("name", "?")
	var weapon_label := String(WeaponDefs.get_def(windex)["name"])
	if backstab:
		weapon_label = "Knife · BACKSTAB"
	Net.register_kill(attacker_id, peer_id, headshot, weapon_label)
	cl_set_dead.rpc(true, killer_name)
	_local_set_dead(true, killer_name)
	if attacker_id != peer_id:
		var attacker := _find_player(attacker_id)
		if attacker:
			# Recompensa por kill: +25 de vida (premia la agresividad).
			attacker._srv_heal(25)
			# Confirmación de kill para el atacante humano.
			if not attacker.is_bot:
				if attacker_id == 1:
					attacker._local_kill_confirm()
				else:
					attacker.cl_kill_confirm.rpc_id(attacker_id)
	get_tree().create_timer(RESPAWN_SECONDS).timeout.connect(_srv_respawn)

## Curación server-side (medkits, recompensa por kill).
func _srv_heal(amount: int) -> void:
	if not multiplayer.is_server() or _srv_dead:
		return
	_srv_health = mini(_srv_health + amount, MAX_HEALTH)
	_send_owner_health()

## Desbloqueo server-side de un arma (pads del mapa).
func _srv_unlock(windex: int) -> void:
	if not multiplayer.is_server() or windex >= _srv_unlocked.size():
		return
	_srv_unlocked[windex] = true
	if is_bot:
		return
	if peer_id == 1:
		_local_unlock(windex)
	else:
		cl_unlock.rpc_id(peer_id, windex)

func srv_has_weapon(windex: int) -> bool:
	return windex < _srv_unlocked.size() and _srv_unlocked[windex]

@rpc("authority", "reliable")
func cl_unlock(windex: int) -> void:
	_local_unlock(windex)

func _local_unlock(windex: int) -> void:
	if not is_local() or _weapons == null:
		return
	_weapons.unlock(windex)
	Sfx.play("pickup")
	var mhud := get_tree().get_first_node_in_group("match-ui")
	if mhud:
		mhud.show_pickup("%s ACQUIRED" % String(WeaponDefs.get_def(windex)["name"]).to_upper())

func _srv_respawn() -> void:
	if not multiplayer.is_server() or not Net.in_match or not is_inside_tree():
		return
	_srv_health = MAX_HEALTH
	_srv_dead = false
	_srv_protect_until = _now() + SPAWN_PROTECT_SECONDS
	_srv_reset_loadout() # al morir perdés las armas del mapa
	var arena := get_tree().current_scene
	var pos := Vector3(0, 1.5, 0)
	if arena and arena.has_method("pick_spawn_point"):
		pos = arena.pick_spawn_point()
	cl_respawn.rpc(pos)
	_local_respawn(pos)

@rpc("authority", "reliable")
func cl_health(value: int, from_pos := Vector3.INF) -> void:
	_local_set_health(value, from_pos)

func _local_set_health(value: int, from_pos := Vector3.INF) -> void:
	var took_damage := value < health
	health = value
	if is_local():
		var hud := get_tree().get_first_node_in_group("game-ui")
		if hud:
			hud.update_health(max(health, 0), MAX_HEALTH)
		var mhud := get_tree().get_first_node_in_group("match-ui")
		if mhud:
			mhud.update_health_fx(max(health, 0), MAX_HEALTH)
			if took_damage:
				mhud.flash_damage()
				if from_pos.is_finite():
					# Ángulo del atacante relativo a donde mirás (0 = adelante).
					var to := from_pos - global_position
					var rel := atan2(to.x, -to.z) + rotation.y
					mhud.show_damage_dir(rel)
		if took_damage:
			_fov_kick = 5.0
			Sfx.play("hurt", -6.0)

@rpc("authority", "reliable")
func cl_hitmarker(headshot: bool) -> void:
	_local_hitmarker(headshot)

func _local_hitmarker(headshot: bool) -> void:
	if not is_local():
		return
	Sfx.play("headshot" if headshot else "hit", -4.0)
	var mhud := get_tree().get_first_node_in_group("match-ui")
	if mhud:
		mhud.show_hitmarker(headshot)

@rpc("authority", "reliable")
func cl_kill_confirm() -> void:
	_local_kill_confirm()

func _local_kill_confirm() -> void:
	if not is_local():
		return
	Sfx.play("kill")
	var mhud := get_tree().get_first_node_in_group("match-ui")
	if mhud:
		mhud.show_kill_popup()

@rpc("authority", "reliable")
func cl_set_dead(dead: bool, killer_name: String) -> void:
	_local_set_dead(dead, killer_name)

func _local_set_dead(dead: bool, killer_name: String) -> void:
	is_dead = dead
	if dead:
		anim_state = Anim.DEAD
		if is_local():
			Sfx.play("death")
			if _weapons:
				_weapons.visible = false
			# Death cam: la cámara cae y mira al piso.
			var tw := create_tween()
			tw.set_parallel(true)
			tw.tween_property(head, "rotation:x", deg_to_rad(-65), 0.9)\
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			tw.tween_property(head, "position:y", 0.5, 0.9)
			var mhud := get_tree().get_first_node_in_group("match-ui")
			if mhud:
				mhud.show_death(killer_name, RESPAWN_SECONDS)

@rpc("authority", "reliable")
func cl_respawn(pos: Vector3) -> void:
	_local_respawn(pos)

func _local_respawn(pos: Vector3) -> void:
	is_dead = false
	anim_state = Anim.IDLE
	if _rig:
		_rig.set_state(CharacterRig.State.IDLE)
	if is_bot and multiplayer.is_server():
		global_position = pos
		sync_pos = pos
		velocity = Vector3.ZERO
	if is_local():
		global_position = pos
		sync_pos = pos
		velocity = Vector3.ZERO
		head.rotation.x = 0
		_is_crouching = false
		head.position.y = 1.55
		if _weapons:
			_weapons.visible = true
			_weapons.reset_loadout()
		_local_set_health(MAX_HEALTH)
		Sfx.play("respawn")
		var mhud := get_tree().get_first_node_in_group("match-ui")
		if mhud:
			mhud.hide_death()

@rpc("authority", "reliable")
func cl_give_ammo() -> void:
	give_ammo()

@rpc("authority", "reliable")
func cl_medkit(amount: int) -> void:
	if is_local():
		Sfx.play("pickup")
		var mhud := get_tree().get_first_node_in_group("match-ui")
		if mhud:
			mhud.show_pickup("+%d HP" % amount)

## Munición extra (cajas de la Arena). Solo el dueño la aplica a su HUD.
func give_ammo() -> void:
	if is_local() and _weapons:
		_weapons.add_reserve_all()
		Sfx.play("pickup")
		var mhud := get_tree().get_first_node_in_group("match-ui")
		if mhud:
			mhud.show_pickup("AMMO +")

# FEEDBACK VISUAL DE DISPAROS (en todos los peers)

@rpc("authority", "reliable")
func cl_fire_fx(windex: int, origin: Vector3, fx: Array) -> void:
	_apply_fire_fx(windex, origin, fx)

func _apply_fire_fx(windex: int, origin: Vector3, fx: Array) -> void:
	radar_ping_at = _now()
	# Retroceso del brazo del que dispara (visible en 3ra persona para todos).
	if _aim_pose:
		_aim_pose.kick()
	# Sonido posicional + fogonazo en la mano del que dispara (si no sos vos).
	if not is_local():
		Sfx.play3d(String(WeaponDefs.get_def(windex)["sfx"]), origin, -4.0)
		if _hand_flash:
			_hand_flash.start()
	var too_many_vfx: bool = get_tree().get_nodes_in_group("impact-vfx").size() > 8
	var whizzed := false
	for hit in fx:
		var target: Vector3 = hit["p"]
		if windex != 0: # el cuchillo no traza
			_spawn_tracer(origin, target, windex)
			# Silbido si la bala pasó cerca de TU cámara (y no la tiraste vos).
			if not whizzed and not is_local():
				var cam := get_viewport().get_camera_3d()
				if cam:
					var seg := target - origin
					var t := clampf((cam.global_position - origin).dot(seg) / maxf(seg.length_squared(), 0.001), 0.0, 1.0)
					if cam.global_position.distance_to(origin + seg * t) < 1.8:
						whizzed = true
						Sfx.play("whiz", -6.0)
		if bool(hit.get("miss", false)) or too_many_vfx:
			continue
		_spawn_puff(target, bool(hit["blood"]))

## Impacto: puff chico emisivo que crece y se esfuma. Rojo si es sangre
## (los VFX de partículas del demo renderizan mal en WebGL).
func _spawn_puff(pos: Vector3, blood := false) -> void:
	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.06
	sphere.height = 0.12
	sphere.radial_segments = 8
	sphere.rings = 4
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.75, 0.08, 0.05, 0.9) if blood else Color(0.95, 0.9, 0.75, 0.85)
	sphere.material = mat
	mi.mesh = sphere
	mi.add_to_group("impact-vfx")
	get_tree().root.add_child(mi)
	mi.global_position = pos
	var tw := mi.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3.ONE * 3.2, 0.25)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.25)
	tw.chain().tween_callback(mi.queue_free)

func _spawn_tracer(from: Vector3, to: Vector3, windex := 1) -> void:
	var dir := to - from
	var dist := dir.length()
	if dist < 1.2:
		return
	dir = dir / dist
	# Nace un poco adelante y abajo para que no salga de la cara.
	var start := from + dir * 0.9 - Vector3.UP * 0.12
	dist = start.distance_to(to)
	var width := float(WeaponDefs.get_def(windex).get("tracer", 0.02))
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(width, width, dist)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.9, 0.55, 0.85)
	box.material = mat
	mi.mesh = box
	get_tree().root.add_child(mi)
	mi.global_position = (start + to) * 0.5
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	mi.look_at(to, up)
	var tw := mi.create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.09)
	tw.tween_callback(mi.queue_free)

func _find_player(id: int) -> NetPlayer:
	for p in get_tree().get_nodes_in_group("net_players"):
		if p.peer_id == id:
			return p
	return null

# HUD hooks (jugador local)

func _on_ammo_changed(mag: int, reserve: int) -> void:
	var hud := get_tree().get_first_node_in_group("game-ui")
	if hud and _weapons:
		var def := _weapons.current_def()
		var wname := String(def["name"])
		if mag < 0:
			hud.update_weapon(wname, 1, 0, false)
		else:
			hud.update_weapon(wname, mag, reserve)
		if hud.has_method("set_low_ammo"):
			hud.set_low_ammo(bool(def["uses_ammo"]) and mag >= 0 \
				and mag <= maxi(1, int(def["mag"]) / 4) )

func _on_weapon_changed(index: int, weapon_name: String) -> void:
	var hud := get_tree().get_first_node_in_group("game-ui")
	if hud:
		var def := _weapons.current_def()
		if hud.crosshair:
			var ch_data = load(String(def["crosshair"]))
			if ch_data:
				hud.crosshair.apply_data(ch_data)
		var info: Dictionary = _weapons.ammo_info()
		if bool(def["uses_ammo"]):
			hud.update_weapon(weapon_name, int(info["mag"]), int(info["reserve"]))
		else:
			hud.update_weapon(weapon_name, 1, 0, false)
	var mhud := get_tree().get_first_node_in_group("match-ui")
	if mhud:
		mhud.set_weapon_index(index)
