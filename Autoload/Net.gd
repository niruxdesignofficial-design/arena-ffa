# Net.gd (autoload)
# Sesión multijugador free-for-all sobre ENet (Godot high-level multiplayer).
# El anfitrión es el SERVIDOR AUTORITATIVO: acá viven el registro de
# jugadores, los puntajes (kills/muertes/racha), el reloj de ronda y el
# fin de ronda. Los clientes solo reciben réplicas: nunca deciden kills
# ni el orden del scoreboard.
extends Node

signal players_changed
signal kill_feed(text: String)
signal round_time_changed(seconds_left: int)
signal session_closed(reason: String)
signal lobby_joined
signal lan_search_done(hosts: Array)
signal countdown_started(seconds: float)
signal round_reset(winner_name: String, winner_kills: int)

const PORT := 8910
const DISCOVERY_PORT := 8911
const MAX_PLAYERS := 8
const ARENA_SCENE := "res://Levels/Arena.tscn"
const MENU_SCENE := "res://UI/Menus/Menu.tscn"

# Reglas de ronda (vars para que AutoTest pueda acortar rondas de prueba).
var kill_limit := 10
var round_seconds_total := 300

# peer_id -> {name, character, kills, deaths, streak}
var players := {}
var in_match := false
var round_seconds_left := 0
# Snapshot del final de la última ronda: {"players": {...}, "winner": id, "my_id": id}
var last_results := {}
# Servidor dedicado (headless, sin jugador propio) y líder de sala (quien
# puede arrancar la partida / revancha cuando el server es dedicado).
var dedicated := false
var leader_id := 1

const COUNTDOWN_SECONDS := 3.0
# Nombres tipo "jugador real" para que la sala parezca poblada.
const BOT_NAMES: Array[String] = [
	"Shadow23", "xKiraa", "NoScope_L", "Ferchu", "Dark_YT", "TrigZ",
	"pau.exe", "KevinAR", "Lautaro7", "M4ti", "juampi", "Sofi_k",
]
const INFINITE_ROUND_SECONDS := 1800 # el dashboard se resetea cada 30 min
const INFINITE_TARGET_PLAYERS := 6 # bots + humanos que mantiene el server
const HISTORY_PATH := "user://match_history.json"

# Partida única infinita (server dedicado): nunca termina; cada 30 min se
# guarda el resultado en disco y el scoreboard arranca de cero.
var infinite := false

# Momento (reloj local) hasta el que el fuego está bloqueado (countdown).
var _fire_unlock_at := 0.0
var _next_bot_id := 0

var _discovery := PacketPeerUDP.new()
var _discovery_active := false
var _round_accum := 0.0
var _arena_ready_peers := {}

func fire_locked() -> bool:
	return Time.get_ticks_msec() / 1000.0 < _fire_unlock_at

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _process(delta: float) -> void:
	_poll_discovery()
	_tick_round(delta)

# SESIÓN

func session_active() -> bool:
	return multiplayer.multiplayer_peer != null \
		and multiplayer.multiplayer_peer is WebSocketMultiplayerPeer

func is_session_server() -> bool:
	return session_active() and multiplayer.is_server()

func my_id() -> int:
	return multiplayer.get_unique_id() if session_active() else 0

## ¿Puedo arrancar la partida/revancha? (host de sala, o líder si el server es dedicado)
func i_am_leader() -> bool:
	if not session_active():
		return false
	if is_session_server():
		return not dedicated
	return my_id() == leader_id

## Puerto de escucha: en hostings tipo Render viene por la env var PORT.
func listen_port() -> int:
	var env := OS.get_environment("PORT")
	return int(env) if env.is_valid_int() and int(env) > 0 else PORT

## Crear sala (nativo/headless; el navegador no puede escuchar puertos).
## Devuelve "" si salió bien, o el mensaje de error.
func host() -> String:
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_server(listen_port()) != OK:
		return "Couldn't create the room (is port %d in use?)" % listen_port()
	multiplayer.multiplayer_peer = peer
	dedicated = false
	leader_id = 1
	players = {1: _me_entry()}
	in_match = false
	_start_discovery()
	players_changed.emit()
	return ""

## Servidor dedicado: escucha sin jugar; el primer cliente es el líder.
func host_dedicated() -> String:
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_server(listen_port()) != OK:
		return "Couldn't open port %d" % listen_port()
	multiplayer.multiplayer_peer = peer
	dedicated = true
	leader_id = 0
	players = {}
	in_match = false
	_start_discovery()
	players_changed.emit()
	print("[Net] Dedicated server listening on port %d" % listen_port())
	return ""

## Unirse a una sala por IP, host:puerto, dominio o URL ws(s)://.
## Dominios pelados (ej. mi-server.onrender.com) asumen wss:// (TLS, puerto
## 443): es lo que usan Render y cualquier hosting detrás de proxy https.
## Resultado async: lobby_joined / session_closed.
func join(address: String) -> String:
	var url := address.strip_edges()
	if url.is_empty():
		return "Invalid address"
	if not url.begins_with("ws://") and not url.begins_with("wss://"):
		var bare := url.split(":")[0]
		if bare.is_valid_ip_address() or bare == "localhost":
			url = "ws://%s" % url if url.contains(":") else "ws://%s:%d" % [url, PORT]
		elif url.contains(":"):
			url = "ws://%s" % url
		else:
			url = "wss://%s" % url
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_client(url) != OK:
		return "Invalid address"
	multiplayer.multiplayer_peer = peer
	return ""

func leave() -> void:
	_stop_discovery()
	if session_active():
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	players = {}
	in_match = false
	players_changed.emit()

func _me_entry() -> Dictionary:
	return {
		"name": GameSettings.player_name,
		"character": GameSettings.character_id if not GameSettings.character_id.is_empty() else CharacterLib.default_id(),
		"kills": 0, "deaths": 0, "streak": 0, "score": 0,
	}

# CALLBACKS DE CONEXIÓN

func _on_peer_connected(id: int) -> void:
	if is_session_server() and in_match and not infinite:
		# En salas por ronda no se puede entrar con la ronda en curso.
		multiplayer.multiplayer_peer.disconnect_peer(id)

func _on_peer_disconnected(id: int) -> void:
	if is_session_server() and players.has(id):
		players.erase(id)
		_arena_ready_peers.erase(id)
		if dedicated and leader_id == id:
			# Nuevo líder: el humano (id positivo) más antiguo; nunca un bot.
			var humans := players.keys().filter(func(k): return int(k) > 0)
			humans.sort()
			leader_id = humans[0] if not humans.is_empty() else 0
		_balance_bots()
		_broadcast_players()

func _on_connected_to_server() -> void:
	srv_register.rpc_id(1, GameSettings.player_name,
		GameSettings.character_id if not GameSettings.character_id.is_empty() else CharacterLib.default_id())

func _on_connection_failed() -> void:
	leave()
	session_closed.emit("Couldn't connect to the room.")

func _on_server_disconnected() -> void:
	var was_in_match := in_match
	leave()
	session_closed.emit("The host closed the room.")
	if was_in_match:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		Transition.change_scene(MENU_SCENE)

# REGISTRO Y RÉPLICA DE JUGADORES (server-authoritative)

@rpc("any_peer", "reliable")
func srv_register(pname: String, character: String) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if in_match and not infinite:
		multiplayer.multiplayer_peer.disconnect_peer(id)
		return
	players[id] = {
		"name": pname.strip_edges().substr(0, 18) if not pname.strip_edges().is_empty() else "Player %d" % id,
		"character": character,
		"kills": 0, "deaths": 0, "streak": 0, "score": 0,
	}
	if dedicated and (leader_id == 0 or not players.has(leader_id)):
		leader_id = id
	_balance_bots()
	_broadcast_players()
	if infinite and in_match:
		# Drop-in: el nuevo jugador entra directo a la partida en curso.
		cl_start_match.rpc_id(id)

func _broadcast_players() -> void:
	cl_sync_players.rpc(players, leader_id)
	players_changed.emit()

@rpc("authority", "reliable")
func cl_sync_players(replica: Dictionary, leader: int) -> void:
	players = replica
	leader_id = leader
	players_changed.emit()
	if not in_match:
		lobby_joined.emit()

## Orden oficial del scoreboard (se calcula sobre la réplica del server).
func sorted_ids(source: Dictionary = {}) -> Array:
	var src := source if not source.is_empty() else players
	var ids := src.keys()
	ids.sort_custom(func(a, b):
		var pa: Dictionary = src[a]
		var pb: Dictionary = src[b]
		if pa["kills"] != pb["kills"]:
			return pa["kills"] > pb["kills"]
		if int(pa.get("score", 0)) != int(pb.get("score", 0)):
			return int(pa.get("score", 0)) > int(pb.get("score", 0))
		if pa["deaths"] != pb["deaths"]:
			return pa["deaths"] < pb["deaths"]
		return String(pa["name"]) < String(pb["name"]))
	return ids

## Id del jugador que va primero en el scoreboard (no confundir con leader_id,
## que es quien controla el arranque de partida en server dedicado).
func top_player_id() -> int:
	var ids := sorted_ids()
	return ids[0] if not ids.is_empty() else 0

# BOTS (viven en el server; el líder los agrega/quita desde el lobby)

func request_add_bot() -> void:
	if not i_am_leader():
		return
	if is_session_server():
		_srv_do_add_bot()
	else:
		srv_add_bot.rpc_id(1)

func request_remove_bot() -> void:
	if not i_am_leader():
		return
	if is_session_server():
		_srv_do_remove_bot()
	else:
		srv_remove_bot.rpc_id(1)

@rpc("any_peer", "reliable")
func srv_add_bot() -> void:
	if multiplayer.is_server() and multiplayer.get_remote_sender_id() == leader_id:
		_srv_do_add_bot()

@rpc("any_peer", "reliable")
func srv_remove_bot() -> void:
	if multiplayer.is_server() and multiplayer.get_remote_sender_id() == leader_id:
		_srv_do_remove_bot()

func _srv_do_add_bot() -> void:
	if in_match or players.size() >= MAX_PLAYERS:
		return
	_next_bot_id -= 1
	var ids := CharacterLib.get_ids()
	players[_next_bot_id] = {
		"name": BOT_NAMES[absi(_next_bot_id) % BOT_NAMES.size()],
		"character": ids[absi(_next_bot_id) % maxi(ids.size(), 1)] if not ids.is_empty() else "",
		"kills": 0, "deaths": 0, "streak": 0, "score": 0, "bot": true,
	}
	_broadcast_players()

func _srv_do_remove_bot() -> void:
	if in_match:
		return
	var bot_ids := players.keys().filter(func(k): return int(k) < 0)
	if bot_ids.is_empty():
		return
	bot_ids.sort()
	players.erase(bot_ids[0])
	_broadcast_players()

## Mantiene la sala poblada: en modo infinito el server suma/quita bots
## para que siempre parezca una partida online real.
func _balance_bots() -> void:
	if not (is_session_server() and infinite):
		return
	var changed := false
	while players.size() < INFINITE_TARGET_PLAYERS:
		_next_bot_id -= 1
		var ids := CharacterLib.get_ids()
		players[_next_bot_id] = {
			"name": BOT_NAMES[absi(_next_bot_id) % BOT_NAMES.size()],
			"character": ids[absi(_next_bot_id) % maxi(ids.size(), 1)] if not ids.is_empty() else "",
			"kills": 0, "deaths": 0, "streak": 0, "score": 0, "bot": true,
		}
		changed = true
	# Si se llena de humanos, los bots van saliendo.
	var bot_ids := players.keys().filter(func(k): return int(k) < 0)
	while players.size() > MAX_PLAYERS and not bot_ids.is_empty():
		players.erase(bot_ids.pop_back())
		changed = true
	if changed:
		players_changed.emit()

## Modo producción: partida única infinita con reset periódico del dashboard.
func begin_infinite() -> void:
	if not is_session_server():
		return
	infinite = true
	round_seconds_total = INFINITE_ROUND_SECONDS if round_seconds_total == 300 else round_seconds_total
	_balance_bots()
	_broadcast_players()
	start_match()
	print("[Net] Infinite match started; dashboard resets every %d s" % round_seconds_total)

## Fin de ciclo en modo infinito: guarda el resultado y arranca de cero
## sin echar a nadie de la partida.
func _soft_reset_round() -> void:
	var winner: int = top_player_id()
	var winner_name: String = String(players.get(winner, {}).get("name", "?"))
	var winner_kills: int = int(players.get(winner, {}).get("kills", 0))
	_save_history(winner_name)
	for id in players:
		players[id]["kills"] = 0
		players[id]["deaths"] = 0
		players[id]["streak"] = 0
		players[id]["score"] = 0
	round_seconds_left = round_seconds_total
	_broadcast_players()
	cl_round_reset.rpc(winner_name, winner_kills)
	round_reset.emit(winner_name, winner_kills)
	print("[Net] Dashboard reset; last winner: %s (%d kills)" % [winner_name, winner_kills])

@rpc("authority", "reliable")
func cl_round_reset(winner_name: String, winner_kills: int) -> void:
	round_reset.emit(winner_name, winner_kills)

## Historial en disco (user://match_history.json): un registro por ciclo.
func _save_history(winner_name: String) -> void:
	var history := []
	if FileAccess.file_exists(HISTORY_PATH):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(HISTORY_PATH))
		if typeof(parsed) == TYPE_ARRAY:
			history = parsed
	var standings := []
	for id in sorted_ids():
		var pl: Dictionary = players[id]
		standings.append({
			"name": pl["name"], "kills": int(pl["kills"]),
			"deaths": int(pl["deaths"]), "score": int(pl.get("score", 0)),
		})
	history.append({
		"ended_at": Time.get_datetime_string_from_system(true),
		"duration_seconds": round_seconds_total,
		"winner": winner_name,
		"standings": standings,
	})
	while history.size() > 100:
		history.pop_front()
	var f := FileAccess.open(HISTORY_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(history, "\t"))
		f.close()

# ARRANQUE DE PARTIDA

## Punto de entrada para la UI: el líder pide arrancar (partida o revancha).
func request_start() -> void:
	if not i_am_leader():
		return
	if is_session_server():
		start_match()
	else:
		srv_request_start.rpc_id(1)

@rpc("any_peer", "reliable")
func srv_request_start() -> void:
	if multiplayer.is_server() and multiplayer.get_remote_sender_id() == leader_id:
		start_match()

func start_match() -> void:
	if not is_session_server() or in_match or players.is_empty():
		return
	for id in players:
		players[id]["kills"] = 0
		players[id]["deaths"] = 0
		players[id]["streak"] = 0
		players[id]["score"] = 0
	_arena_ready_peers = {}
	_broadcast_players()
	cl_start_match.rpc()
	_local_start_match()

@rpc("authority", "reliable")
func cl_start_match() -> void:
	_local_start_match()

func _local_start_match() -> void:
	print("[Net] entering match (scene -> Arena)")
	in_match = true
	round_seconds_left = round_seconds_total
	last_results = {}
	Transition.change_scene(ARENA_SCENE)

## La Arena de cada peer avisa cuando terminó de cargar; el server recién
## spawnea jugadores cuando todos están listos.
func notify_arena_ready() -> void:
	if is_session_server():
		_mark_arena_ready(1)
	else:
		srv_arena_ready.rpc_id(1)

@rpc("any_peer", "reliable")
func srv_arena_ready() -> void:
	if multiplayer.is_server():
		_mark_arena_ready(multiplayer.get_remote_sender_id())

func _mark_arena_ready(id: int) -> void:
	_arena_ready_peers[id] = true
	var arena := get_tree().current_scene
	if arena and arena.has_method("on_peer_ready"):
		arena.on_peer_ready(id)

## Countdown de arranque: nadie puede disparar hasta que termina.
func begin_countdown() -> void:
	if not is_session_server():
		return
	_fire_unlock_at = Time.get_ticks_msec() / 1000.0 + COUNTDOWN_SECONDS
	cl_countdown.rpc(COUNTDOWN_SECONDS)
	countdown_started.emit(COUNTDOWN_SECONDS)

@rpc("authority", "reliable")
func cl_countdown(seconds: float) -> void:
	_fire_unlock_at = Time.get_ticks_msec() / 1000.0 + seconds
	countdown_started.emit(seconds)

# PUNTAJE (solo el server muta)

func register_kill(killer_id: int, victim_id: int, headshot := false) -> void:
	if not multiplayer.is_server() or not in_match:
		return
	var victim_name: String = players[victim_id]["name"] if players.has(victim_id) else "?"
	if players.has(victim_id):
		players[victim_id]["deaths"] += 1
		players[victim_id]["streak"] = 0
	var feed: String
	if killer_id != victim_id and players.has(killer_id):
		players[killer_id]["kills"] += 1
		players[killer_id]["streak"] += 1
		players[killer_id]["score"] = int(players[killer_id].get("score", 0)) + 100 + (50 if headshot else 0)
		feed = "%s eliminated %s" % [players[killer_id]["name"], victim_name]
		if headshot:
			feed += " ☠ HEADSHOT"
		if players[killer_id]["streak"] >= 3:
			feed += " (streak x%d)" % players[killer_id]["streak"]
	else:
		feed = "%s took themselves out" % victim_name
	_broadcast_players()
	cl_kill_feed.rpc(feed)
	kill_feed.emit(feed)
	if not infinite and killer_id != victim_id and players.has(killer_id) \
			and players[killer_id]["kills"] >= kill_limit:
		end_round()

@rpc("authority", "reliable")
func cl_kill_feed(text: String) -> void:
	kill_feed.emit(text)

# RELOJ DE RONDA (server)

func _tick_round(delta: float) -> void:
	if not is_session_server() or not in_match:
		return
	_round_accum += delta
	if _round_accum < 1.0:
		return
	_round_accum -= 1.0
	round_seconds_left -= 1
	cl_time.rpc(round_seconds_left)
	round_time_changed.emit(round_seconds_left)
	if round_seconds_left <= 0:
		if infinite:
			_soft_reset_round()
		else:
			end_round()

@rpc("authority", "unreliable_ordered")
func cl_time(seconds: int) -> void:
	round_seconds_left = seconds
	round_time_changed.emit(seconds)

# FIN DE RONDA

func end_round() -> void:
	if not is_session_server() or not in_match:
		return
	var winner: int = top_player_id()
	cl_end_round.rpc(players.duplicate(true), winner)
	_local_end_round(players.duplicate(true), winner)

@rpc("authority", "reliable")
func cl_end_round(final_players: Dictionary, winner_id: int) -> void:
	_local_end_round(final_players, winner_id)

func _local_end_round(final_players: Dictionary, winner_id: int) -> void:
	if not in_match:
		return
	in_match = false
	last_results = {"players": final_players, "winner": winner_id, "my_id": my_id()}
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	Transition.change_scene(MENU_SCENE)

# DESCUBRIMIENTO LAN ("Buscar partida")

func _start_discovery() -> void:
	if _discovery.bind(DISCOVERY_PORT) == OK:
		_discovery_active = true
	else:
		push_warning("[Net] No se pudo abrir el puerto de descubrimiento LAN.")

func _stop_discovery() -> void:
	if _discovery_active:
		_discovery.close()
		_discovery_active = false

func _poll_discovery() -> void:
	if not _discovery_active:
		return
	while _discovery.get_available_packet_count() > 0:
		var msg := _discovery.get_packet().get_string_from_utf8()
		var ip := _discovery.get_packet_ip()
		var port := _discovery.get_packet_port()
		if msg == "FFA_FIND" and not in_match:
			_discovery.set_dest_address(ip, port)
			_discovery.put_packet(("FFA_HOST:" + GameSettings.player_name).to_utf8_buffer())

## Busca salas en la red local; emite lan_search_done([{ip, name}, ...]).
func search_lan(timeout := 1.2) -> void:
	var sock := PacketPeerUDP.new()
	sock.bind(0)
	sock.set_broadcast_enabled(true)
	for dest in ["255.255.255.255", "127.0.0.1"]:
		sock.set_dest_address(dest, DISCOVERY_PORT)
		sock.put_packet("FFA_FIND".to_utf8_buffer())
	var found := {}
	var elapsed := 0.0
	while elapsed < timeout:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
		while sock.get_available_packet_count() > 0:
			var msg := sock.get_packet().get_string_from_utf8()
			var ip := sock.get_packet_ip()
			if msg.begins_with("FFA_HOST:"):
				found[ip] = msg.substr(9)
	sock.close()
	var hosts := []
	for ip in found:
		hosts.append({"ip": ip, "name": found[ip]})
	lan_search_done.emit(hosts)
