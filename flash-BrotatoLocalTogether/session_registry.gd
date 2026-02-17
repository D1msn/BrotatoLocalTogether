extends Node

const BASE_DIR := "brotato_local_together"
const SESSIONS_DIR := "user://brotato_local_together/sessions"
const ACTIVE_SESSION_PATH := SESSIONS_DIR + "/active_session.json"
const SESSION_SCHEMA_VERSION := 1
const DEFAULT_TTL_SEC := 900

enum GamePhase {
	LOBBY,
	CHARACTER_SELECT,
	WEAPON_SELECT,
	DIFFICULTY_SELECT,
	MAIN,
	SHOP,
	POSTGAME,
}

const GAME_PHASE_NAME_TO_VALUE := {
	"LOBBY": GamePhase.LOBBY,
	"CHARACTER_SELECT": GamePhase.CHARACTER_SELECT,
	"WEAPON_SELECT": GamePhase.WEAPON_SELECT,
	"DIFFICULTY_SELECT": GamePhase.DIFFICULTY_SELECT,
	"MAIN": GamePhase.MAIN,
	"SHOP": GamePhase.SHOP,
	"POSTGAME": GamePhase.POSTGAME,
}

const GAME_PHASE_VALUE_TO_NAME := {
	GamePhase.LOBBY: "LOBBY",
	GamePhase.CHARACTER_SELECT: "CHARACTER_SELECT",
	GamePhase.WEAPON_SELECT: "WEAPON_SELECT",
	GamePhase.DIFFICULTY_SELECT: "DIFFICULTY_SELECT",
	GamePhase.MAIN: "MAIN",
	GamePhase.SHOP: "SHOP",
	GamePhase.POSTGAME: "POSTGAME",
}

const ALLOWED_TRANSITIONS := {
	GamePhase.LOBBY: [GamePhase.CHARACTER_SELECT, GamePhase.MAIN],
	GamePhase.CHARACTER_SELECT: [GamePhase.WEAPON_SELECT, GamePhase.DIFFICULTY_SELECT, GamePhase.LOBBY],
	GamePhase.WEAPON_SELECT: [GamePhase.DIFFICULTY_SELECT, GamePhase.CHARACTER_SELECT, GamePhase.LOBBY],
	GamePhase.DIFFICULTY_SELECT: [GamePhase.MAIN, GamePhase.LOBBY],
	GamePhase.MAIN: [GamePhase.SHOP, GamePhase.POSTGAME, GamePhase.LOBBY],
	GamePhase.SHOP: [GamePhase.MAIN, GamePhase.POSTGAME, GamePhase.LOBBY],
	GamePhase.POSTGAME: [GamePhase.LOBBY, GamePhase.CHARACTER_SELECT],
}


func parse_game_phase(phase_name: String) -> int:
	var normalized_phase = String(phase_name).strip_edges().to_upper()
	if GAME_PHASE_NAME_TO_VALUE.has(normalized_phase):
		return int(GAME_PHASE_NAME_TO_VALUE[normalized_phase])
	return -1


func game_phase_to_string(phase_value: int) -> String:
	if GAME_PHASE_VALUE_TO_NAME.has(phase_value):
		return String(GAME_PHASE_VALUE_TO_NAME[phase_value])
	return ""


func normalize_game_phase(phase_name: String) -> String:
	var phase_value = parse_game_phase(phase_name)
	if phase_value < 0:
		return ""
	return game_phase_to_string(phase_value)


func is_valid_phase_transition(from_phase: String, to_phase: String) -> bool:
	var from_value = parse_game_phase(from_phase)
	var to_value = parse_game_phase(to_phase)
	if from_value < 0 or to_value < 0:
		return false
	if from_value == to_value:
		return true
	if not ALLOWED_TRANSITIONS.has(from_value):
		return false
	var next_phases: Array = ALLOWED_TRANSITIONS[from_value]
	return to_value in next_phases


func load_active_session() -> Dictionary:
	var file := File.new()
	if not file.file_exists(ACTIVE_SESSION_PATH):
		return {}

	if file.open(ACTIVE_SESSION_PATH, File.READ) != OK:
		return {}

	var raw_text = file.get_as_text()
	file.close()

	var parsed = parse_json(raw_text)
	if not (parsed is Dictionary):
		return {}

	return parsed


func save_active_session(session_payload: Dictionary) -> bool:
	if session_payload.empty():
		return false

	if not _ensure_sessions_dir():
		return false

	var payload = session_payload.duplicate(true)
	payload["schema_version"] = SESSION_SCHEMA_VERSION

	var temp_path := SESSIONS_DIR + "/active_session.tmp"
	var file := File.new()
	if file.open(temp_path, File.WRITE) != OK:
		return false

	file.store_string(to_json(payload))
	file.close()

	var directory := Directory.new()
	if directory.open(SESSIONS_DIR) != OK:
		return false

	if directory.file_exists("active_session.json"):
		var _remove_result = directory.remove("active_session.json")

	return directory.rename("active_session.tmp", "active_session.json") == OK


func clear_active_session() -> void:
	var directory := Directory.new()
	if directory.open(SESSIONS_DIR) != OK:
		return

	if directory.file_exists("active_session.json"):
		var _remove_result = directory.remove("active_session.json")


func is_session_expired(session_payload: Dictionary) -> bool:
	if session_payload.empty():
		return true

	var now_unix = OS.get_unix_time()
	var expires_at = int(session_payload.get("expires_at_unix", 0))
	if expires_at <= 0:
		return true

	return now_unix > expires_at


func touch_session(session_payload: Dictionary, ttl_sec: int = DEFAULT_TTL_SEC) -> Dictionary:
	var payload = session_payload.duplicate(true)
	var now_unix = OS.get_unix_time()
	payload["updated_at_unix"] = now_unix
	payload["expires_at_unix"] = now_unix + max(60, ttl_sec)
	return payload


func create_session(host_endpoint: String, host_port: int, host_name: String, host_token: String, host_instance_id: String = "", session_id: String = "", ttl_sec: int = DEFAULT_TTL_SEC) -> Dictionary:
	var now_unix = OS.get_unix_time()
	var resolved_host_name = host_name.strip_edges()
	if resolved_host_name.empty():
		resolved_host_name = "Host"

	var resolved_token = host_token.strip_edges()
	if resolved_token.empty():
		resolved_token = _random_id()

	var resolved_instance_id = host_instance_id.strip_edges()
	if resolved_instance_id.empty():
		resolved_instance_id = _random_id()

	var resolved_session_id = session_id.strip_edges()
	if resolved_session_id.empty():
		resolved_session_id = _random_id()

	var payload = {
		"schema_version": SESSION_SCHEMA_VERSION,
		"status": "active",
		"session_id": resolved_session_id,
		"host_instance_id": resolved_instance_id,
		"host_endpoint": host_endpoint,
		"host_port": host_port,
		"created_at_unix": now_unix,
		"updated_at_unix": now_unix,
		"expires_at_unix": now_unix + max(60, ttl_sec),
		"players": [
			{
				"token": resolved_token,
				"display_name": resolved_host_name,
				"slot": 0,
				"connected": true,
				"peer_id": 1,
				"last_seen_unix": now_unix,
			}
		],
	}

	return payload


func restore_session_from_snapshot(snapshot_payload: Dictionary, host_endpoint: String, host_port: int, host_name: String, host_token: String, ttl_sec: int = DEFAULT_TTL_SEC) -> Dictionary:
	var now_unix = OS.get_unix_time()
	var restored_session_id = String(snapshot_payload.get("session_id", "")).strip_edges()
	var restored_instance_id = String(snapshot_payload.get("host_instance_id", "")).strip_edges()

	var payload = create_session(host_endpoint, host_port, host_name, host_token, restored_instance_id, restored_session_id, ttl_sec)

	if snapshot_payload.has("session_players") and snapshot_payload["session_players"] is Array:
		var restored_players : Array = snapshot_payload["session_players"]
		for restored_player in restored_players:
			if not (restored_player is Dictionary):
				continue

			var token = String(restored_player.get("token", "")).strip_edges()
			if token.empty():
				continue

			var display_name = String(restored_player.get("display_name", "Player"))
			var slot = int(restored_player.get("slot", -1))
			if slot < 0:
				continue

			if slot == 0:
				continue

			payload = upsert_player(payload, token, display_name, slot, false, -1)

	# Гарантируем, что хост-токен в слоте 0
	payload = upsert_player(payload, host_token, host_name, 0, true, 1)
	payload["updated_at_unix"] = now_unix
	payload["expires_at_unix"] = now_unix + max(60, ttl_sec)
	payload["status"] = "active"
	payload["host_endpoint"] = host_endpoint
	payload["host_port"] = host_port
	return payload


func upsert_player(session_payload: Dictionary, player_token: String, display_name: String, slot: int, connected: bool, peer_id: int = -1) -> Dictionary:
	var payload = session_payload.duplicate(true)
	var players : Array = payload.get("players", [])
	var now_unix = OS.get_unix_time()
	var clean_token = player_token.strip_edges()
	if clean_token.empty():
		return payload

	var clean_name = display_name.strip_edges()
	if clean_name.empty():
		clean_name = "Player"

	var found_index = -1
	for index in range(players.size()):
		var player_data = players[index]
		if not (player_data is Dictionary):
			continue
		if String(player_data.get("token", "")) == clean_token:
			found_index = index
			break

	var player_payload = {
		"token": clean_token,
		"display_name": clean_name,
		"slot": slot,
		"connected": connected,
		"peer_id": peer_id,
		"last_seen_unix": now_unix,
	}

	if found_index == -1:
		players.push_back(player_payload)
	else:
		players[found_index] = player_payload

	payload["players"] = players
	return payload


func find_player_by_token(session_payload: Dictionary, player_token: String) -> Dictionary:
	if session_payload.empty():
		return {}

	var players : Array = session_payload.get("players", [])
	for player_data in players:
		if not (player_data is Dictionary):
			continue
		if String(player_data.get("token", "")) == player_token:
			return player_data

	return {}


func find_player_by_peer(session_payload: Dictionary, peer_id: int) -> Dictionary:
	if session_payload.empty():
		return {}

	var players : Array = session_payload.get("players", [])
	for player_data in players:
		if not (player_data is Dictionary):
			continue
		if int(player_data.get("peer_id", -1)) == peer_id:
			return player_data

	return {}


func mark_player_disconnected_by_peer(session_payload: Dictionary, peer_id: int) -> Dictionary:
	var payload = session_payload.duplicate(true)
	var players : Array = payload.get("players", [])
	for index in range(players.size()):
		var player_data = players[index]
		if not (player_data is Dictionary):
			continue
		if int(player_data.get("peer_id", -1)) != peer_id:
			continue

		player_data["connected"] = false
		player_data["peer_id"] = -1
		player_data["last_seen_unix"] = OS.get_unix_time()
		players[index] = player_data
		break

	payload["players"] = players
	return payload


func allocate_slot(session_payload: Dictionary, max_players: int) -> int:
	var used_slots := {}
	var players : Array = session_payload.get("players", [])
	for player_data in players:
		if not (player_data is Dictionary):
			continue
		var slot = int(player_data.get("slot", -1))
		if slot >= 0:
			used_slots[slot] = true

	for slot in range(1, max_players):
		if not used_slots.has(slot):
			return slot

	return -1


func _ensure_sessions_dir() -> bool:
	var directory := Directory.new()
	if directory.open("user://") != OK:
		return false

	if not directory.dir_exists(BASE_DIR):
		if directory.make_dir(BASE_DIR) != OK:
			return false

	if directory.change_dir(BASE_DIR) != OK:
		return false

	if not directory.dir_exists("sessions"):
		if directory.make_dir("sessions") != OK:
			return false

	return true


func _random_id() -> String:
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	return "%08x%08x%08x%08x" % [rng.randi(), rng.randi(), rng.randi(), rng.randi()]
