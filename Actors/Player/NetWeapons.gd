# NetWeapons.gd
# Arsenal en primera persona del jugador LOCAL, con los modelos GLB del
# pack del usuario (Assets/Guns). Acá vive solo lo cosmético + munición
# del HUD; el disparo real (raycast, daño, kills) lo resuelve el SERVER
# en NetPlayer.srv_fire usando los mismos WeaponDefs.
class_name NetWeapons
extends Node3D

signal ammo_changed(mag: int, reserve: int)
signal weapon_changed(index: int, weapon_name: String)

const KNIFE_SCENE := "res://Weapons/Scenes/Knife/KnifeEquipped.tscn"

# Fogonazo propio, chico y breve: las partículas del demo quedan enormes
# tan cerca de la cámara en primera persona.
class MiniFlash extends Node3D:
	var _mesh: MeshInstance3D
	var _light: OmniLight3D

	func _init() -> void:
		_mesh = MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.035
		sphere.height = 0.07
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.85, 0.4)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.8, 0.3)
		mat.emission_energy_multiplier = 2.5
		sphere.material = mat
		_mesh.mesh = sphere
		_mesh.visible = false
		add_child(_mesh)
		_light = OmniLight3D.new()
		_light.light_color = Color(1.0, 0.8, 0.4)
		_light.omni_range = 3.0
		_light.light_energy = 0.0
		add_child(_light)

	func start() -> void:
		_mesh.visible = true
		_mesh.scale = Vector3.ONE * randf_range(0.8, 1.3)
		_light.light_energy = 2.0
		var tw := create_tween()
		tw.tween_interval(0.05)
		tw.tween_callback(func():
			_mesh.visible = false
			_light.light_energy = 0.0)

signal loadout_changed # armas desbloqueadas cambiaron (pickup o respawn)

var current_index := 1
var unlocked: Array[bool] = []
var ads := false # apuntando (click derecho)

const ADS_OFFSET := Vector3(-0.3, 0.13, 0.12) # lleva el arma al centro
var _sway := Vector2.ZERO

var _viewmodels: Array[Node3D] = []
var _muzzles: Array[Node3D] = []
var _rest_pos: Array[Vector3] = []
var _ammo: Array[Dictionary] = [] # {mag, reserve, reloading}
var _reload_timer: Timer
var _last_fire_at := -10.0

func _ready() -> void:
	_reload_timer = Timer.new()
	_reload_timer.one_shot = true
	_reload_timer.timeout.connect(_finish_reload)
	add_child(_reload_timer)
	for i in WeaponDefs.count():
		var def := WeaponDefs.get_def(i)
		unlocked.append(WeaponDefs.is_starter(i))
		_ammo.append({
			"mag": int(def["mag"]),
			"reserve": int(def["reserve"]),
			"reloading": false,
		})
		_viewmodels.append(_build_viewmodel(i, def))
	switch_to(1) # arranca con la pistola

func _build_viewmodel(index: int, def: Dictionary) -> Node3D:
	var holder := Node3D.new()
	holder.name = "VM%d" % index
	var muzzle: Node3D = null
	if String(def["model"]).is_empty():
		# Cuchillo: viewmodel del demo (CSG), sin lógica single-player.
		var knife: Node3D = (load(KNIFE_SCENE) as PackedScene).instantiate()
		knife.set_script(null)
		for ray in knife.find_children("*", "RayCast3D", true, false):
			ray.enabled = false
		holder.add_child(knife)
	else:
		var gun: Node3D = (load(String(def["model"])) as PackedScene).instantiate()
		var s := float(def.get("scale", 1.0))
		gun.scale = Vector3.ONE * s
		# Los GLB del pack apuntan el caño hacia +X; en cámara el frente es -Z.
		gun.rotation_degrees.y = 90.0
		holder.add_child(gun)
		# Fogonazo en la punta del caño.
		muzzle = MiniFlash.new()
		holder.add_child(muzzle)
		muzzle.position = Vector3(0, 0.02, -_gun_length(gun) * 0.95)
	_muzzles.append(muzzle)
	_rest_pos.append(holder.position)
	holder.visible = false
	add_child(holder)
	return holder

func _gun_length(gun: Node3D) -> float:
	var total := 0.0
	for mi in gun.find_children("*", "MeshInstance3D", true, false):
		var aabb: AABB = (mi as MeshInstance3D).get_aabb()
		total = maxf(total, aabb.end.x * gun.scale.x)
	return total

func _process(delta: float) -> void:
	# Recuperación tipo resorte del retroceso + sway + ADS + dip de recarga.
	_sway = _sway.lerp(Vector2.ZERO, 6.0 * delta)
	var vm := _viewmodels[current_index]
	var target_pos := _rest_pos[current_index] + Vector3(_sway.x, _sway.y, 0)
	if ads:
		target_pos += ADS_OFFSET
	var target_rot := Vector3(0, 0, -_sway.x * 1.2)
	if is_reloading():
		target_rot.x = deg_to_rad(26)
		target_pos.y -= 0.06
	vm.position = vm.position.lerp(target_pos, 8.0 * delta)
	vm.rotation = vm.rotation.lerp(target_rot, 8.0 * delta)

## Retardo del arma al mover el mouse (lo alimenta NetPlayer).
func add_sway(relative: Vector2) -> void:
	_sway = (_sway - relative * 0.00045).clamp(Vector2(-0.03, -0.03), Vector2(0.03, 0.03))

func is_reloading() -> bool:
	return bool(_ammo[current_index]["reloading"])

func current_def() -> Dictionary:
	return WeaponDefs.get_def(current_index)

func is_auto() -> bool:
	return bool(current_def()["auto"])

func ammo_info() -> Dictionary:
	return _ammo[current_index]

func switch_to(index: int) -> void:
	index = wrapi(index, 0, WeaponDefs.count())
	if not unlocked[index]:
		Sfx.play("empty", -12.0)
		return
	_reload_timer.stop()
	_ammo[current_index]["reloading"] = false
	_viewmodels[current_index].visible = false
	current_index = index
	_viewmodels[current_index].visible = true
	weapon_changed.emit(current_index, String(current_def()["name"]))
	_emit_ammo()

func switch_next() -> void:
	_switch_step(1)

func switch_prev() -> void:
	_switch_step(-1)

func _switch_step(dir: int) -> void:
	var i := current_index
	for _step in WeaponDefs.count():
		i = wrapi(i + dir, 0, WeaponDefs.count())
		if unlocked[i]:
			switch_to(i)
			return

## Pickup de arma: desbloquea, llena su munición y la equipa.
func unlock(index: int) -> void:
	index = clampi(index, 0, WeaponDefs.count() - 1)
	var def := WeaponDefs.get_def(index)
	unlocked[index] = true
	_ammo[index]["mag"] = int(def["mag"])
	_ammo[index]["reserve"] = int(def["reserve"])
	_ammo[index]["reloading"] = false
	loadout_changed.emit()
	switch_to(index)

## Al morir volvés al loadout inicial (cuchillo + pistola).
func reset_loadout() -> void:
	_reload_timer.stop()
	for i in WeaponDefs.count():
		var def := WeaponDefs.get_def(i)
		unlocked[i] = WeaponDefs.is_starter(i)
		_ammo[i]["mag"] = int(def["mag"])
		_ammo[i]["reserve"] = int(def["reserve"])
		_ammo[i]["reloading"] = false
	loadout_changed.emit()
	switch_to(1)

## Intenta disparar localmente. Devuelve true si el tiro salió (consume
## munición + feedback visual); el llamador manda el RPC al server.
func try_fire() -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_fire_at < WeaponDefs.cooldown_for(current_index):
		return false
	var def := current_def()
	var ammo := _ammo[current_index]
	if bool(def["uses_ammo"]):
		if ammo["reloading"]:
			return false
		if int(ammo["mag"]) <= 0:
			Sfx.play("empty", -8.0)
			start_reload()
			return false
		ammo["mag"] = int(ammo["mag"]) - 1
	_last_fire_at = now
	Sfx.play(String(def["sfx"]))
	# Retroceso.
	var vm := _viewmodels[current_index]
	vm.position.z += 0.09
	vm.rotation.x += deg_to_rad(3.5)
	var muzzle := _muzzles[current_index]
	if muzzle and muzzle.has_method("start"):
		muzzle.start()
	if bool(def["uses_ammo"]) and int(ammo["mag"]) <= 0 and int(ammo["reserve"]) > 0:
		start_reload()
	_emit_ammo()
	return true

## Caja de munición: suma media reserva máxima a cada arma (con tope).
func add_reserve_all() -> void:
	for i in WeaponDefs.count():
		var def := WeaponDefs.get_def(i)
		if not bool(def["uses_ammo"]):
			continue
		var max_reserve := int(def["reserve"])
		_ammo[i]["reserve"] = mini(int(_ammo[i]["reserve"]) + maxi(max_reserve / 2, 1), max_reserve)
	_emit_ammo()

func refill_all() -> void:
	_reload_timer.stop()
	for i in WeaponDefs.count():
		var def := WeaponDefs.get_def(i)
		_ammo[i]["mag"] = int(def["mag"])
		_ammo[i]["reserve"] = int(def["reserve"])
		_ammo[i]["reloading"] = false
	_emit_ammo()

func start_reload() -> void:
	var def := current_def()
	var ammo := _ammo[current_index]
	if not bool(def["uses_ammo"]) or ammo["reloading"]:
		return
	if int(ammo["mag"]) >= int(def["mag"]) or int(ammo["reserve"]) <= 0:
		return
	ammo["reloading"] = true
	Sfx.play("reload", -6.0)
	_reload_timer.wait_time = float(def["reload"])
	_reload_timer.start()

func _finish_reload() -> void:
	var def := current_def()
	var ammo := _ammo[current_index]
	if not ammo["reloading"]:
		return
	var needed: int = int(def["mag"]) - int(ammo["mag"])
	var moved: int = mini(needed, int(ammo["reserve"]))
	ammo["mag"] = int(ammo["mag"]) + moved
	ammo["reserve"] = int(ammo["reserve"]) - moved
	ammo["reloading"] = false
	_emit_ammo()

func _emit_ammo() -> void:
	var def := current_def()
	var ammo := _ammo[current_index]
	if bool(def["uses_ammo"]):
		ammo_changed.emit(int(ammo["mag"]), int(ammo["reserve"]))
	else:
		ammo_changed.emit(-1, -1)
