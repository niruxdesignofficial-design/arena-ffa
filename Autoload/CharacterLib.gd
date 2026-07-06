# CharacterLib.gd (autoload)
# Carga res://Characters/manifest.json y construye los rigs de los
# personajes custom. Agregar un personaje nuevo = soltar el GLB en
# Characters/Models/ y sumar una entrada al manifest, sin tocar código.
extends Node

const MANIFEST_PATH := "res://Characters/manifest.json"
# Estados que el juego usa. Los tres primeros son los mínimos esperables;
# el resto son opcionales con fallback procedural.
const KNOWN_STATES := ["idle", "walk", "run", "jump", "shoot", "die"]

var characters: Array[Dictionary] = [] # definiciones válidas, en orden del manifest
var issues: Array[String] = [] # avisos de validación (modelos/anims faltantes)

func _ready() -> void:
	_load_manifest()

func _load_manifest() -> void:
	characters.clear()
	issues.clear()
	if not FileAccess.file_exists(MANIFEST_PATH):
		_issue("Character manifest not found (%s)." % MANIFEST_PATH)
		return
	var raw := FileAccess.get_file_as_string(MANIFEST_PATH)
	var parsed = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("characters"):
		_issue("Invalid character manifest (expected {\"characters\": [...]}).")
		return
	for entry in parsed["characters"]:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var id := String(entry.get("id", ""))
		var model := String(entry.get("model", ""))
		if id.is_empty() or model.is_empty():
			_issue("Character entry missing 'id' or 'model' — skipped.")
			continue
		if not ResourceLoader.exists(model):
			_issue("Character '%s': model %s missing or not imported — skipped." % [id, model])
			continue
		var anims: Dictionary = entry.get("animations", {})
		for required in ["idle", "walk", "run"]:
			if not anims.has(required):
				_issue("Character '%s': missing '%s' animation in the manifest (fallback will be used)." % [id, required])
		for optional in ["jump", "shoot", "die"]:
			if not anims.has(optional):
				_issue("Character '%s': model has no '%s' animation; using a procedural fallback." % [id, optional])
		characters.append(entry)
	if characters.is_empty():
		_issue("No valid characters in the manifest.")
	for i in issues:
		push_warning("[CharacterLib] " + i)

func _issue(text: String) -> void:
	issues.append(text)

func get_ids() -> Array[String]:
	var out: Array[String] = []
	for c in characters:
		out.append(String(c["id"]))
	return out

func get_def(id: String) -> Dictionary:
	for c in characters:
		if String(c["id"]) == id:
			return c
	if not characters.is_empty():
		return characters[0]
	return {}

func default_id() -> String:
	return String(characters[0]["id"]) if not characters.is_empty() else ""

func display_name(id: String) -> String:
	var d := get_def(id)
	return String(d.get("name", id)) if not d.is_empty() else id

func accent_color(id: String) -> Color:
	var d := get_def(id)
	return Color(String(d.get("accent_color", "#f3ba2f")))

## Construye el rig de tercera persona (modelo + animaciones fusionadas).
## Devuelve null si el personaje no se pudo cargar (ya avisado en issues).
func build_rig(id: String) -> CharacterRig:
	var def := get_def(id)
	if def.is_empty():
		return null
	var scene: PackedScene = load(String(def["model"]))
	if scene == null:
		push_warning("[CharacterLib] No se pudo cargar el modelo de '%s'." % id)
		return null
	var model: Node3D = scene.instantiate()
	var ap: AnimationPlayer = model.find_child("AnimationPlayer", true, false)
	var states := {}
	if ap == null:
		push_warning("[CharacterLib] Personaje '%s' sin AnimationPlayer: el modelo no viene animado." % id)
	else:
		var lib := AnimationLibrary.new()
		var anims: Dictionary = def.get("animations", {})
		for state_name in anims.keys():
			var spec: Dictionary = anims[state_name]
			var anim := _extract_animation(String(def["model"]), ap, spec)
			if anim == null:
				push_warning("[CharacterLib] Personaje '%s': no se encontró el clip '%s' para '%s'." % [id, spec.get("clip", "?"), state_name])
				continue
			anim = anim.duplicate(true)
			if String(state_name) in ["idle", "walk", "run"]:
				anim.loop_mode = Animation.LOOP_LINEAR
			lib.add_animation(String(state_name), anim)
			states[String(state_name)] = String(state_name)
		ap.add_animation_library("rig", lib)
	# Tinte opcional (variantes de color del mismo modelo).
	if def.has("tint"):
		_apply_tint(model, Color(String(def["tint"])))
	var rig := CharacterRig.new()
	rig.name = "CharacterRig"
	var model_root := Node3D.new()
	model_root.name = "ModelRoot"
	rig.add_child(model_root)
	model_root.add_child(model)
	var s := float(def.get("scale", 1.0))
	model.scale = Vector3.ONE * s
	rig.setup(model_root, ap, states)
	return rig

func _extract_animation(base_model_path: String, base_ap: AnimationPlayer, spec: Dictionary) -> Animation:
	var file := String(spec.get("file", ""))
	var clip := String(spec.get("clip", ""))
	if file.is_empty() or clip.is_empty():
		return null
	if file == base_model_path:
		return base_ap.get_animation(clip) if base_ap.has_animation(clip) else null
	if not ResourceLoader.exists(file):
		return null
	var scene: PackedScene = load(file)
	if scene == null:
		return null
	var inst: Node = scene.instantiate()
	var ap: AnimationPlayer = inst.find_child("AnimationPlayer", true, false)
	var anim: Animation = null
	if ap and ap.has_animation(clip):
		anim = ap.get_animation(clip)
	inst.free()
	return anim

func _apply_tint(root: Node, tint: Color) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		for surf in mesh.get_surface_count():
			var mat: Material = mi.get_active_material(surf)
			if mat is BaseMaterial3D:
				var dup: BaseMaterial3D = mat.duplicate()
				dup.albedo_color = dup.albedo_color * tint
				mi.set_surface_override_material(surf, dup)
