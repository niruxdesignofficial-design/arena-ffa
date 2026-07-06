# Sfx.gd (autoload)
# Sonidos 100% procedurales (sintetizados al arrancar): disparos por arma,
# hitmarker, headshot, kill, muerte, recarga, UI, countdown. Sin assets de
# audio externos; el volumen sale del bus Master (Ajustes).
extends Node

const SAMPLE_RATE := 22050

var _streams := {}
var _rng := RandomNumberGenerator.new()
var _headless := false

func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	if _headless:
		return
	_rng.seed = 12345
	_streams["pistol"] = _gunshot(0.13, 260.0, 0.75, 14.0)
	_streams["smg"] = _gunshot(0.09, 320.0, 0.55, 22.0)
	_streams["shotgun"] = _gunshot(0.30, 130.0, 1.0, 9.0)
	_streams["rifle"] = _gunshot(0.16, 200.0, 0.8, 16.0)
	_streams["sniper"] = _gunshot(0.42, 95.0, 1.0, 7.0)
	_streams["knife"] = _whoosh(0.14)
	_streams["hit"] = _blip(880.0, 0.05, 0.35)
	_streams["headshot"] = _twoblip(980.0, 1320.0, 0.10, 0.5)
	_streams["kill"] = _twoblip(660.0, 990.0, 0.16, 0.45)
	_streams["hurt"] = _blip(160.0, 0.09, 0.5)
	_streams["death"] = _slide(320.0, 70.0, 0.45, 0.5)
	_streams["respawn"] = _slide(300.0, 720.0, 0.22, 0.35)
	_streams["reload"] = _click_pair()
	_streams["ui"] = _blip(1150.0, 0.035, 0.25)
	_streams["count"] = _blip(620.0, 0.07, 0.4)
	_streams["go"] = _twoblip(740.0, 1100.0, 0.18, 0.5)
	_streams["pickup"] = _twoblip(520.0, 780.0, 0.12, 0.4)
	_streams["empty"] = _blip(300.0, 0.04, 0.3)
	_streams["step"] = _step()
	_streams["streak"] = _twoblip(880.0, 1320.0, 0.22, 0.5)
	_streams["chat"] = _blip(1500.0, 0.03, 0.2)
	_streams["whiz"] = _whiz()

func play(sound: String, vol_db := 0.0, pitch := 1.0) -> void:
	if _headless or not _streams.has(sound):
		return
	var p := AudioStreamPlayer.new()
	p.stream = _streams[sound]
	p.volume_db = vol_db
	p.pitch_scale = clampf(pitch * randf_range(0.94, 1.06), 0.1, 3.0)
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()

## Sonido posicional en el mundo (disparos de otros, etc.).
func play3d(sound: String, pos: Vector3, vol_db := 0.0) -> void:
	if _headless or not _streams.has(sound):
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = _streams[sound]
	p.volume_db = vol_db
	p.pitch_scale = randf_range(0.94, 1.06)
	p.max_distance = 90.0
	p.unit_size = 8.0
	scene.add_child(p)
	p.global_position = pos
	p.finished.connect(p.queue_free)
	p.play()

# SÍNTESIS

func _make(seconds: float, fn: Callable) -> AudioStreamWAV:
	var frames := int(seconds * SAMPLE_RATE)
	var data := PackedByteArray()
	data.resize(frames * 2)
	for i in frames:
		var v: float = clampf(fn.call(float(i) / SAMPLE_RATE), -1.0, 1.0)
		data.encode_s16(i * 2, int(v * 32000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	wav.data = data
	return wav

## Disparo: ráfaga de ruido con decaimiento + golpe grave.
func _gunshot(dur: float, thump_hz: float, amp: float, decay: float) -> AudioStreamWAV:
	return _make(dur, func(t: float) -> float:
		var env := exp(-t * decay)
		var noise := _rng.randf_range(-1.0, 1.0) * env * 0.7
		var thump := sin(TAU * thump_hz * t) * exp(-t * decay * 1.6) * 0.8
		return (noise + thump) * amp)

func _whoosh(dur: float) -> AudioStreamWAV:
	return _make(dur, func(t: float) -> float:
		var env := sin(PI * t / dur)
		return _rng.randf_range(-1.0, 1.0) * env * env * 0.35)

func _blip(hz: float, dur: float, amp: float) -> AudioStreamWAV:
	return _make(dur, func(t: float) -> float:
		return sin(TAU * hz * t) * exp(-t * 30.0) * amp)

func _twoblip(hz1: float, hz2: float, dur: float, amp: float) -> AudioStreamWAV:
	return _make(dur, func(t: float) -> float:
		var hz := hz1 if t < dur * 0.5 else hz2
		var lt := fmod(t, dur * 0.5)
		return sin(TAU * hz * t) * exp(-lt * 24.0) * amp)

func _slide(hz_from: float, hz_to: float, dur: float, amp: float) -> AudioStreamWAV:
	return _make(dur, func(t: float) -> float:
		var k := t / dur
		var hz := lerpf(hz_from, hz_to, k)
		return sin(TAU * hz * t) * (1.0 - k) * amp)

## Paso: golpecito sordo de ruido filtrado.
func _step() -> AudioStreamWAV:
	return _make(0.07, func(t: float) -> float:
		var env := exp(-t * 60.0)
		return (_rng.randf_range(-1.0, 1.0) * 0.35 + sin(TAU * 95.0 * t) * 0.5) * env * 0.5)

## Bala pasando cerca: barrido corto de ruido agudo.
func _whiz() -> AudioStreamWAV:
	return _make(0.12, func(t: float) -> float:
		var k := t / 0.12
		var env := sin(PI * k)
		return _rng.randf_range(-1.0, 1.0) * env * env * 0.3 * (1.0 - k * 0.5))

func _click_pair() -> AudioStreamWAV:
	return _make(0.16, func(t: float) -> float:
		var lt := t if t < 0.08 else t - 0.08
		return _rng.randf_range(-1.0, 1.0) * exp(-lt * 90.0) * 0.4)
