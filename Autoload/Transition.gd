# Transition.gd (autoload)
# Fundido a negro entre escenas para que el pase menú <-> partida sea limpio.
extends CanvasLayer

var _rect: ColorRect
var _busy := false

func _ready() -> void:
	layer = 100
	_rect = ColorRect.new()
	_rect.color = Color(0, 0, 0, 0)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_rect)

func change_scene(path: String) -> void:
	if _busy:
		return
	_busy = true
	await _fade_to(1.0, 0.22)
	get_tree().change_scene_to_file(path)
	# Esperar a que la escena nueva esté montada antes de destapar.
	await get_tree().process_frame
	await get_tree().process_frame
	await _fade_to(0.0, 0.28)
	_busy = false

func _fade_to(alpha: float, dur: float) -> void:
	var tw := create_tween()
	tw.tween_property(_rect, "color:a", alpha, dur)
	await tw.finished
