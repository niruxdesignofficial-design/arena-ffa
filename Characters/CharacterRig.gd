# CharacterRig.gd
# Wrapper del modelo GLB de un personaje custom (tercera persona).
# Expone estados de animación de alto nivel; los estados sin clip en el
# manifest usan un fallback procedural (y quedan registrados como aviso
# en CharacterLib.issues, nunca rotos en silencio).
class_name CharacterRig
extends Node3D

enum State { IDLE, WALK, RUN, AIR, DEAD }

var anim_player: AnimationPlayer
var available: Dictionary = {} # state_name -> anim name dentro de la lib "rig"
var _state: int = -1
var _death_tween: Tween
var _model_root: Node3D

func setup(model_root: Node3D, player: AnimationPlayer, states: Dictionary) -> void:
	_model_root = model_root
	anim_player = player
	available = states
	set_state(State.IDLE)

func set_state(s: int) -> void:
	if s == _state:
		return
	# Salir de DEAD resetea la pose procedural.
	if _state == State.DEAD:
		_reset_death_pose()
	_state = s
	if anim_player == null:
		return
	match s:
		State.IDLE:
			_play_or_freeze("idle")
		State.WALK:
			if not _play("walk"):
				_play_or_freeze("run")
		State.RUN:
			if not _play("run"):
				_play_or_freeze("walk")
		State.AIR:
			# Sin clip de salto: congela la pose actual (fallback procedural).
			if not _play("jump"):
				anim_player.pause()
		State.DEAD:
			if not _play("die"):
				_procedural_death()

func _play(state_name: String) -> bool:
	if available.has(state_name):
		anim_player.play("rig/" + String(available[state_name]))
		return true
	return false

func _play_or_freeze(state_name: String) -> void:
	if not _play(state_name):
		anim_player.pause()

func _procedural_death() -> void:
	anim_player.pause()
	if _death_tween:
		_death_tween.kill()
	_death_tween = create_tween()
	_death_tween.set_parallel(true)
	_death_tween.tween_property(_model_root, "rotation_degrees:x", -88.0, 0.45)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_death_tween.tween_property(_model_root, "position:y", 0.08, 0.45)

func _reset_death_pose() -> void:
	if _death_tween:
		_death_tween.kill()
		_death_tween = null
	if _model_root:
		_model_root.rotation_degrees.x = 0.0
		_model_root.position.y = 0.0
