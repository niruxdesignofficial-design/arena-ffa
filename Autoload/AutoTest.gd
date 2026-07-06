# AutoTest.gd (autoload)
# Harness de verificación: permite correr dos instancias que se conectan,
# juegan y terminan una ronda solas, sacando capturas. Inactivo salvo que
# se pase `-- autotest=...` por línea de comandos. No afecta el juego normal.
extends Node

var autopilot := false

var _mode := ""
var _shot_dir := ""
var _shot_i := 0
var _did_rematch := false
var _join_ip := "127.0.0.1"
var _min_players := 2
var _bots := 0

func _gather_args() -> PackedStringArray:
	var args := OS.get_cmdline_user_args()
	if OS.has_feature("web"):
		# En web los args llegan por query string: ?autotest=join&ip=x
		var qs = JavaScriptBridge.eval("location.search", true)
		if qs != null and String(qs).begins_with("?"):
			for pair in String(qs).substr(1).split("&"):
				args.append(pair)
	return args

func _ready() -> void:
	for a in _gather_args():
		if a.begins_with("autotest="):
			_mode = a.substr("autotest=".length())
		elif a.begins_with("shots="):
			_shot_dir = a.substr("shots=".length())
		elif a.begins_with("quit="):
			var secs := float(a.substr("quit=".length()))
			get_tree().create_timer(secs).timeout.connect(func(): get_tree().quit())
		elif a.begins_with("killlimit="):
			Net.kill_limit = int(a.substr("killlimit=".length()))
		elif a.begins_with("roundsecs="):
			Net.round_seconds_total = int(a.substr("roundsecs=".length()))
		elif a.begins_with("ip="):
			_join_ip = a.substr("ip=".length())
		elif a.begins_with("minplayers="):
			_min_players = int(a.substr("minplayers=".length()))
		elif a.begins_with("bots="):
			_bots = int(a.substr("bots=".length()))
		elif a == "server":
			# Servidor dedicado de producción: el líder decide cuándo empezar.
			_mode = "dedicated"
	if _mode.is_empty():
		return
	print("[AutoTest] modo=", _mode)
	if not _shot_dir.is_empty():
		var t := Timer.new()
		t.wait_time = 2.0
		t.timeout.connect(_screenshot)
		add_child(t)
		t.start()
	match _mode:
		"host":
			autopilot = true
			_run_host()
		"solo":
			autopilot = true
			_run_solo()
		"overview":
			_run_overview()
		"server":
			_run_server()
		"dedicated":
			_run_dedicated()
		"join":
			autopilot = true
			_run_join()
		"menu":
			_run_menu_tour()

func _screenshot() -> void:
	# En partida, alternar el scoreboard para que salga en capturas.
	var mhud := get_tree().get_first_node_in_group("match-ui")
	if mhud:
		mhud.set_scoreboard_visible(_shot_i % 3 == 1)
	var img := get_viewport().get_texture().get_image()
	if img:
		_shot_i += 1
		img.save_png("%s/%s_%03d.png" % [_shot_dir, _mode, _shot_i])

func _run_host() -> void:
	await get_tree().create_timer(1.5).timeout
	GameSettings.player_name = "ANA-HOST"
	GameSettings.character_id = CharacterLib.default_id()
	var err := Net.host()
	print("[AutoTest] host: ", "OK" if err.is_empty() else err)
	# Esperar al segundo jugador.
	var waited := 0.0
	while Net.players.size() < 2 and waited < 40.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
	print("[AutoTest] jugadores en sala: ", Net.players.size())
	await get_tree().create_timer(1.0).timeout
	Net.start_match()
	# Cuando termine la ronda, una revancha automática y listo.
	while true:
		await get_tree().create_timer(1.0).timeout
		if not Net.in_match and not Net.last_results.is_empty() and not _did_rematch:
			print("[AutoTest] ronda terminada; ganador id=", Net.last_results.get("winner"))
			_did_rematch = true
			await get_tree().create_timer(5.0).timeout
			Net.start_match()

func _run_solo() -> void:
	await get_tree().create_timer(1.2).timeout
	GameSettings.player_name = "SOLO-BOT"
	GameSettings.character_id = CharacterLib.default_id()
	Net.host()
	for i in _bots:
		Net._srv_do_add_bot()
	await get_tree().create_timer(0.5).timeout
	Net.start_match()

func _run_overview() -> void:
	await get_tree().create_timer(1.2).timeout
	GameSettings.player_name = "VISTA"
	GameSettings.character_id = CharacterLib.default_id()
	var err := Net.host()
	print("[AutoTest] overview host: ", "OK" if err.is_empty() else err)
	await get_tree().create_timer(0.5).timeout
	Net.start_match()
	print("[AutoTest] overview in_match=", Net.in_match)
	await get_tree().create_timer(2.5).timeout
	print("[AutoTest] overview scene=", get_tree().current_scene.name if get_tree().current_scene else "none")
	var cam := Camera3D.new()
	cam.position = Vector3(0, 52, 34)
	get_tree().current_scene.add_child(cam)
	cam.look_at(Vector3.ZERO)
	cam.make_current()
	await get_tree().create_timer(4.0).timeout
	# Segunda vista: a nivel de piso desde una esquina.
	cam.position = Vector3(-18, 3.5, -6)
	cam.look_at(Vector3(8, 1, 10))

func _run_join() -> void:
	await get_tree().create_timer(3.0).timeout
	GameSettings.player_name = "BOT-%d" % (randi() % 100)
	var ids := CharacterLib.get_ids()
	GameSettings.character_id = ids[randi() % ids.size()]
	var err := Net.join(_join_ip)
	print("[AutoTest] join: ", "OK" if err.is_empty() else err)

func _run_dedicated() -> void:
	await get_tree().create_timer(0.5).timeout
	var err := Net.host_dedicated()
	if not err.is_empty():
		printerr("[Server] " + err)
		get_tree().quit(1)
		return
	# Producción = partida única infinita (bots automáticos, reset cada 30 min).
	Net.begin_infinite()

## Servidor dedicado de prueba: arranca solo cuando hay jugadores, y tras
## el fin de ronda lanza una revancha automática.
func _run_server() -> void:
	await get_tree().create_timer(0.8).timeout
	var err := Net.host_dedicated()
	print("[AutoTest] server dedicado: ", "OK" if err.is_empty() else err)
	while true:
		await get_tree().create_timer(1.0).timeout
		if not Net.in_match and Net.players.size() >= _min_players:
			if Net.last_results.is_empty():
				print("[AutoTest] arrancando partida con %d jugadores" % Net.players.size())
				Net.start_match()
			elif not _did_rematch:
				_did_rematch = true
				print("[AutoTest] ronda terminada; ganador id=", Net.last_results.get("winner"))
				await get_tree().create_timer(4.0).timeout
				Net.start_match()

func _run_menu_tour() -> void:
	await get_tree().create_timer(1.2).timeout
	var menu := get_tree().get_first_node_in_group("menu")
	if menu == null:
		return
	for screen in [0, 1, 3, 2, 0]: # MAIN, CHARACTER, SETTINGS, LOBBY, MAIN
		menu.goto(screen)
		await get_tree().create_timer(2.2).timeout
