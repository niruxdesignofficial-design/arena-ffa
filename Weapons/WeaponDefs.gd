# WeaponDefs.gd
# Fuente única de verdad de las armas (la usan el cliente para HUD/munición
# y el SERVER para validar cadencia y calcular daño). Los modelos son los
# GLB del pack del usuario en Assets/Guns.
class_name WeaponDefs

const DEFS: Array[Dictionary] = [
	{
		"name": "Knife", "cam_punch": 0.4, "climb": 0.0, "spread_hip": 0.0, "spread_ads": 0.0, "spread_move": 0.0, "tracer": 0.0, "speed_mult": 1.1, "sfx": "knife", "starter": true, "model": "", "uses_ammo": false,
		"damage": 50, "cooldown": 0.45, "range": 2.4,
		"mag": 0, "reserve": 0, "reload": 0.0, "auto": false, "pellets": 0,
		"crosshair": "res://UI/Crosshairs/Data/cross.tres",
	},
	{
		"name": "Pistol", "cam_punch": 0.9, "climb": 0.15, "spread_hip": 0.5, "spread_ads": 0.1, "spread_move": 0.6, "tracer": 0.02, "speed_mult": 1.0, "sfx": "pistol", "starter": true, "model": "res://Assets/Guns/pew.glb", "uses_ammo": true,
		"damage": 25, "cooldown": 0.32, "range": 120.0,
		"mag": 8, "reserve": 40, "reload": 1.3, "auto": false, "pellets": 0,
		"scale": 1.6,
		"crosshair": "res://UI/Crosshairs/Data/plus.tres",
	},
	{
		"name": "MAC-10", "cam_punch": 0.55, "climb": 0.3, "spread_hip": 1.3, "spread_ads": 0.7, "spread_move": 0.7, "tracer": 0.016, "speed_mult": 1.05, "starter": true, "sfx": "smg", "model": "res://Assets/Guns/mac10.glb", "uses_ammo": true,
		"damage": 13, "cooldown": 0.09, "range": 90.0,
		"mag": 24, "reserve": 96, "reload": 1.8, "auto": true, "pellets": 0,
		"scale": 1.3,
		"crosshair": "res://UI/Crosshairs/Data/plus.tres",
	},
	{
		"name": "Shotgun", "cam_punch": 2.2, "climb": 0.0, "spread_hip": 0.0, "spread_ads": 0.0, "spread_move": 0.0, "tracer": 0.02, "speed_mult": 1.0, "starter": true, "sfx": "shotgun", "model": "res://Assets/Guns/shotgun.glb", "uses_ammo": true,
		"damage": 98, "cooldown": 0.9, "range": 40.0,
		"mag": 6, "reserve": 24, "reload": 2.5, "auto": false, "pellets": 7,
		"crosshair": "res://UI/Crosshairs/Data/circular.tres",
	},
	{
		"name": "AK-47", "cam_punch": 0.8, "climb": 0.45, "spread_hip": 0.8, "spread_ads": 0.15, "spread_move": 0.9, "tracer": 0.024, "speed_mult": 1.0, "starter": true, "sfx": "rifle", "model": "res://Assets/Guns/ak47.glb", "uses_ammo": true,
		"damage": 22, "cooldown": 0.12, "range": 150.0,
		"mag": 30, "reserve": 90, "reload": 2.2, "auto": true, "pellets": 0,
		"crosshair": "res://UI/Crosshairs/Data/plus.tres",
	},
	{
		"name": "AWP", "cam_punch": 3.2, "climb": 0.0, "spread_hip": 6.0, "spread_ads": 0.02, "spread_move": 2.0, "tracer": 0.05, "speed_mult": 0.95, "starter": true, "sfx": "sniper", "model": "res://Assets/Guns/awp.glb", "uses_ammo": true,
		"damage": 105, "cooldown": 1.4, "range": 300.0,
		"mag": 5, "reserve": 15, "reload": 3.0, "auto": false, "pellets": 0,
		"crosshair": "res://UI/Crosshairs/Data/cross.tres",
	},
]

const SHOTGUN_SPREAD_DEG := 4.5

static func count() -> int:
	return DEFS.size()

static func get_def(i: int) -> Dictionary:
	return DEFS[clampi(i, 0, DEFS.size() - 1)]

static func cooldown_for(i: int) -> float:
	return float(get_def(i)["cooldown"])

static func is_starter(i: int) -> bool:
	return bool(get_def(i).get("starter", false))
