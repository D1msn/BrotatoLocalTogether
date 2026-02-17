extends "res://mods-unpacked/flash-BrotatoLocalTogether/protocol_connection.gd"

const SessionPersistence = preload("res://mods-unpacked/flash-BrotatoLocalTogether/session_persistence.gd")
const SessionRegistry = preload("res://mods-unpacked/flash-BrotatoLocalTogether/session_registry.gd")

const SESSION_MESSAGE_REGISTER_CLIENT := 10000
const SESSION_MESSAGE_LOBBY_SYNC := 10001
const SESSION_MESSAGE_GLOBAL_CHAT := 10002
const SESSION_MESSAGE_LOBBY_CHAT := 10003
const SESSION_MESSAGE_REGISTER_ACK := 10004
const SESSION_MESSAGE_REGISTER_REJECT := 10005
const SESSION_MESSAGE_RECOVERY_STATE := 10006

const ACTIVE_LOBBY_ID := 1
const HOST_PEER_ID := 1
const MAX_PLAYERS := 4
const SNAPSHOT_INTERVAL_MSEC := 3000
const SESSION_TTL_SEC := 900
const PROTOCOL_VERSION := 1
const ENVELOPE_MAX_SEQ := 2147483647
const ENVELOPE_KEY_PROTOCOL_VERSION := "PROTOCOL_VERSION"
const ENVELOPE_KEY_MESSAGE_TYPE := "MESSAGE_TYPE"
const ENVELOPE_KEY_SESSION_ID := "SESSION_ID"
const ENVELOPE_KEY_SEQUENCE := "SEQ"
const ENVELOPE_KEY_TICK := "TICK"
const ENVELOPE_KEY_SENT_AT_MSEC := "SENT_AT_MSEC"
const ENVELOPE_KEY_PAYLOAD := "PAYLOAD"
const LOG_NAME := "BrotatoLocalTogether:SessionConnection"

var network_peer : NetworkedMultiplayerENet = null
var session_persistence : Node = null
var session_registry : Node = null

var host_endpoint : String = ""
var pending_join_endpoint : String = ""
var known_peer_names : Dictionary = {}

var cached_state_snapshot : Dictionary = {}
var last_snapshot_write_msec : int = 0
var active_session : Dictionary = {}
var session_id : String = ""
var host_instance_id : String = ""
var local_player_token : String = ""
var slot_by_peer_id : Dictionary = {}
var peer_id_by_slot : Dictionary = {}
var token_by_peer_id : Dictionary = {}
var last_rejection_reason : String = ""
var pending_restore_snapshot : Dictionary = {}
var pending_client_recovery_state : Dictionary = {}
var attempted_tokenless_retry : bool = false

signal session_resume_available(session_id, expires_at_unix)
signal session_resumed(session_id, player_slot)
signal session_resume_failed(reason_code, reason_text)


func _ready() -> void:
	steam_id = -1
	game_lobby_id = -1
	game_lobby_owner_id = -1
	known_peer_names.clear()
	lobby_members.clear()
	lobby_member_names.clear()
	player_latencies.clear()
	slot_by_peer_id.clear()
	peer_id_by_slot.clear()
	token_by_peer_id.clear()
	active_session.clear()
	session_id = ""
	host_instance_id = ""
	local_player_token = ""
	pending_restore_snapshot.clear()
	pending_client_recovery_state.clear()
	last_rejection_reason = ""
	attempted_tokenless_retry = false

	session_persistence = SessionPersistence.new()
	session_persistence.set_name("SessionPersistence")
	add_child(session_persistence)

	session_registry = SessionRegistry.new()
	session_registry.set_name("SessionRegistry")
	add_child(session_registry)

	var _err = get_tree().connect("network_peer_connected", self, "_on_network_peer_connected")
	_err = get_tree().connect("network_peer_disconnected", self, "_on_network_peer_disconnected")
	_err = get_tree().connect("connected_to_server", self, "_on_connected_to_server")
	_err = get_tree().connect("connection_failed", self, "_on_connection_failed")
	_err = get_tree().connect("server_disconnected", self, "_on_server_disconnected")

	ping_timer = Timer.new()
	_err = ping_timer.connect("timeout", self, "_ping_timer_timeout")
	add_child(ping_timer)
	ping_timer.start(2.0)

	_emit_resume_hints()
	request_lobby_search()


func _physics_process(_delta : float) -> void:
	pass


func _notification(what: int) -> void:
	if what == MainLoop.NOTIFICATION_WM_QUIT_REQUEST or what == NOTIFICATION_PREDELETE:
		_flush_snapshot(true)


func _request_global_chat_search() -> void:
	return


func _on_lobby_match_list(_lobbies: Array) -> void:
	return


func _on_lobby_created(_connect: int, _created_lobby_id: int) -> void:
	return


func _on_lobby_joined(_lobby_id: int, _permissions: int, _locked: bool, _response: int) -> void:
	return


func _on_lobby_message(_lobby_id : int, _user_id : int, _buffer : String, _chat_type : int) -> void:
	return


func _on_lobby_chat_update(_lobby_id: int, _change_id: int, _making_change_id: int, _chat_state: int) -> void:
	return


func create_new_game_lobby(host_port: int = -1, restore_snapshot: Dictionary = {}) -> void:
	var options = _get_options()
	if options == null:
		return

	if host_port <= 0:
		host_port = options.host_port

	host_port = int(clamp(host_port, 1024, 65535))
	options.set_host_port(host_port)

	leave_game_lobby()

	var peer := NetworkedMultiplayerENet.new()
	var result = peer.create_server(host_port, MAX_PLAYERS - 1)
	if result != OK:
		_push_system_message("Failed to start host on port %d" % host_port)
		return

	network_peer = peer
	get_tree().set_network_peer(network_peer)

	game_lobby_id = ACTIVE_LOBBY_ID
	steam_id = get_tree().get_network_unique_id()
	game_lobby_owner_id = steam_id

	host_endpoint = _guess_host_endpoint(host_port)
	pending_join_endpoint = ""
	last_rejection_reason = ""
	attempted_tokenless_retry = false

	var host_name = _sanitize_username(options.get_local_username())
	var host_token = _generate_random_id()

	var recovery_snapshot = restore_snapshot
	if recovery_snapshot.empty() and not pending_restore_snapshot.empty():
		recovery_snapshot = pending_restore_snapshot.duplicate(true)

	if recovery_snapshot.empty():
		active_session = session_registry.create_session(host_endpoint, host_port, host_name, host_token, "", "", SESSION_TTL_SEC)
		cached_state_snapshot.clear()
	else:
		if not options.last_player_token.strip_edges().empty():
			host_token = options.last_player_token.strip_edges()
		active_session = session_registry.restore_session_from_snapshot(recovery_snapshot, host_endpoint, host_port, host_name, host_token, SESSION_TTL_SEC)
		cached_state_snapshot = recovery_snapshot.get("state_dict", {}).duplicate(true)
		var restored_phase = String(recovery_snapshot.get("game_phase", "LOBBY"))
		if restored_phase.to_upper() != "LOBBY":
			_push_system_message("Снимок найден. Полное восстановление mid-run пока недоступно, запускаем лобби.")

	active_session = session_registry.touch_session(active_session, SESSION_TTL_SEC)
	session_id = String(active_session.get("session_id", ""))
	host_instance_id = String(active_session.get("host_instance_id", ""))
	local_player_token = String(_get_host_token_from_session())
	pending_restore_snapshot.clear()

	known_peer_names.clear()
	slot_by_peer_id.clear()
	peer_id_by_slot.clear()
	token_by_peer_id.clear()

	known_peer_names[steam_id] = host_name
	slot_by_peer_id[steam_id] = 0
	peer_id_by_slot[0] = steam_id
	token_by_peer_id[steam_id] = local_player_token

	active_session = session_registry.upsert_player(active_session, local_player_token, host_name, 0, true, steam_id)
	active_session = session_registry.touch_session(active_session, SESSION_TTL_SEC)
	var _saved_active = session_registry.save_active_session(active_session)
	_rebuild_lobby_members()

	options.joining_multiplayer_lobby = true
	options.in_multiplayer_game = false
	options.set_last_join_endpoint(host_endpoint)
	options.set_session_credentials(session_id, local_player_token, host_endpoint)

	_push_system_message("Hosting on %s" % host_endpoint)
	_send_lobby_sync()
	_change_scene_to_character_selection()
	_flush_snapshot(true)


func join_game_lobby(endpoint: String) -> void:
	var options = _get_options()
	if options == null:
		return

	var parsed = _parse_endpoint(endpoint)
	if not parsed["ok"]:
		_push_system_message("Invalid endpoint. Use host:port")
		return

	leave_game_lobby()

	var peer := NetworkedMultiplayerENet.new()
	var result = peer.create_client(parsed["host"], int(parsed["port"]))
	if result != OK:
		_push_system_message("Connection failed to %s:%d" % [parsed["host"], parsed["port"]])
		return

	network_peer = peer
	get_tree().set_network_peer(network_peer)

	game_lobby_id = ACTIVE_LOBBY_ID
	game_lobby_owner_id = HOST_PEER_ID
	pending_join_endpoint = "%s:%d" % [parsed["host"], parsed["port"]]
	last_rejection_reason = ""
	pending_client_recovery_state.clear()
	attempted_tokenless_retry = false

	_push_system_message("Connecting to %s" % pending_join_endpoint)
	options.set_last_join_endpoint(pending_join_endpoint)
	options.joining_multiplayer_lobby = true
	options.in_multiplayer_game = false


func leave_game_lobby() -> void:
	var was_host = is_host()
	if was_host:
		_flush_snapshot(true)

	if was_host and session_registry != null and not active_session.empty():
		active_session["status"] = "recoverable"
		active_session = session_registry.touch_session(active_session, SESSION_TTL_SEC)
		var _saved_active = session_registry.save_active_session(active_session)

	if get_tree().has_network_peer():
		get_tree().set_network_peer(null)

	if network_peer != null:
		network_peer.close_connection()
		network_peer = null

	game_lobby_id = -1
	game_lobby_owner_id = -1
	steam_id = -1

	lobby_members.clear()
	lobby_member_names.clear()
	player_latencies.clear()
	known_peer_names.clear()
	slot_by_peer_id.clear()
	peer_id_by_slot.clear()
	token_by_peer_id.clear()
	cached_state_snapshot.clear()
	active_session.clear()
	session_id = ""
	host_instance_id = ""
	local_player_token = ""
	last_rejection_reason = ""
	attempted_tokenless_retry = false
	host_endpoint = ""
	pending_join_endpoint = ""

	var options = _get_options()
	if options != null:
		options.joining_multiplayer_lobby = false
		options.in_multiplayer_game = false

	emit_signal("lobby_players_updated")


func request_lobby_search() -> void:
	var shown : Dictionary = {}
	if not host_endpoint.empty():
		emit_signal("game_lobby_found", host_endpoint, "Active host (%s)" % host_endpoint)
		shown[host_endpoint] = true

	var options = _get_options()
	if options == null:
		return

	if session_registry != null:
		var persisted_session = session_registry.load_active_session()
		if not persisted_session.empty() and not session_registry.is_session_expired(persisted_session):
			var persisted_endpoint = String(persisted_session.get("host_endpoint", ""))
			if not persisted_endpoint.empty() and not shown.has(persisted_endpoint):
				emit_signal("game_lobby_found", persisted_endpoint, "Recoverable (%s)" % persisted_endpoint)
				shown[persisted_endpoint] = true

	if not options.last_join_endpoint.empty() and not shown.has(options.last_join_endpoint):
		emit_signal("game_lobby_found", options.last_join_endpoint, "Recent (%s)" % options.last_join_endpoint)
		shown[options.last_join_endpoint] = true

	if has_recovery_snapshot():
		var snapshot = session_persistence.load_latest_snapshot()
		if snapshot.has("host_endpoint"):
			var snapshot_endpoint = String(snapshot["host_endpoint"])
			if not snapshot_endpoint.empty() and not shown.has(snapshot_endpoint):
				emit_signal("game_lobby_found", snapshot_endpoint, "Recovery (%s)" % snapshot_endpoint)
				shown[snapshot_endpoint] = true


func send_global_chat_message(message : String) -> void:
	var trimmed_message = message.strip_edges()
	if trimmed_message.empty():
		return

	var payload = {
		"MESSAGE": trimmed_message,
		"USERNAME": _name_for_peer(steam_id),
	}

	if is_host():
		emit_signal("global_chat_received", payload["USERNAME"], payload["MESSAGE"])
		send_p2p_packet(payload, SESSION_MESSAGE_GLOBAL_CHAT)
	else:
		send_p2p_packet(payload, SESSION_MESSAGE_GLOBAL_CHAT, game_lobby_owner_id)


func send_lobby_chat_message(message : String) -> void:
	var trimmed_message = message.strip_edges()
	if trimmed_message.empty():
		return

	var payload = {
		"MESSAGE": trimmed_message,
		"USERNAME": _name_for_peer(steam_id),
	}

	if is_host():
		emit_signal("game_lobby_chat_received", payload["USERNAME"], payload["MESSAGE"])
		send_p2p_packet(payload, SESSION_MESSAGE_LOBBY_CHAT)
	else:
		send_p2p_packet(payload, SESSION_MESSAGE_LOBBY_CHAT, game_lobby_owner_id)


func send_p2p_packet(data : Dictionary, message_type : int, target_id = -1) -> void:
	if not is_inside_tree():
		return
	var tree = get_tree()
	if tree == null:
		return
	if game_lobby_id == -1 or network_peer == null or not tree.has_network_peer():
		return

	var safe_payload : Dictionary = {}
	if data != null:
		safe_payload = data.duplicate(true)
	var envelope = _build_envelope(safe_payload, message_type)
	var compressed_data: PoolByteArray = var2bytes(envelope).compress(File.COMPRESSION_GZIP)

	if target_id == -1:
		if is_host():
			var connected_peers = tree.get_network_connected_peers()
			for peer_id in connected_peers:
				if peer_id == steam_id:
					continue
				_send_rpc_packet(int(peer_id), message_type, compressed_data)
		elif game_lobby_owner_id > 0:
			_send_rpc_packet(game_lobby_owner_id, message_type, compressed_data)
		return

	if target_id == steam_id:
		return

	_send_rpc_packet(int(target_id), message_type, compressed_data)


remote func _receive_enet_packet(message_type : int, compressed_data : PoolByteArray) -> void:
	if not is_inside_tree():
		return
	var tree = get_tree()
	if tree == null:
		return
	var sender_id = tree.get_rpc_sender_id()

	var decoded_payload = null
	if compressed_data.size() > 0:
		var unpacked_data = compressed_data.decompress_dynamic(-1, File.COMPRESSION_GZIP)
		if unpacked_data.size() > 0:
			decoded_payload = bytes2var(unpacked_data)

	var packet = _parse_received_packet(message_type, decoded_payload, sender_id)
	if not bool(packet.get("ok", false)):
		return

	_dispatch_incoming_packet(int(packet.get("message_type", message_type)), packet.get("payload", {}), sender_id)


func read_p2p_packet() -> void:
	return


func _dispatch_incoming_packet(channel : int, data : Dictionary, sender_id : int) -> void:
	if channel == SESSION_MESSAGE_REGISTER_CLIENT:
		_receive_client_registration(data, sender_id)
		return
	elif channel == SESSION_MESSAGE_REGISTER_ACK:
		_receive_client_registration_ack(data, sender_id)
		return
	elif channel == SESSION_MESSAGE_REGISTER_REJECT:
		_receive_client_registration_reject(data, sender_id)
		return
	elif channel == SESSION_MESSAGE_LOBBY_SYNC:
		_receive_lobby_sync(data, sender_id)
		return
	elif channel == SESSION_MESSAGE_GLOBAL_CHAT:
		_receive_global_chat_packet(data, sender_id)
		return
	elif channel == SESSION_MESSAGE_LOBBY_CHAT:
		_receive_lobby_chat_packet(data, sender_id)
		return
	elif channel == SESSION_MESSAGE_RECOVERY_STATE:
		_receive_recovery_state(data, sender_id)
		return

	if channel == MessageType.MESSAGE_TYPE_PING:
		_respond_to_ping(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_PONG:
		_respond_to_pong(data)
	elif channel == MessageType.MESSAGE_TYPE_LATENCY_REPORT:
		_accept_latency_report(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_PLAYER_STATUS:
		_receive_player_statuses(data)
	elif channel == MessageType.MESSAGE_TYPE_CHARACTER_FOCUS:
		_receive_character_focus(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_CHARACTER_SELECTED:
		_receive_character_select(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_CHARACTER_LOBBY_UPDATE:
		_receive_character_lobby_update(data)
	elif channel == MessageType.MESSAGE_TYPE_WEAPON_FOCUS:
		_receive_weapon_focus(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_WEAPON_SELECTED:
		_receive_weapon_select(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_WEAPON_LOBBY_UPDATE:
		_receive_weapon_lobby_update(data)
	elif channel == MessageType.MESSAGE_TYPE_DIFFICULTY_FOCUSED:
		_receive_difficutly_focus_update(data)
	elif channel == MessageType.MESSAGE_TYPE_DIFFICULTY_PRESSED:
		_receive_difficutly_pressed(data)
	elif channel == MessageType.MESSAGE_TYPE_SHOP_LOBBY_UPDATE:
		_receive_shop_update(data)
	elif channel == MessageType.MESSAGE_TYPE_SHOP_WEAPON_DISCARD:
		_receive_shop_weapon_discard(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_SHOP_BUY_ITEM:
		_receive_shop_buy_item(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_SHOP_REROLL:
		_receive_shop_reroll(sender_id)
	elif channel == MessageType.MESSAGE_TYPE_SHOP_COMBINE_WEAPON:
		_receive_shop_combine_weapon(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_SHOP_ITEM_FOCUS:
		_receive_shop_item_focus(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_SHOP_GO_BUTTON_UPDATED:
		_receive_shop_go_button_pressed(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_SHOP_LOCK_ITEM:
		_receive_shop_lock_item(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_SHOP_UNLOCK_ITEM:
		_receive_shop_unlock_item(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_CHARACTER_SELECTION_COMPLETED:
		_receive_character_selection_completed(data)
	elif channel == MessageType.MESSAGE_TYPE_WEAPON_SELECTION_COMPLETED:
		_receive_weapon_selection_completed(data)
	elif channel == MessageType.MESSAGE_TYPE_HOST_ROUND_START:
		_receive_host_round_start()
	elif channel == MessageType.MESSAGE_TYPE_SHOP_INVENTORY_ITEM_FOCUS:
		_receive_shop_focus_inventory_element(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_SHOP_CLOSE_POPUP:
		_receive_shop_close_popup()
	elif channel == MessageType.MESSAGE_TYPE_LEAVE_SHOP:
		_receive_leave_shop()
	elif channel == MessageType.MESSAGE_TYPE_MAIN_STATE:
		_receive_game_state(data)
	elif channel == MessageType.MESSAGE_TYPE_CLIENT_POSITION:
		_receive_client_position(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_CLIENT_FOCUS_MAIN_SCENE:
		_receive_client_menu_focus(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_MAIN_SCENE_REROLL_BUTTON_PRESSED:
		_receive_main_scene_client_reroll_button_pressed(sender_id)
	elif channel == MessageType.MESSAGE_TYPE_MAIN_SCENE_CHOOSE_UPGRADE_PRESSED:
		_receive_main_scene_client_choose_upgrade_pressed(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_MAIN_SCENE_TAKE_BUTTON_PRESSED:
		_receive_main_scene_client_take_button_pressed(sender_id)
	elif channel == MessageType.MESSAGE_TYPE_MAIN_SCENE_DISCARD_BUTTON_PRESSED:
		_receive_main_scene_client_discard_button_pressed(sender_id)
	elif channel == MessageType.MESSAGE_TYPE_HOST_ENTERED_SHOP:
		_receive_host_entered_shop()


func _on_network_peer_connected(peer_id : int) -> void:
	if not is_host():
		return

	if peer_id == steam_id:
		return


func _on_network_peer_disconnected(peer_id : int) -> void:
	player_latencies.erase(peer_id)

	if is_host():
		var player_token = String(token_by_peer_id.get(peer_id, ""))
		if known_peer_names.has(peer_id):
			known_peer_names.erase(peer_id)
		if slot_by_peer_id.has(peer_id):
			var slot = int(slot_by_peer_id[peer_id])
			slot_by_peer_id.erase(peer_id)
			peer_id_by_slot.erase(slot)
		if token_by_peer_id.has(peer_id):
			token_by_peer_id.erase(peer_id)

		if session_registry != null and not active_session.empty() and not player_token.empty():
			var disconnected_player = session_registry.find_player_by_token(active_session, player_token)
			if not disconnected_player.empty():
				active_session = session_registry.upsert_player(
					active_session,
					player_token,
					String(disconnected_player.get("display_name", "Player")),
					int(disconnected_player.get("slot", -1)),
					false,
					-1
				)
				active_session = session_registry.touch_session(active_session, SESSION_TTL_SEC)
				var _saved_active = session_registry.save_active_session(active_session)

		_rebuild_lobby_members()
		_send_lobby_sync()
		emit_signal("lobby_players_updated")
		return

	if peer_id == game_lobby_owner_id:
		_push_system_message("Host left the lobby")
		leave_game_lobby()
		_go_to_multiplayer_menu()
		return

	if known_peer_names.has(peer_id):
		known_peer_names.erase(peer_id)
		if slot_by_peer_id.has(peer_id):
			var peer_slot = int(slot_by_peer_id[peer_id])
			slot_by_peer_id.erase(peer_id)
			peer_id_by_slot.erase(peer_slot)
		if token_by_peer_id.has(peer_id):
			token_by_peer_id.erase(peer_id)
		_rebuild_lobby_members()
		emit_signal("lobby_players_updated")


func _on_connected_to_server() -> void:
	if network_peer == null:
		return
	attempted_tokenless_retry = false

	steam_id = get_tree().get_network_unique_id()
	game_lobby_id = ACTIVE_LOBBY_ID
	game_lobby_owner_id = HOST_PEER_ID

	known_peer_names.clear()
	slot_by_peer_id.clear()
	peer_id_by_slot.clear()
	token_by_peer_id.clear()
	known_peer_names[game_lobby_owner_id] = "Host"
	slot_by_peer_id[game_lobby_owner_id] = 0
	peer_id_by_slot[0] = game_lobby_owner_id

	var options = _get_options()
	var local_name := "Player"
	var requested_session_id := ""
	var requested_token := ""
	if options != null:
		local_name = _sanitize_username(options.get_local_username())
		known_peer_names[steam_id] = local_name
		options.joining_multiplayer_lobby = true
		options.in_multiplayer_game = false
		if options.last_session_host_endpoint == pending_join_endpoint:
			requested_session_id = options.last_session_id
			requested_token = options.last_player_token
	else:
		known_peer_names[steam_id] = "Player"

	slot_by_peer_id[steam_id] = 1
	peer_id_by_slot[1] = steam_id
	_rebuild_lobby_members()

	send_p2p_packet(
		{
			"USERNAME": local_name,
			"SESSION_ID": requested_session_id,
			"PLAYER_TOKEN": requested_token,
			"PROTOCOL_VERSION": PROTOCOL_VERSION,
		},
		SESSION_MESSAGE_REGISTER_CLIENT,
		game_lobby_owner_id
	)


func _on_connection_failed() -> void:
	_push_system_message("Connection failed")
	leave_game_lobby()
	_go_to_multiplayer_menu()


func _on_server_disconnected() -> void:
	_push_system_message("Server disconnected")
	leave_game_lobby()
	_go_to_multiplayer_menu()


func _receive_client_registration(data : Dictionary, sender_id : int) -> void:
	if not is_host():
		return

	if active_session.empty() or session_registry == null:
		_send_register_reject(sender_id, "session_unavailable", "Session is unavailable")
		return

	if session_registry.is_session_expired(active_session):
		_send_register_reject(sender_id, "session_expired", "Session expired")
		return

	var username = "Player %d" % sender_id
	if data.has("USERNAME"):
		username = _sanitize_username(String(data["USERNAME"]))
	var remote_protocol_version = int(data.get("PROTOCOL_VERSION", 0))
	if remote_protocol_version != PROTOCOL_VERSION:
		_send_register_reject(
			sender_id,
			"protocol_mismatch",
			"Protocol mismatch: host=%d client=%d" % [PROTOCOL_VERSION, remote_protocol_version]
		)
		return

	var requested_session_id = String(data.get("SESSION_ID", "")).strip_edges()
	var requested_token = String(data.get("PLAYER_TOKEN", "")).strip_edges()
	var assigned_slot = -1
	var assigned_token = requested_token
	var is_resumed = false

	if not requested_session_id.empty() and requested_session_id != session_id:
		_send_register_reject(sender_id, "session_mismatch", "Session ID mismatch")
		return

	if not assigned_token.empty():
		var existing_player = session_registry.find_player_by_token(active_session, assigned_token)
		if existing_player.empty():
			_send_register_reject(sender_id, "token_unknown", "Unknown player token")
			return

		assigned_slot = int(existing_player.get("slot", -1))
		if assigned_slot < 0:
			_send_register_reject(sender_id, "token_invalid_slot", "Invalid token slot")
			return

		if peer_id_by_slot.has(assigned_slot) and int(peer_id_by_slot[assigned_slot]) != sender_id:
			_send_register_reject(sender_id, "token_in_use", "Player token already in use")
			return

		is_resumed = true
	else:
		if _current_game_phase() != "LOBBY":
			_send_register_reject(sender_id, "late_join_blocked", "Cannot join mid-run without resume token")
			return

		assigned_slot = session_registry.allocate_slot(active_session, MAX_PLAYERS)
		if assigned_slot < 0:
			_send_register_reject(sender_id, "lobby_full", "Lobby is full")
			return

		assigned_token = _generate_random_id()
		is_resumed = false

	var player_record = session_registry.find_player_by_token(active_session, assigned_token)
	var display_name = username
	if not player_record.empty():
		display_name = _sanitize_username(String(player_record.get("display_name", username)))

	active_session = session_registry.upsert_player(active_session, assigned_token, display_name, assigned_slot, true, sender_id)
	active_session = session_registry.touch_session(active_session, SESSION_TTL_SEC)
	var _saved_active = session_registry.save_active_session(active_session)

	for tracked_slot in peer_id_by_slot.keys():
		if int(peer_id_by_slot[tracked_slot]) == sender_id and int(tracked_slot) != assigned_slot:
			peer_id_by_slot.erase(tracked_slot)

	known_peer_names[sender_id] = display_name
	slot_by_peer_id[sender_id] = assigned_slot
	peer_id_by_slot[assigned_slot] = sender_id
	token_by_peer_id[sender_id] = assigned_token
	_rebuild_lobby_members()

	var ack_payload = {
		"SESSION_ID": session_id,
		"PLAYER_TOKEN": assigned_token,
		"PLAYER_SLOT": assigned_slot,
		"HOST_INSTANCE_ID": host_instance_id,
		"HOST_ENDPOINT": host_endpoint,
		"RESUMED": is_resumed,
		"GAME_PHASE": _current_game_phase(),
		"PROTOCOL_VERSION": PROTOCOL_VERSION,
	}
	send_p2p_packet(ack_payload, SESSION_MESSAGE_REGISTER_ACK, sender_id)
	_send_lobby_sync()

	if is_resumed and _current_game_phase() == "MAIN" and cached_state_snapshot.size() > 0:
		send_p2p_packet({"STATE_DICT": cached_state_snapshot.duplicate(true)}, SESSION_MESSAGE_RECOVERY_STATE, sender_id)

	emit_signal("lobby_players_updated")


func _receive_client_registration_ack(data : Dictionary, sender_id : int) -> void:
	if sender_id != game_lobby_owner_id:
		return
	attempted_tokenless_retry = false

	if not data.has("SESSION_ID") or not data.has("PLAYER_TOKEN"):
		_receive_client_registration_reject(
			{
				"REASON_CODE": "bad_ack",
				"REASON_TEXT": "Invalid registration ack",
			},
			sender_id
		)
		return
	var remote_protocol_version = int(data.get("PROTOCOL_VERSION", 0))
	if remote_protocol_version != PROTOCOL_VERSION:
		_receive_client_registration_reject(
			{
				"REASON_CODE": "protocol_mismatch",
				"REASON_TEXT": "Protocol mismatch: host=%d client=%d" % [remote_protocol_version, PROTOCOL_VERSION],
			},
			sender_id
		)
		return

	session_id = String(data["SESSION_ID"])
	local_player_token = String(data["PLAYER_TOKEN"])
	host_instance_id = String(data.get("HOST_INSTANCE_ID", ""))
	host_endpoint = String(data.get("HOST_ENDPOINT", pending_join_endpoint))
	var player_slot = int(data.get("PLAYER_SLOT", -1))
	var resumed = bool(data.get("RESUMED", false))
	var game_phase = String(data.get("GAME_PHASE", "LOBBY")).to_upper()

	if player_slot >= 0:
		for tracked_slot in peer_id_by_slot.keys():
			if int(peer_id_by_slot[tracked_slot]) == steam_id and int(tracked_slot) != player_slot:
				peer_id_by_slot.erase(tracked_slot)
		slot_by_peer_id[steam_id] = player_slot
		peer_id_by_slot[player_slot] = steam_id
	token_by_peer_id[steam_id] = local_player_token

	var options = _get_options()
	if options != null:
		if not host_endpoint.empty():
			options.set_last_join_endpoint(host_endpoint)
		options.set_session_credentials(session_id, local_player_token, host_endpoint)
		if game_phase == "MAIN" and resumed:
			options.joining_multiplayer_lobby = false
			options.in_multiplayer_game = true
		else:
			options.joining_multiplayer_lobby = true
			options.in_multiplayer_game = false

	if game_phase == "MAIN" and resumed:
		var _scene_error = get_tree().change_scene(MenuData.game_scene)
		emit_signal("session_resumed", session_id, player_slot)
	else:
		_change_scene_to_character_selection()
		_initiate_ping()


func _receive_client_registration_reject(data : Dictionary, sender_id : int) -> void:
	if sender_id != game_lobby_owner_id:
		return

	var reason_code = String(data.get("REASON_CODE", "rejected"))
	var reason_text = String(data.get("REASON_TEXT", "Connection rejected"))

	if not attempted_tokenless_retry and (
		reason_code == "session_mismatch" or
		reason_code == "token_unknown" or
		reason_code == "token_invalid_slot"
	):
		attempted_tokenless_retry = true
		var options = _get_options()
		if options != null:
			options.clear_session_credentials()

		send_p2p_packet(
			{
				"USERNAME": _name_for_peer(steam_id),
				"SESSION_ID": "",
				"PLAYER_TOKEN": "",
				"PROTOCOL_VERSION": PROTOCOL_VERSION,
			},
			SESSION_MESSAGE_REGISTER_CLIENT,
			game_lobby_owner_id
		)
		return

	last_rejection_reason = reason_code
	emit_signal("session_resume_failed", reason_code, reason_text)
	_push_system_message(reason_text)
	leave_game_lobby()
	_go_to_multiplayer_menu()


func _send_register_reject(target_peer_id: int, reason_code: String, reason_text: String) -> void:
	send_p2p_packet(
		{
			"REASON_CODE": reason_code,
			"REASON_TEXT": reason_text,
			"PROTOCOL_VERSION": PROTOCOL_VERSION,
		},
		SESSION_MESSAGE_REGISTER_REJECT,
		target_peer_id
	)


func _next_outgoing_sequence() -> int:
	outgoing_sequence += 1
	if outgoing_sequence >= ENVELOPE_MAX_SEQ:
		outgoing_sequence = 1
	return outgoing_sequence


func _build_envelope(payload: Dictionary, message_type: int) -> Dictionary:
	return {
		ENVELOPE_KEY_PROTOCOL_VERSION: PROTOCOL_VERSION,
		ENVELOPE_KEY_MESSAGE_TYPE: message_type,
		ENVELOPE_KEY_SESSION_ID: session_id,
		ENVELOPE_KEY_SEQUENCE: _next_outgoing_sequence(),
		ENVELOPE_KEY_TICK: Engine.get_physics_frames(),
		ENVELOPE_KEY_SENT_AT_MSEC: Time.get_ticks_msec(),
		ENVELOPE_KEY_PAYLOAD: payload,
	}


func _parse_received_packet(fallback_message_type: int, decoded_payload, sender_id: int) -> Dictionary:
	var result = {
		"ok": true,
		"message_type": fallback_message_type,
		"payload": {},
	}
	if not (decoded_payload is Dictionary):
		result["ok"] = false
		return result

	var decoded_dict: Dictionary = decoded_payload

	if (
		not decoded_dict.has(ENVELOPE_KEY_PROTOCOL_VERSION) or
		not decoded_dict.has(ENVELOPE_KEY_MESSAGE_TYPE) or
		not decoded_dict.has(ENVELOPE_KEY_SESSION_ID) or
		not decoded_dict.has(ENVELOPE_KEY_SEQUENCE) or
		not decoded_dict.has(ENVELOPE_KEY_TICK) or
		not decoded_dict.has(ENVELOPE_KEY_SENT_AT_MSEC) or
		not decoded_dict.has(ENVELOPE_KEY_PAYLOAD)
	):
		result["ok"] = false
		return result

	var remote_protocol_version = int(decoded_dict.get(ENVELOPE_KEY_PROTOCOL_VERSION, 0))
	var parsed_message_type = int(decoded_dict.get(ENVELOPE_KEY_MESSAGE_TYPE, fallback_message_type))
	var remote_session_id = String(decoded_dict.get(ENVELOPE_KEY_SESSION_ID, "")).strip_edges()
	var payload_data = decoded_dict.get(ENVELOPE_KEY_PAYLOAD, {})

	if parsed_message_type != fallback_message_type:
		result["ok"] = false
		return result

	if remote_protocol_version != PROTOCOL_VERSION:
		if parsed_message_type == SESSION_MESSAGE_REGISTER_CLIENT and is_host():
			_send_register_reject(
				sender_id,
				"protocol_mismatch",
				"Protocol mismatch: host=%d client=%d" % [PROTOCOL_VERSION, remote_protocol_version]
			)
		result["ok"] = false
		return result

	if _is_session_bound_message(parsed_message_type):
		if not session_id.empty() and not remote_session_id.empty() and remote_session_id != session_id:
			result["ok"] = false
			return result

	if not (payload_data is Dictionary):
		result["ok"] = false
		return result

	result["message_type"] = parsed_message_type
	result["payload"] = payload_data
	return result


func _is_session_bound_message(message_type: int) -> bool:
	if message_type == SESSION_MESSAGE_REGISTER_CLIENT:
		return false
	if message_type == SESSION_MESSAGE_REGISTER_ACK:
		return false
	if message_type == SESSION_MESSAGE_REGISTER_REJECT:
		return false
	return true


func _send_rpc_packet(target_peer_id: int, message_type: int, compressed_data: PoolByteArray) -> void:
	if target_peer_id <= 0:
		return
	var previous_channel = int(network_peer.transfer_channel)
	if previous_channel <= 0:
		previous_channel = 1
	var transfer_channel = _transfer_channel_for_message(message_type)
	if transfer_channel <= 0:
		transfer_channel = 1
	if transfer_channel != previous_channel:
		network_peer.transfer_channel = transfer_channel
	var is_unreliable = _is_unreliable_message(message_type)
	var is_reliable = _is_reliable_message(message_type)
	if is_unreliable and is_reliable:
		is_unreliable = false
	if is_unreliable and has_method("rpc_unreliable_id"):
		rpc_unreliable_id(target_peer_id, "_receive_enet_packet", message_type, compressed_data)
	elif is_reliable:
		rpc_id(target_peer_id, "_receive_enet_packet", message_type, compressed_data)
	else:
		rpc_id(target_peer_id, "_receive_enet_packet", message_type, compressed_data)
	if int(network_peer.transfer_channel) != previous_channel:
		network_peer.transfer_channel = previous_channel


func _is_unreliable_message(message_type: int) -> bool:
	match message_type:
		MessageType.MESSAGE_TYPE_PING:
			return true
		MessageType.MESSAGE_TYPE_PONG:
			return true
		MessageType.MESSAGE_TYPE_LATENCY_REPORT:
			return true
		MessageType.MESSAGE_TYPE_PLAYER_STATUS:
			return true
		MessageType.MESSAGE_TYPE_CHARACTER_FOCUS:
			return true
		MessageType.MESSAGE_TYPE_WEAPON_FOCUS:
			return true
		MessageType.MESSAGE_TYPE_DIFFICULTY_FOCUSED:
			return true
		MessageType.MESSAGE_TYPE_SHOP_ITEM_FOCUS:
			return true
		MessageType.MESSAGE_TYPE_SHOP_INVENTORY_ITEM_FOCUS:
			return true
		MessageType.MESSAGE_TYPE_SHOP_GO_BUTTON_UPDATED:
			return true
		MessageType.MESSAGE_TYPE_CLIENT_POSITION:
			return true
		MessageType.MESSAGE_TYPE_CLIENT_FOCUS_MAIN_SCENE:
			return true
		MessageType.MESSAGE_TYPE_MAIN_STATE:
			return true
	return false


func _is_reliable_message(message_type: int) -> bool:
	match message_type:
		SESSION_MESSAGE_REGISTER_CLIENT:
			return true
		SESSION_MESSAGE_REGISTER_ACK:
			return true
		SESSION_MESSAGE_REGISTER_REJECT:
			return true
		SESSION_MESSAGE_LOBBY_SYNC:
			return true
		SESSION_MESSAGE_RECOVERY_STATE:
			return true
		MessageType.MESSAGE_TYPE_CHARACTER_SELECTED:
			return true
		MessageType.MESSAGE_TYPE_WEAPON_SELECTED:
			return true
		MessageType.MESSAGE_TYPE_DIFFICULTY_PRESSED:
			return true
		MessageType.MESSAGE_TYPE_CHARACTER_LOBBY_UPDATE:
			return true
		MessageType.MESSAGE_TYPE_WEAPON_LOBBY_UPDATE:
			return true
		MessageType.MESSAGE_TYPE_CHARACTER_SELECTION_COMPLETED:
			return true
		MessageType.MESSAGE_TYPE_WEAPON_SELECTION_COMPLETED:
			return true
		MessageType.MESSAGE_TYPE_SHOP_BUY_ITEM:
			return true
		MessageType.MESSAGE_TYPE_SHOP_LOCK_ITEM:
			return true
		MessageType.MESSAGE_TYPE_SHOP_UNLOCK_ITEM:
			return true
		MessageType.MESSAGE_TYPE_SHOP_REROLL:
			return true
		MessageType.MESSAGE_TYPE_SHOP_COMBINE_WEAPON:
			return true
		MessageType.MESSAGE_TYPE_SHOP_WEAPON_DISCARD:
			return true
		MessageType.MESSAGE_TYPE_SHOP_LOBBY_UPDATE:
			return true
		MessageType.MESSAGE_TYPE_HOST_ROUND_START:
			return true
		MessageType.MESSAGE_TYPE_HOST_ENTERED_SHOP:
			return true
		MessageType.MESSAGE_TYPE_SHOP_CLOSE_POPUP:
			return true
		MessageType.MESSAGE_TYPE_LEAVE_SHOP:
			return true
		MessageType.MESSAGE_TYPE_MAIN_SCENE_REROLL_BUTTON_PRESSED:
			return true
		MessageType.MESSAGE_TYPE_MAIN_SCENE_CHOOSE_UPGRADE_PRESSED:
			return true
		MessageType.MESSAGE_TYPE_MAIN_SCENE_TAKE_BUTTON_PRESSED:
			return true
		MessageType.MESSAGE_TYPE_MAIN_SCENE_DISCARD_BUTTON_PRESSED:
			return true
	return false


func _transfer_channel_for_message(message_type: int) -> int:
	match message_type:
		MessageType.MESSAGE_TYPE_MAIN_STATE:
			return 2
		MessageType.MESSAGE_TYPE_CLIENT_POSITION:
			return 2
		MessageType.MESSAGE_TYPE_CLIENT_FOCUS_MAIN_SCENE:
			return 2
		MessageType.MESSAGE_TYPE_CHARACTER_FOCUS:
			return 1
		MessageType.MESSAGE_TYPE_WEAPON_FOCUS:
			return 1
		MessageType.MESSAGE_TYPE_SHOP_ITEM_FOCUS:
			return 1
		MessageType.MESSAGE_TYPE_SHOP_INVENTORY_ITEM_FOCUS:
			return 1
	return 1


func _send_lobby_sync() -> void:
	if not is_host():
		return

	var players_payload : Array = []
	for peer_id in lobby_members:
		var slot = int(slot_by_peer_id.get(peer_id, -1))
		players_payload.push_back(
			{
				"PEER_ID": int(peer_id),
				"SLOT": slot,
				"NAME": _name_for_peer(int(peer_id)),
			}
		)

	var payload = {
		"MEMBER_IDS": lobby_members.duplicate(),
		"MEMBER_NAMES": lobby_member_names.duplicate(),
		"OWNER_ID": game_lobby_owner_id,
		"SESSION_ID": session_id,
		"HOST_ENDPOINT": host_endpoint,
		"GAME_PHASE": _current_game_phase(),
		"PLAYERS": players_payload,
	}
	send_p2p_packet(payload, SESSION_MESSAGE_LOBBY_SYNC)


func _receive_lobby_sync(data : Dictionary, sender_id : int) -> void:
	if sender_id != game_lobby_owner_id:
		return

	if not data.has("MEMBER_IDS") or not data.has("MEMBER_NAMES"):
		return

	lobby_members = data["MEMBER_IDS"].duplicate()
	lobby_member_names = data["MEMBER_NAMES"].duplicate()

	if data.has("OWNER_ID"):
		game_lobby_owner_id = int(data["OWNER_ID"])
	if data.has("SESSION_ID"):
		session_id = String(data["SESSION_ID"])
	if data.has("HOST_ENDPOINT"):
		host_endpoint = String(data["HOST_ENDPOINT"])
		var options = _get_options()
		if options != null and not host_endpoint.empty():
			options.set_last_join_endpoint(host_endpoint)

	known_peer_names.clear()
	slot_by_peer_id.clear()
	peer_id_by_slot.clear()
	var peer_count = min(lobby_members.size(), lobby_member_names.size())
	for index in range(peer_count):
		known_peer_names[int(lobby_members[index])] = String(lobby_member_names[index])

	if data.has("PLAYERS") and data["PLAYERS"] is Array:
		for player_entry in data["PLAYERS"]:
			if not (player_entry is Dictionary):
				continue
			var peer_id = int(player_entry.get("PEER_ID", -1))
			var player_slot = int(player_entry.get("SLOT", -1))
			var player_name = _sanitize_username(String(player_entry.get("NAME", "")))
			if peer_id <= 0:
				continue
			if player_slot >= 0:
				slot_by_peer_id[peer_id] = player_slot
				peer_id_by_slot[player_slot] = peer_id
			if not player_name.empty():
				known_peer_names[peer_id] = player_name

	emit_signal("lobby_players_updated")


func _receive_global_chat_packet(data : Dictionary, sender_id : int) -> void:
	if not data.has("MESSAGE"):
		return

	var message = String(data["MESSAGE"]).strip_edges()
	if message.empty():
		return

	var username = _name_for_peer(sender_id)
	if data.has("USERNAME"):
		username = _sanitize_username(String(data["USERNAME"]))

	if is_host() and sender_id != steam_id:
		send_p2p_packet({"MESSAGE": message, "USERNAME": username}, SESSION_MESSAGE_GLOBAL_CHAT)

	emit_signal("global_chat_received", username, message)


func _receive_lobby_chat_packet(data : Dictionary, sender_id : int) -> void:
	if not data.has("MESSAGE"):
		return

	var message = String(data["MESSAGE"]).strip_edges()
	if message.empty():
		return

	var username = _name_for_peer(sender_id)
	if data.has("USERNAME"):
		username = _sanitize_username(String(data["USERNAME"]))

	if is_host() and sender_id != steam_id:
		send_p2p_packet({"MESSAGE": message, "USERNAME": username}, SESSION_MESSAGE_LOBBY_CHAT)

	emit_signal("game_lobby_chat_received", username, message)


func _receive_recovery_state(data : Dictionary, sender_id : int) -> void:
	if sender_id != game_lobby_owner_id:
		return

	if not data.has("STATE_DICT") or not (data["STATE_DICT"] is Dictionary):
		return

	pending_client_recovery_state = data["STATE_DICT"].duplicate(true)
	if get_tree().current_scene != null and (get_tree().current_scene.name == "Main" or get_tree().current_scene.name == "ClientMain"):
		emit_signal("state_update", pending_client_recovery_state)
		pending_client_recovery_state.clear()


func _rebuild_lobby_members() -> void:
	var members_with_slots : Array = []
	for peer_id in slot_by_peer_id.keys():
		if not known_peer_names.has(peer_id):
			continue
		members_with_slots.push_back([int(slot_by_peer_id[peer_id]), int(peer_id)])

	if members_with_slots.empty() and known_peer_names.has(game_lobby_owner_id):
		members_with_slots.push_back([0, game_lobby_owner_id])

	members_with_slots.sort_custom(self, "_sort_members_by_slot")

	lobby_members = []
	for entry in members_with_slots:
		lobby_members.push_back(entry[1])

	lobby_member_names = []
	for peer_id in lobby_members:
		lobby_member_names.push_back(_name_for_peer(int(peer_id)))


func _sort_members_by_slot(a, b) -> bool:
	if int(a[0]) == int(b[0]):
		return int(a[1]) < int(b[1])
	return int(a[0]) < int(b[0])


func _go_to_multiplayer_menu() -> void:
	if get_tree().current_scene == null:
		return

	if get_tree().current_scene.filename == "res://mods-unpacked/flash-BrotatoLocalTogether/ui/multiplayer_menu.tscn":
		return

	var _scene_error = get_tree().change_scene("res://mods-unpacked/flash-BrotatoLocalTogether/ui/multiplayer_menu.tscn")


func _push_system_message(message : String) -> void:
	pending_system_messages.push_back(message)
	emit_signal("global_chat_received", "SYSTEM", message)


func _change_scene_to_character_selection() -> void:
	var options = _get_options()
	if options != null:
		options.joining_multiplayer_lobby = true

	if get_tree().current_scene == null:
		return

	if get_tree().current_scene.filename == MenuData.character_selection_scene:
		return

	var _scene_error = get_tree().change_scene(MenuData.character_selection_scene)


func _current_game_phase() -> String:
	var options = _get_options()
	if options != null and options.in_multiplayer_game:
		return "MAIN"

	if get_tree().current_scene != null:
		var scene_name = String(get_tree().current_scene.name)
		if scene_name == "Main" or scene_name == "ClientMain":
			return "MAIN"

	return "LOBBY"


func _build_snapshot_players_payload() -> Array:
	var payload : Array = []
	if active_session.empty():
		return payload

	var players = active_session.get("players", [])
	if not (players is Array):
		return payload

	for player_data in players:
		if not (player_data is Dictionary):
			continue
		payload.push_back(
			{
				"token": String(player_data.get("token", "")),
				"display_name": String(player_data.get("display_name", "Player")),
				"slot": int(player_data.get("slot", -1)),
			}
		)

	return payload


func _is_snapshot_expired(snapshot : Dictionary) -> bool:
	if snapshot.empty():
		return true

	var ttl_sec = int(snapshot.get("snapshot_ttl_sec", SESSION_TTL_SEC))
	var saved_at_unix = int(snapshot.get("saved_at_unix", 0))
	if saved_at_unix <= 0:
		return true

	var now_unix = OS.get_unix_time()
	return now_unix > (saved_at_unix + max(60, ttl_sec))


func _get_host_token_from_session() -> String:
	if active_session.empty() or session_registry == null:
		return _generate_random_id()

	var players = active_session.get("players", [])
	if not (players is Array):
		return _generate_random_id()

	for player_data in players:
		if not (player_data is Dictionary):
			continue
		if int(player_data.get("slot", -1)) != 0:
			continue
		var token = String(player_data.get("token", "")).strip_edges()
		if token.empty():
			continue
		return token

	return _generate_random_id()


func _generate_random_id() -> String:
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	return "%08x%08x%08x%08x" % [rng.randi(), rng.randi(), rng.randi(), rng.randi()]


func _emit_resume_hints() -> void:
	if session_registry == null:
		return

	var persisted_session = session_registry.load_active_session()
	if persisted_session.empty():
		return
	if session_registry.is_session_expired(persisted_session):
		return

	var persisted_session_id = String(persisted_session.get("session_id", ""))
	var expires_at = int(persisted_session.get("expires_at_unix", 0))
	emit_signal("session_resume_available", persisted_session_id, expires_at)


func _sanitize_username(value : String) -> String:
	var username = value.strip_edges().replace("\n", " ").replace("\r", " ")
	if username.empty():
		return "Player"
	return username


func _name_for_peer(peer_id : int) -> String:
	if known_peer_names.has(peer_id):
		return String(known_peer_names[peer_id])

	if peer_id == steam_id:
		var options = _get_options()
		if options != null:
			return _sanitize_username(options.get_local_username())

	if peer_id == game_lobby_owner_id:
		return "Host"

	return "Player %d" % peer_id


func _parse_endpoint(endpoint_string : String) -> Dictionary:
	var options = _get_options()
	var default_port = 24567
	if options != null:
		default_port = options.host_port

	var endpoint = endpoint_string.strip_edges()
	var result = {
		"ok": false,
		"host": "",
		"port": default_port,
	}

	if endpoint.empty():
		return result

	if endpoint.find(":") == -1:
		result["host"] = endpoint
		result["ok"] = true
		return result

	var parts = endpoint.split(":")
	if parts.size() < 2:
		return result

	var port_text = String(parts[parts.size() - 1]).strip_edges()
	if not port_text.is_valid_integer():
		return result

	var host = ""
	for idx in range(parts.size() - 1):
		host += parts[idx]
		if idx < parts.size() - 2:
			host += ":"

	host = host.strip_edges()
	if host.empty():
		return result

	var port = int(port_text)
	if port < 1024 or port > 65535:
		return result

	result["host"] = host
	result["port"] = port
	result["ok"] = true
	return result


func _guess_host_endpoint(port : int) -> String:
	var options = _get_options()
	if options != null:
		var preferred_value = String(options.preferred_advertise_ip).strip_edges()
		if not preferred_value.empty():
			return "%s:%d" % [preferred_value, port]

	var addresses = IP.get_local_addresses()
	var ipv4_candidates : Array = []
	for address in addresses:
		if address == "127.0.0.1" or address == "::1":
			continue
		if address.find(":") != -1:
			continue
		if _ipv4_octets(address).empty():
			continue
		ipv4_candidates.push_back(address)

	for address in ipv4_candidates:
		if _is_tailscale_ipv4(address):
			return "%s:%d" % [address, port]

	for address in ipv4_candidates:
		if _is_private_ipv4(address):
			return "%s:%d" % [address, port]

	if not ipv4_candidates.empty():
		return "%s:%d" % [String(ipv4_candidates[0]), port]

	return "127.0.0.1:%d" % port


func _ipv4_octets(address : String) -> Array:
	var parts = address.split(".")
	if parts.size() != 4:
		return []

	var octets : Array = []
	for part in parts:
		if not part.is_valid_integer():
			return []
		var value = int(part)
		if value < 0 or value > 255:
			return []
		octets.push_back(value)

	return octets


func _is_tailscale_ipv4(address : String) -> bool:
	var octets = _ipv4_octets(address)
	if octets.empty():
		return false

	var first = int(octets[0])
	var second = int(octets[1])
	if first != 100:
		return false

	return second >= 64 and second <= 127


func _is_private_ipv4(address : String) -> bool:
	var octets = _ipv4_octets(address)
	if octets.empty():
		return false

	var first = int(octets[0])
	var second = int(octets[1])
	if first == 10:
		return true
	if first == 192 and second == 168:
		return true
	if first == 172 and second >= 16 and second <= 31:
		return true

	return false


func _get_options():
	if not is_inside_tree():
		return null
	var tree = get_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("BrotogetherOptions")
	return null


func is_host() -> bool:
	return game_lobby_id > 0 and game_lobby_owner_id > 0 and steam_id == game_lobby_owner_id


func _send_player_statuses() -> void:
	if not is_host():
		return

	if game_lobby_id == -1 or game_lobby_owner_id == -1:
		return

	send_p2p_packet({"PLAYER_LATENCIES": player_latencies}, MessageType.MESSAGE_TYPE_PLAYER_STATUS)


func send_character_selection_completed(some_player_has_weapon_slots : bool, currently_focused_characters : Array) -> void:
	if not is_host():
		return

	var data = {
		"HAS_WEAPON_SLOTS" : some_player_has_weapon_slots,
		"SELECTED_CHARACTERS": currently_focused_characters,
	}

	send_p2p_packet(data, MessageType.MESSAGE_TYPE_CHARACTER_SELECTION_COMPLETED)


func send_game_state(state_dict : Dictionary) -> void:
	.send_game_state(state_dict)

	if not is_host():
		return

	cached_state_snapshot = state_dict.duplicate(true)
	if session_registry != null and not active_session.empty():
		active_session = session_registry.touch_session(active_session, SESSION_TTL_SEC)
		var _saved_active = session_registry.save_active_session(active_session)
	_maybe_store_snapshot(false)


func has_recovery_snapshot() -> bool:
	if session_persistence == null:
		return false

	if not session_persistence.has_snapshot():
		return false

	var snapshot = session_persistence.load_latest_snapshot()
	return not _is_snapshot_expired(snapshot)


func resume_from_latest_snapshot() -> bool:
	if session_persistence == null or not session_persistence.has_snapshot():
		_push_system_message("Recovery snapshot not found")
		return false

	var snapshot = session_persistence.load_latest_snapshot()
	if snapshot.empty():
		_push_system_message("Recovery snapshot is invalid")
		return false
	if _is_snapshot_expired(snapshot):
		_push_system_message("Recovery snapshot expired")
		return false

	var host_port = -1
	if snapshot.has("host_port"):
		host_port = int(snapshot["host_port"])

	if host_port <= 0 and snapshot.has("host_endpoint"):
		var endpoint_info = _parse_endpoint(String(snapshot["host_endpoint"]))
		if endpoint_info["ok"]:
			host_port = int(endpoint_info["port"])

	if host_port <= 0:
		var options = _get_options()
		if options != null:
			host_port = options.host_port
		else:
			host_port = 24567

	pending_restore_snapshot = snapshot.duplicate(true)
	create_new_game_lobby(host_port, pending_restore_snapshot)
	return true


func consume_recovery_snapshot_state() -> Dictionary:
	var state_copy = pending_client_recovery_state.duplicate(true)
	pending_client_recovery_state.clear()
	return state_copy


func consume_pending_runtime_recovery_state() -> Dictionary:
	var state_copy = pending_client_recovery_state.duplicate(true)
	pending_client_recovery_state.clear()
	return state_copy


func clear_recovery_snapshots() -> void:
	if session_persistence != null:
		session_persistence.clear_snapshots()
	if session_registry != null:
		session_registry.clear_active_session()


func reset_saved_sessions() -> void:
	leave_game_lobby()
	clear_recovery_snapshots()
	cached_state_snapshot.clear()
	active_session.clear()
	session_id = ""
	host_instance_id = ""
	local_player_token = ""
	pending_restore_snapshot.clear()
	pending_client_recovery_state.clear()

	var options = _get_options()
	if options != null:
		options.clear_session_credentials()
		options.set_last_join_endpoint("")

	emit_signal("session_resume_failed", "reset_by_user", "Session data reset")
	_push_system_message("Saved sessions cleared")


func _build_snapshot_payload() -> Dictionary:
	var options = _get_options()
	var host_port = 24567
	if options != null:
		host_port = options.host_port

	var scene_path = ""
	if get_tree().current_scene != null:
		scene_path = String(get_tree().current_scene.filename)

	var payload = {
		"host_endpoint": host_endpoint,
		"host_port": host_port,
		"lobby_members": lobby_members.duplicate(),
		"lobby_member_names": lobby_member_names.duplicate(),
		"player_latencies": player_latencies.duplicate(true),
		"scene_path": scene_path,
		"session_id": session_id,
		"host_instance_id": host_instance_id,
		"game_phase": _current_game_phase(),
		"session_players": _build_snapshot_players_payload(),
		"snapshot_ttl_sec": SESSION_TTL_SEC,
	}

	if cached_state_snapshot.size() > 0:
		payload["state_dict"] = cached_state_snapshot.duplicate(true)

	return payload


func _maybe_store_snapshot(force: bool = false) -> void:
	if not is_host() or session_persistence == null:
		return

	var now_msec = Time.get_ticks_msec()
	if not force and now_msec - last_snapshot_write_msec < SNAPSHOT_INTERVAL_MSEC:
		return

	if session_registry != null and not active_session.empty():
		active_session = session_registry.touch_session(active_session, SESSION_TTL_SEC)
		var _saved_active = session_registry.save_active_session(active_session)

	var payload = _build_snapshot_payload()
	if session_persistence.save_snapshot(payload):
		last_snapshot_write_msec = now_msec


func _flush_snapshot(force: bool = false) -> void:
	if force:
		_maybe_store_snapshot(true)
		return

	_maybe_store_snapshot(false)


