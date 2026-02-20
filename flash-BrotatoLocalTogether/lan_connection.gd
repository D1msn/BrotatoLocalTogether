extends "res://mods-unpacked/flash-BrotatoLocalTogether/protocol_connection.gd"
# LAN-соединение поверх ENet с сохранением обратной совместимости API.

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
const ENVELOPE_KEY_COMPRESSED := "COMPRESSED"
const COMPRESSION_THRESHOLD_BYTES := 512
const MAX_DECOMPRESSED_BYTES := 8 * 1024 * 1024
const LOG_NAME := "BrotatoLocalTogether:SessionConnection"
const NETWORK_METRICS_NODE_NAME := "NetworkMetrics"
const DIAGNOSTICS_LOGGER_PATH := "res://mods-unpacked/flash-BrotatoLocalTogether/logging/diagnostics_logger.gd"
const SCENE_TRANSITION_TIMEOUT_MSEC := 12000
const SCENE_TRANSITION_RETRY_MSEC := 1000
const SCENE_TRANSITION_ROLE_HOST := "host"
const SCENE_TRANSITION_ROLE_CLIENT := "client"
const SCENE_TRANSITION_KEY_ID := "TRANSITION_ID"
const SCENE_TRANSITION_KEY_TARGET_SCENE := "TARGET_SCENE"
const SCENE_TRANSITION_KEY_SOURCE_SCENE := "SOURCE_SCENE"
const SCENE_TRANSITION_KEY_STARTED_AT_MSEC := "STARTED_AT_MSEC"
const SCENE_TRANSITION_KEY_TIMEOUT_MSEC := "TIMEOUT_MSEC"
const SCENE_TRANSITION_KEY_READY_SCENE := "READY_SCENE"
const SCENE_TRANSITION_KEY_READY_AT_MSEC := "READY_AT_MSEC"
const MIN_ENET_TRANSFER_CHANNEL := 1

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
var network_metrics_node : Node = null
var _last_seq_by_peer : Dictionary = {}
var _protocol_mismatch_dialog : AcceptDialog = null
var scene_transition_active : bool = false
var scene_transition_role : String = ""
var scene_transition_id : String = ""
var scene_transition_target_scene : String = ""
var scene_transition_source_scene : String = ""
var scene_transition_started_msec : int = 0
var scene_transition_deadline_msec : int = 0
var scene_transition_last_prepare_sent_msec : int = 0
var scene_transition_last_ready_sent_msec : int = 0
var scene_transition_prepare_sender_id : int = -1
var scene_transition_ready_by_peer : Dictionary = {}
var _shutdown_cleanup_done := false

signal session_resume_available(session_id, expires_at_unix)
signal session_resumed(session_id, player_slot)
signal session_resume_failed(reason_code, reason_text)


func _ready() -> void:
	_sync_logger_session_tag("")
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
	_last_seq_by_peer.clear()
	last_rejection_reason = ""
	attempted_tokenless_retry = false
	_reset_scene_transition_state()

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
	discover_lan_sessions()


func _physics_process(_delta : float) -> void:
	_tick_scene_transition_state_machine()


func _notification(what: int) -> void:
	if what == MainLoop.NOTIFICATION_WM_QUIT_REQUEST or what == NOTIFICATION_PREDELETE:
		_flush_snapshot(true)
		_cleanup_runtime_state()


func _exit_tree() -> void:
	_cleanup_runtime_state()


func _cleanup_runtime_state() -> void:
	if _shutdown_cleanup_done:
		return
	_shutdown_cleanup_done = true

	var tree = null
	if is_inside_tree():
		tree = get_tree()
	if tree != null:
		if tree.is_connected("network_peer_connected", self, "_on_network_peer_connected"):
			tree.disconnect("network_peer_connected", self, "_on_network_peer_connected")
		if tree.is_connected("network_peer_disconnected", self, "_on_network_peer_disconnected"):
			tree.disconnect("network_peer_disconnected", self, "_on_network_peer_disconnected")
		if tree.is_connected("connected_to_server", self, "_on_connected_to_server"):
			tree.disconnect("connected_to_server", self, "_on_connected_to_server")
		if tree.is_connected("connection_failed", self, "_on_connection_failed"):
			tree.disconnect("connection_failed", self, "_on_connection_failed")
		if tree.is_connected("server_disconnected", self, "_on_server_disconnected"):
			tree.disconnect("server_disconnected", self, "_on_server_disconnected")

	if ping_timer != null and is_instance_valid(ping_timer):
		if ping_timer.is_connected("timeout", self, "_ping_timer_timeout"):
			ping_timer.disconnect("timeout", self, "_ping_timer_timeout")
		ping_timer.stop()
		ping_timer.free()
	ping_timer = null

	if _protocol_mismatch_dialog != null and is_instance_valid(_protocol_mismatch_dialog):
		_protocol_mismatch_dialog.free()
	_protocol_mismatch_dialog = null

	_teardown_network_peer()


func _teardown_network_peer() -> void:
	var tree = null
	if is_inside_tree():
		tree = get_tree()
	if tree != null and tree.has_network_peer():
		tree.set_network_peer(null)

	if network_peer != null:
		network_peer.close_connection()
		network_peer = null


func create_lan_session(host_port: int = -1, restore_snapshot: Dictionary = {}) -> void:
	create_new_game_lobby(host_port, restore_snapshot)


func create_new_game_lobby(host_port: int = -1, restore_snapshot: Dictionary = {}) -> void:
	var options = _get_options()
	if options == null:
		_log_error("LanConnection", "create_new_game_lobby aborted: options node missing")
		return

	if host_port <= 0:
		host_port = options.host_port

	host_port = int(clamp(host_port, 1024, 65535))
	options.set_host_port(host_port)

	leave_game_lobby()

	var peer := NetworkedMultiplayerENet.new()
	var result = peer.create_server(host_port, MAX_PLAYERS - 1)
	if result != OK:
		_log_error("LanConnection", "create_server failed on port %d with error %d" % [host_port, result])
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
	_sync_logger_session_tag(session_id)
	pending_restore_snapshot.clear()

	known_peer_names.clear()
	slot_by_peer_id.clear()
	peer_id_by_slot.clear()
	token_by_peer_id.clear()
	_last_seq_by_peer.clear()

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


func join_lan_session(endpoint: String) -> void:
	join_game_lobby(endpoint)


func join_game_lobby(endpoint: String) -> void:
	var options = _get_options()
	if options == null:
		_log_error("LanConnection", "join_game_lobby aborted: options node missing")
		return

	var parsed = _parse_endpoint(endpoint)
	if not parsed["ok"]:
		_log_warn("LanConnection", "join_game_lobby rejected invalid endpoint: %s" % endpoint)
		_push_system_message("Invalid endpoint. Use host:port")
		return

	leave_game_lobby()

	var peer := NetworkedMultiplayerENet.new()
	var result = peer.create_client(parsed["host"], int(parsed["port"]))
	if result != OK:
		_log_warn("LanConnection", "create_client failed for %s:%d with error %d" % [parsed["host"], parsed["port"], result])
		_push_system_message("Connection failed to %s:%d" % [parsed["host"], parsed["port"]])
		return

	network_peer = peer
	get_tree().set_network_peer(network_peer)

	game_lobby_id = ACTIVE_LOBBY_ID
	game_lobby_owner_id = HOST_PEER_ID
	pending_join_endpoint = "%s:%d" % [parsed["host"], parsed["port"]]
	_sync_logger_session_tag("join:%s" % pending_join_endpoint)
	last_rejection_reason = ""
	pending_client_recovery_state.clear()
	attempted_tokenless_retry = false

	_push_system_message("Connecting to %s" % pending_join_endpoint)
	options.set_last_join_endpoint(pending_join_endpoint)
	options.joining_multiplayer_lobby = true
	options.in_multiplayer_game = false


func leave_lan_session() -> void:
	leave_game_lobby()


func leave_game_lobby() -> void:
	var was_host = is_host()
	if was_host:
		_flush_snapshot(true)

	if was_host and session_registry != null and not active_session.empty():
		active_session["status"] = "recoverable"
		active_session = session_registry.touch_session(active_session, SESSION_TTL_SEC)
		var _saved_active = session_registry.save_active_session(active_session)

	_teardown_network_peer()

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
	_last_seq_by_peer.clear()
	cached_state_snapshot.clear()
	active_session.clear()
	session_id = ""
	host_instance_id = ""
	local_player_token = ""
	last_rejection_reason = ""
	attempted_tokenless_retry = false
	host_endpoint = ""
	pending_join_endpoint = ""
	_sync_logger_session_tag("")
	_reset_scene_transition_state()

	var options = _get_options()
	if options != null:
		options.joining_multiplayer_lobby = false
		options.in_multiplayer_game = false

	emit_signal("lobby_players_updated")


func discover_lan_sessions() -> void:
	request_lobby_search()


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
	var payload_bytes: PoolByteArray = var2bytes(safe_payload)
	var should_compress_payload = payload_bytes.size() > COMPRESSION_THRESHOLD_BYTES
	var envelope_payload = safe_payload
	if should_compress_payload:
		var compressed_payload: PoolByteArray = payload_bytes.compress(File.COMPRESSION_GZIP)
		if compressed_payload.size() > 0:
			envelope_payload = compressed_payload
		else:
			should_compress_payload = false
	var envelope = _build_envelope(envelope_payload, message_type, should_compress_payload)
	var packet_data: PoolByteArray = var2bytes(envelope)

	if target_id == -1:
		if is_host():
			var connected_peers = tree.get_network_connected_peers()
			for peer_id in connected_peers:
				if peer_id == steam_id:
					continue
				_record_packet_sent_metrics(message_type, packet_data.size())
				_send_rpc_packet(int(peer_id), message_type, packet_data)
		elif game_lobby_owner_id > 0:
			_record_packet_sent_metrics(message_type, packet_data.size())
			_send_rpc_packet(game_lobby_owner_id, message_type, packet_data)
		return

	if target_id == steam_id:
		return

	_record_packet_sent_metrics(message_type, packet_data.size())
	_send_rpc_packet(int(target_id), message_type, packet_data)


remote func _receive_enet_packet(message_type : int, packet_data : PoolByteArray) -> void:
	if not is_inside_tree():
		return
	var tree = get_tree()
	if tree == null:
		return
	var sender_id = tree.get_rpc_sender_id()
	if not _is_allowed_sender_for_message(message_type, sender_id):
		ModLoaderLog.warning("Rejected packet from unknown peer %d" % sender_id, LOG_NAME)
		return

	var decoded_payload = null
	if packet_data.size() > 0:
		decoded_payload = bytes2var(packet_data)

	var packet = _parse_received_packet(message_type, decoded_payload, sender_id)
	if not bool(packet.get("ok", false)):
		return

	if bool(packet.get("compressed", false)):
		var compressed_payload = packet.get("payload_compressed", PoolByteArray())
		if not (compressed_payload is PoolByteArray):
			ModLoaderLog.warning("Compressed payload is not a PoolByteArray", LOG_NAME)
			return
		var unpacked_data = compressed_payload.decompress_dynamic(MAX_DECOMPRESSED_BYTES, File.COMPRESSION_GZIP)
		if unpacked_data.size() <= 0:
			ModLoaderLog.warning("Decompression failed or empty", LOG_NAME)
			return
		if unpacked_data.size() >= MAX_DECOMPRESSED_BYTES:
			ModLoaderLog.warning("Decompressed payload exceeds limit: %d bytes" % unpacked_data.size(), LOG_NAME)
			return
		var unpacked_payload = bytes2var(unpacked_data)
		if not (unpacked_payload is Dictionary):
			ModLoaderLog.warning("Decompressed payload is not a Dictionary", LOG_NAME)
			return
		packet["payload"] = unpacked_payload

	_dispatch_incoming_packet(
		int(packet.get("message_type", message_type)),
		packet.get("payload", {}),
		sender_id,
		packet_data.size(),
		int(packet.get("sequence", -1))
	)


func read_p2p_packet() -> void:
	return


func _dispatch_incoming_packet(channel : int, data : Dictionary, sender_id : int, packet_size: int = -1, packet_seq: int = -1) -> void:
	if packet_size >= 0:
		_record_packet_received_metrics(channel, packet_size)
	if not _is_allowed_sender_for_message(channel, sender_id):
		ModLoaderLog.warning("Rejected packet from unknown peer %d" % sender_id, LOG_NAME)
		_log_warn("Handshake", "Rejected packet from peer=%d type=%d (sender not allowed)" % [sender_id, channel])
		return
	if packet_seq > 0 and _is_duplicate_packet(sender_id, channel, packet_seq):
		ModLoaderLog.info("Dropped duplicate packet type=%d seq=%d from peer=%d" % [channel, packet_seq, sender_id], LOG_NAME)
		_log_debug("Handshake", "Dropped duplicate packet type=%d seq=%d sender=%d" % [channel, packet_seq, sender_id])
		return
	if not _is_valid_phase_packet(channel, data, sender_id):
		_log_warn("Handshake", "Rejected packet type=%d sender=%d due to phase guard" % [channel, sender_id])
		return

	if channel == SESSION_MESSAGE_REGISTER_CLIENT:
		_log_info("Handshake", "Received REGISTER_CLIENT from peer=%d" % sender_id)
		_receive_client_registration(data, sender_id)
		return
	elif channel == SESSION_MESSAGE_REGISTER_ACK:
		_log_info("Handshake", "Received REGISTER_ACK from peer=%d" % sender_id)
		_receive_client_registration_ack(data, sender_id)
		return
	elif channel == SESSION_MESSAGE_REGISTER_REJECT:
		_log_warn("Handshake", "Received REGISTER_REJECT from peer=%d" % sender_id)
		_receive_client_registration_reject(data, sender_id)
		return
	elif channel == SESSION_MESSAGE_LOBBY_SYNC:
		_log_debug("Handshake", "Received LOBBY_SYNC from peer=%d" % sender_id)
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
	elif channel == MessageType.MESSAGE_TYPE_SCENE_PREPARE:
		_receive_scene_prepare(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_SCENE_READY:
		_receive_scene_ready(data, sender_id)
	elif channel == MessageType.MESSAGE_TYPE_SCENE_COMMIT:
		_receive_scene_commit(data, sender_id)


func _is_allowed_sender_for_message(message_type: int, sender_id: int) -> bool:
	if sender_id <= 0:
		return false
	if sender_id == steam_id:
		return true
	if known_peer_names.has(sender_id):
		return true
	if message_type == SESSION_MESSAGE_REGISTER_CLIENT and is_host():
		return true
	if message_type == SESSION_MESSAGE_REGISTER_ACK and sender_id == game_lobby_owner_id:
		return true
	if message_type == SESSION_MESSAGE_REGISTER_REJECT and sender_id == game_lobby_owner_id:
		return true
	if message_type == SESSION_MESSAGE_LOBBY_SYNC and sender_id == game_lobby_owner_id:
		return true
	if message_type == SESSION_MESSAGE_RECOVERY_STATE and sender_id == game_lobby_owner_id:
		return true
	return false


func _is_valid_phase_packet(message_type: int, data: Dictionary, sender_id: int) -> bool:
	if session_registry == null:
		return true
	if not session_registry.has_method("is_valid_phase_transition"):
		return true

	var target_phase = _target_phase_for_message(message_type, data)
	if target_phase.empty():
		return true

	var from_phase = _normalize_phase_name(_current_game_phase())
	var to_phase = _normalize_phase_name(target_phase)
	if from_phase.empty() or to_phase.empty():
		return true
	if session_registry.is_valid_phase_transition(from_phase, to_phase):
		return true

	ModLoaderLog.warning(
		"Rejected packet type %d from peer %d due to invalid phase transition %s -> %s" % [message_type, sender_id, from_phase, to_phase],
		LOG_NAME
	)
	return false


func _is_duplicate_packet(sender_id: int, message_type: int, seq: int) -> bool:
	if seq <= 0:
		return false
	if not _last_seq_by_peer.has(sender_id):
		_last_seq_by_peer[sender_id] = {}

	var peer_seq_state: Dictionary = _last_seq_by_peer[sender_id]
	if not peer_seq_state.has(message_type):
		peer_seq_state[message_type] = seq
		_last_seq_by_peer[sender_id] = peer_seq_state
		return false

	var last_seq = int(peer_seq_state[message_type])

	if _is_unreliable_message(message_type):
		if seq <= last_seq:
			return true
		peer_seq_state[message_type] = seq
		_last_seq_by_peer[sender_id] = peer_seq_state
		return false

	if seq <= last_seq:
		return true

	peer_seq_state[message_type] = seq
	_last_seq_by_peer[sender_id] = peer_seq_state
	return false


func _target_phase_for_message(message_type: int, data: Dictionary) -> String:
	match message_type:
		SESSION_MESSAGE_REGISTER_ACK:
			return _normalize_phase_name(String(data.get("GAME_PHASE", "")))
		SESSION_MESSAGE_LOBBY_SYNC:
			return _normalize_phase_name(String(data.get("GAME_PHASE", "")))
		MessageType.MESSAGE_TYPE_CHARACTER_FOCUS:
			return "CHARACTER_SELECT"
		MessageType.MESSAGE_TYPE_CHARACTER_SELECTED:
			return "CHARACTER_SELECT"
		MessageType.MESSAGE_TYPE_CHARACTER_LOBBY_UPDATE:
			return "CHARACTER_SELECT"
		MessageType.MESSAGE_TYPE_CHARACTER_SELECTION_COMPLETED:
			return "CHARACTER_SELECT"
		MessageType.MESSAGE_TYPE_WEAPON_FOCUS:
			return "WEAPON_SELECT"
		MessageType.MESSAGE_TYPE_WEAPON_SELECTED:
			return "WEAPON_SELECT"
		MessageType.MESSAGE_TYPE_WEAPON_LOBBY_UPDATE:
			return "WEAPON_SELECT"
		MessageType.MESSAGE_TYPE_WEAPON_SELECTION_COMPLETED:
			return "WEAPON_SELECT"
		MessageType.MESSAGE_TYPE_DIFFICULTY_FOCUSED:
			return "DIFFICULTY_SELECT"
		MessageType.MESSAGE_TYPE_DIFFICULTY_PRESSED:
			return "DIFFICULTY_SELECT"
		MessageType.MESSAGE_TYPE_SHOP_LOBBY_UPDATE:
			return "SHOP"
		MessageType.MESSAGE_TYPE_SHOP_WEAPON_DISCARD:
			return "SHOP"
		MessageType.MESSAGE_TYPE_SHOP_BUY_ITEM:
			return "SHOP"
		MessageType.MESSAGE_TYPE_SHOP_REROLL:
			return "SHOP"
		MessageType.MESSAGE_TYPE_SHOP_COMBINE_WEAPON:
			return "SHOP"
		MessageType.MESSAGE_TYPE_SHOP_ITEM_FOCUS:
			return "SHOP"
		MessageType.MESSAGE_TYPE_SHOP_GO_BUTTON_UPDATED:
			return "SHOP"
		MessageType.MESSAGE_TYPE_SHOP_LOCK_ITEM:
			return "SHOP"
		MessageType.MESSAGE_TYPE_SHOP_UNLOCK_ITEM:
			return "SHOP"
		MessageType.MESSAGE_TYPE_SHOP_INVENTORY_ITEM_FOCUS:
			return "SHOP"
		MessageType.MESSAGE_TYPE_SHOP_CLOSE_POPUP:
			return "SHOP"
		MessageType.MESSAGE_TYPE_HOST_ENTERED_SHOP:
			return "SHOP"
		MessageType.MESSAGE_TYPE_MAIN_STATE:
			return "MAIN"
		MessageType.MESSAGE_TYPE_CLIENT_POSITION:
			return "MAIN"
		MessageType.MESSAGE_TYPE_CLIENT_FOCUS_MAIN_SCENE:
			return "MAIN"
		MessageType.MESSAGE_TYPE_MAIN_SCENE_REROLL_BUTTON_PRESSED:
			return "MAIN"
		MessageType.MESSAGE_TYPE_MAIN_SCENE_CHOOSE_UPGRADE_PRESSED:
			return "MAIN"
		MessageType.MESSAGE_TYPE_MAIN_SCENE_TAKE_BUTTON_PRESSED:
			return "MAIN"
		MessageType.MESSAGE_TYPE_MAIN_SCENE_DISCARD_BUTTON_PRESSED:
			return "MAIN"
		MessageType.MESSAGE_TYPE_HOST_ROUND_START:
			return "MAIN"
		MessageType.MESSAGE_TYPE_LEAVE_SHOP:
			return "MAIN"
		MessageType.MESSAGE_TYPE_SCENE_PREPARE:
			return _phase_for_scene_identity(String(data.get(SCENE_TRANSITION_KEY_TARGET_SCENE, "")), "")
		MessageType.MESSAGE_TYPE_SCENE_COMMIT:
			return _phase_for_scene_identity(String(data.get(SCENE_TRANSITION_KEY_TARGET_SCENE, "")), "")
	return ""


func _normalize_phase_name(phase_name: String) -> String:
	if session_registry != null and session_registry.has_method("normalize_game_phase"):
		return String(session_registry.normalize_game_phase(phase_name))
	return String(phase_name).strip_edges().to_upper()


func _phase_for_scene_identity(scene_path: String, scene_name: String) -> String:
	var normalized_path = String(scene_path).strip_edges().to_lower()
	var normalized_name = String(scene_name).strip_edges().to_lower()
	var scene_identity = "%s %s" % [normalized_path, normalized_name]

	if scene_identity.find("character_selection") != -1:
		return "CHARACTER_SELECT"
	if scene_identity.find("weapon_selection") != -1:
		return "WEAPON_SELECT"
	if scene_identity.find("difficulty_selection") != -1:
		return "DIFFICULTY_SELECT"
	if scene_identity.find("postgame") != -1:
		return "POSTGAME"
	if scene_identity.find("shop") != -1:
		return "SHOP"
	if scene_identity.find("multiplayer_menu") != -1 or scene_identity.find("main_menu") != -1 or scene_identity.find("lobby") != -1:
		return "LOBBY"
	if normalized_name == "main" or normalized_name == "clientmain" or normalized_name == "client_main":
		return "MAIN"
	if normalized_path.find("/main.") != -1 or normalized_path.find("/main/") != -1 or normalized_path.find("client_main") != -1:
		return "MAIN"

	return ""


func _on_network_peer_connected(peer_id : int) -> void:
	if not is_host():
		return

	if peer_id == steam_id:
		return


func _on_network_peer_disconnected(peer_id : int) -> void:
	player_latencies.erase(peer_id)
	if _last_seq_by_peer.has(peer_id):
		_last_seq_by_peer.erase(peer_id)
	_reset_interpolation_for_scene_entities()

	if is_host():
		if scene_transition_active and scene_transition_role == SCENE_TRANSITION_ROLE_HOST:
			if scene_transition_ready_by_peer.has(peer_id):
				scene_transition_ready_by_peer.erase(peer_id)
			if _all_scene_transition_peers_ready():
				_commit_scene_transition("peer_disconnected")

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
		_reset_scene_transition_state()
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
		_log_warn("Handshake", "_on_connected_to_server called with null network_peer")
		return
	attempted_tokenless_retry = false
	_reset_scene_transition_state()

	steam_id = get_tree().get_network_unique_id()
	game_lobby_id = ACTIVE_LOBBY_ID
	game_lobby_owner_id = HOST_PEER_ID

	known_peer_names.clear()
	slot_by_peer_id.clear()
	peer_id_by_slot.clear()
	token_by_peer_id.clear()
	_last_seq_by_peer.clear()
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
	_log_info(
		"Handshake",
		"connected_to_server peer_id=%d owner_id=%d pending_endpoint='%s' requested_session='%s' requested_token_empty=%s" % [
			steam_id,
			game_lobby_owner_id,
			pending_join_endpoint,
			requested_session_id,
			str(requested_token.empty()),
		]
	)

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
	_log_debug("Handshake", "REGISTER_CLIENT sent to owner=%d" % game_lobby_owner_id)


func _on_connection_failed() -> void:
	_log_warn("Handshake", "connection_failed for endpoint '%s'" % pending_join_endpoint)
	_push_system_message("Connection failed")
	leave_game_lobby()
	_go_to_multiplayer_menu()


func _on_server_disconnected() -> void:
	_log_warn("Handshake", "server_disconnected for endpoint '%s'" % pending_join_endpoint)
	_push_system_message("Server disconnected")
	leave_game_lobby()
	_go_to_multiplayer_menu()


func _receive_client_registration(data : Dictionary, sender_id : int) -> void:
	if not is_host():
		return
	_log_info(
		"HandshakeHost",
		"register_client from peer=%d username='%s' requested_session='%s' requested_token_empty=%s phase=%s" % [
			sender_id,
			String(data.get("USERNAME", "")),
			String(data.get("SESSION_ID", "")),
			str(String(data.get("PLAYER_TOKEN", "")).strip_edges().empty()),
			_current_game_phase(),
		]
	)

	if active_session.empty() or session_registry == null:
		_log_warn("HandshakeHost", "reject peer=%d reason=session_unavailable" % sender_id)
		_send_register_reject(sender_id, "session_unavailable", "Session is unavailable")
		return

	if session_registry.is_session_expired(active_session):
		_log_warn("HandshakeHost", "reject peer=%d reason=session_expired" % sender_id)
		_send_register_reject(sender_id, "session_expired", "Session expired")
		return

	var username = "Player %d" % sender_id
	if data.has("USERNAME"):
		username = _sanitize_username(String(data["USERNAME"]))
	var remote_protocol_version = int(data.get("PROTOCOL_VERSION", 0))
	if remote_protocol_version != PROTOCOL_VERSION:
		_log_warn(
			"HandshakeHost",
			"reject peer=%d reason=protocol_mismatch host=%d client=%d" % [sender_id, PROTOCOL_VERSION, remote_protocol_version]
		)
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
		_log_warn(
			"HandshakeHost",
			"reject peer=%d reason=session_mismatch requested='%s' actual='%s'" % [sender_id, requested_session_id, session_id]
		)
		_send_register_reject(sender_id, "session_mismatch", "Session ID mismatch")
		return

	if not assigned_token.empty():
		var existing_player = session_registry.find_player_by_token(active_session, assigned_token)
		if existing_player.empty():
			_log_warn("HandshakeHost", "reject peer=%d reason=token_unknown token='%s'" % [sender_id, assigned_token])
			_send_register_reject(sender_id, "token_unknown", "Unknown player token")
			return

		assigned_slot = int(existing_player.get("slot", -1))
		if assigned_slot < 0:
			_log_warn("HandshakeHost", "reject peer=%d reason=token_invalid_slot token='%s'" % [sender_id, assigned_token])
			_send_register_reject(sender_id, "token_invalid_slot", "Invalid token slot")
			return

		if peer_id_by_slot.has(assigned_slot) and int(peer_id_by_slot[assigned_slot]) != sender_id:
			_log_warn("HandshakeHost", "reject peer=%d reason=token_in_use slot=%d" % [sender_id, assigned_slot])
			_send_register_reject(sender_id, "token_in_use", "Player token already in use")
			return

		is_resumed = true
	else:
		var current_phase = _normalize_phase_name(_current_game_phase())
		# Новый игрок без resume-token допустим в лобби и pre-run фазах.
		# Блокируем только mid-run, чтобы не ломать синхронизацию активной волны.
		if current_phase == "MAIN" or current_phase == "SHOP":
			_log_warn("HandshakeHost", "reject peer=%d reason=late_join_blocked phase=%s" % [sender_id, current_phase])
			_send_register_reject(sender_id, "late_join_blocked", "Cannot join mid-run without resume token")
			return

		assigned_slot = session_registry.allocate_slot(active_session, MAX_PLAYERS)
		if assigned_slot < 0:
			_log_warn("HandshakeHost", "reject peer=%d reason=lobby_full" % sender_id)
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
	_log_info(
		"HandshakeHost",
		"ack sent to peer=%d slot=%d resumed=%s session='%s' phase=%s" % [
			sender_id,
			assigned_slot,
			str(is_resumed),
			session_id,
			String(ack_payload.get("GAME_PHASE", "")),
		]
	)
	_send_lobby_sync()

	if is_resumed and _current_game_phase() == "MAIN" and cached_state_snapshot.size() > 0:
		send_p2p_packet({"STATE_DICT": cached_state_snapshot.duplicate(true)}, SESSION_MESSAGE_RECOVERY_STATE, sender_id)

	emit_signal("lobby_players_updated")


func _receive_client_registration_ack(data : Dictionary, sender_id : int) -> void:
	if sender_id != game_lobby_owner_id:
		_log_warn(
			"HandshakeClient",
			"ignore register_ack from sender=%d expected_owner=%d" % [sender_id, game_lobby_owner_id]
		)
		return
	attempted_tokenless_retry = false

	if not data.has("SESSION_ID") or not data.has("PLAYER_TOKEN"):
		_log_warn("HandshakeClient", "register_ack malformed: missing SESSION_ID or PLAYER_TOKEN")
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
		_log_warn(
			"HandshakeClient",
			"register_ack protocol mismatch host=%d client=%d" % [remote_protocol_version, PROTOCOL_VERSION]
		)
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
	_log_info(
		"HandshakeClient",
		"register_ack accepted session='%s' slot=%d resumed=%s phase=%s host_endpoint='%s'" % [
			session_id,
			player_slot,
			str(resumed),
			game_phase,
			host_endpoint,
		]
	)

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
		_log_info("HandshakeClient", "changing scene to game main (resume)")
		var _scene_error = get_tree().change_scene(MenuData.game_scene)
		emit_signal("session_resumed", session_id, player_slot)
	else:
		_log_info("HandshakeClient", "changing scene to character selection")
		_change_scene_to_character_selection()
		_initiate_ping()


func _receive_client_registration_reject(data : Dictionary, sender_id : int) -> void:
	if sender_id != game_lobby_owner_id:
		_log_warn(
			"HandshakeClient",
			"ignore register_reject from sender=%d expected_owner=%d" % [sender_id, game_lobby_owner_id]
		)
		return

	var reason_code = String(data.get("REASON_CODE", "rejected"))
	var reason_text = String(data.get("REASON_TEXT", "Connection rejected"))
	var host_protocol_version = int(data.get("PROTOCOL_VERSION", -1))
	_log_warn(
		"HandshakeClient",
		"register_reject reason_code=%s reason_text='%s' host_version=%d tokenless_retry=%s" % [
			reason_code,
			reason_text,
			host_protocol_version,
			str(attempted_tokenless_retry),
		]
	)
	if reason_code == "protocol_mismatch":
		if host_protocol_version <= 0:
			var host_tag_index = reason_text.find("host=")
			if host_tag_index >= 0:
				var host_version_text = reason_text.substr(host_tag_index + 5, reason_text.length() - (host_tag_index + 5))
				var split_index = host_version_text.find(" ")
				if split_index >= 0:
					host_version_text = host_version_text.substr(0, split_index)
				if host_version_text.is_valid_integer():
					host_protocol_version = int(host_version_text)
		if host_protocol_version <= 0:
			host_protocol_version = 0
		reason_text = "Host version %d, You version %d. Please update!" % [host_protocol_version, PROTOCOL_VERSION]
		_show_protocol_mismatch_popup(host_protocol_version, PROTOCOL_VERSION)

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
		_log_info("HandshakeClient", "retry register without session/token after reject=%s" % reason_code)
		return

	last_rejection_reason = reason_code
	emit_signal("session_resume_failed", reason_code, reason_text)
	_push_system_message(reason_text)
	leave_game_lobby()
	_go_to_multiplayer_menu()


func _send_register_reject(target_peer_id: int, reason_code: String, reason_text: String) -> void:
	_log_warn(
		"HandshakeHost",
		"send register_reject to peer=%d reason_code=%s reason_text='%s'" % [target_peer_id, reason_code, reason_text]
	)
	send_p2p_packet(
		{
			"REASON_CODE": reason_code,
			"REASON_TEXT": reason_text,
			"PROTOCOL_VERSION": PROTOCOL_VERSION,
		},
		SESSION_MESSAGE_REGISTER_REJECT,
		target_peer_id
	)


func _respond_to_pong(data : Dictionary) -> void:
	if not data.has("PING_KEY"):
		_log_warn("LanConnection", "Pong sent without key")
		return

	if data["PING_KEY"] != ping_key:
		_log_warn("LanConnection", "Ping response key doesn't match")
		return

	if ping_start_time_msec == -1:
		_log_warn("LanConnection", "Ping request send without starting timer")
		return

	var current_time_msec = Time.get_ticks_msec()
	var latency_msec = max(0, current_time_msec - ping_start_time_msec)
	_record_packet_ack_metrics(1)
	_record_rtt_sample_metrics(float(latency_msec))

	send_p2p_packet({"LATENCY": str(latency_msec)}, MessageType.MESSAGE_TYPE_LATENCY_REPORT, game_lobby_owner_id)


func _next_outgoing_sequence() -> int:
	outgoing_sequence += 1
	if outgoing_sequence >= ENVELOPE_MAX_SEQ:
		outgoing_sequence = 1
	return outgoing_sequence


func _build_envelope(payload, message_type: int, payload_compressed: bool = false) -> Dictionary:
	return {
		ENVELOPE_KEY_PROTOCOL_VERSION: PROTOCOL_VERSION,
		ENVELOPE_KEY_MESSAGE_TYPE: message_type,
		ENVELOPE_KEY_SESSION_ID: session_id,
		ENVELOPE_KEY_SEQUENCE: _next_outgoing_sequence(),
		ENVELOPE_KEY_TICK: Engine.get_physics_frames(),
		ENVELOPE_KEY_SENT_AT_MSEC: Time.get_ticks_msec(),
		ENVELOPE_KEY_PAYLOAD: payload,
		ENVELOPE_KEY_COMPRESSED: payload_compressed,
	}


func _parse_received_packet(fallback_message_type: int, decoded_payload, sender_id: int) -> Dictionary:
	var result = {
		"ok": true,
		"message_type": fallback_message_type,
		"payload": {},
		"compressed": false,
		"payload_compressed": PoolByteArray(),
		"sequence": -1,
	}
	if not (decoded_payload is Dictionary):
		_log_warn("PacketParse", "drop packet from peer=%d type=%d reason=payload_not_dictionary" % [sender_id, fallback_message_type])
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
		not decoded_dict.has(ENVELOPE_KEY_PAYLOAD) or
		not decoded_dict.has(ENVELOPE_KEY_COMPRESSED)
	):
		_log_warn("PacketParse", "drop packet from peer=%d type=%d reason=missing_envelope_fields" % [sender_id, fallback_message_type])
		result["ok"] = false
		return result

	var remote_protocol_version = int(decoded_dict.get(ENVELOPE_KEY_PROTOCOL_VERSION, 0))
	var parsed_message_type = int(decoded_dict.get(ENVELOPE_KEY_MESSAGE_TYPE, fallback_message_type))
	var remote_session_id = String(decoded_dict.get(ENVELOPE_KEY_SESSION_ID, "")).strip_edges()
	var packet_sequence = int(decoded_dict.get(ENVELOPE_KEY_SEQUENCE, -1))
	var payload_data = decoded_dict.get(ENVELOPE_KEY_PAYLOAD, {})
	var payload_is_compressed = bool(decoded_dict.get(ENVELOPE_KEY_COMPRESSED, false))

	if parsed_message_type != fallback_message_type:
		_log_warn(
			"PacketParse",
			"drop packet from peer=%d reason=message_type_mismatch fallback=%d envelope=%d" % [
				sender_id,
				fallback_message_type,
				parsed_message_type,
			]
		)
		result["ok"] = false
		return result
	if packet_sequence <= 0:
		_log_warn("PacketParse", "drop packet from peer=%d type=%d reason=invalid_sequence seq=%d" % [sender_id, parsed_message_type, packet_sequence])
		result["ok"] = false
		return result

	if remote_protocol_version != PROTOCOL_VERSION:
		if parsed_message_type == SESSION_MESSAGE_REGISTER_CLIENT and is_host():
			_send_register_reject(
				sender_id,
				"protocol_mismatch",
				"Protocol mismatch: host=%d client=%d" % [PROTOCOL_VERSION, remote_protocol_version]
			)
		_log_warn(
			"PacketParse",
			"drop packet from peer=%d type=%d reason=protocol_mismatch host=%d remote=%d" % [
				sender_id,
				parsed_message_type,
				PROTOCOL_VERSION,
				remote_protocol_version,
			]
		)
		result["ok"] = false
		return result

	if _is_session_bound_message(parsed_message_type):
		if not session_id.empty() and not remote_session_id.empty() and remote_session_id != session_id:
			_log_warn(
				"PacketParse",
				"drop packet from peer=%d type=%d reason=session_mismatch local='%s' remote='%s'" % [
					sender_id,
					parsed_message_type,
					session_id,
					remote_session_id,
				]
			)
			result["ok"] = false
			return result

	if payload_is_compressed:
		if not (payload_data is PoolByteArray):
			_log_warn("PacketParse", "drop compressed packet from peer=%d type=%d reason=payload_not_poolbytearray" % [sender_id, parsed_message_type])
			result["ok"] = false
			return result
		result["compressed"] = true
		result["payload_compressed"] = payload_data
	else:
		if not (payload_data is Dictionary):
			_log_warn("PacketParse", "drop packet from peer=%d type=%d reason=payload_not_dictionary_uncompressed" % [sender_id, parsed_message_type])
			result["ok"] = false
			return result
		result["payload"] = payload_data

	result["message_type"] = parsed_message_type
	result["sequence"] = packet_sequence
	return result


func _is_session_bound_message(message_type: int) -> bool:
	if message_type == SESSION_MESSAGE_REGISTER_CLIENT:
		return false
	if message_type == SESSION_MESSAGE_REGISTER_ACK:
		return false
	if message_type == SESSION_MESSAGE_REGISTER_REJECT:
		return false
	return true


func start_scene_transition(target_scene_path: String) -> bool:
	if not is_host():
		return false

	var normalized_target_scene = String(target_scene_path).strip_edges()
	if normalized_target_scene.empty():
		return false

	if (
		scene_transition_active and
		scene_transition_role == SCENE_TRANSITION_ROLE_HOST and
		scene_transition_target_scene == normalized_target_scene
	):
		return true

	_reset_scene_transition_state()
	scene_transition_active = true
	scene_transition_role = SCENE_TRANSITION_ROLE_HOST
	scene_transition_id = _generate_random_id()
	scene_transition_target_scene = normalized_target_scene
	scene_transition_source_scene = _current_scene_path()
	scene_transition_started_msec = Time.get_ticks_msec()
	scene_transition_deadline_msec = scene_transition_started_msec + SCENE_TRANSITION_TIMEOUT_MSEC
	scene_transition_ready_by_peer[steam_id] = true

	for peer_value in lobby_members:
		var peer_id = int(peer_value)
		if peer_id <= 0 or peer_id == steam_id:
			continue
		scene_transition_ready_by_peer[peer_id] = false

	_send_scene_prepare_to_pending_peers(true)

	if _all_scene_transition_peers_ready():
		_commit_scene_transition("all_ready_initial")

	return true


func is_scene_transition_active() -> bool:
	return scene_transition_active


func _reset_scene_transition_state() -> void:
	scene_transition_active = false
	scene_transition_role = ""
	scene_transition_id = ""
	scene_transition_target_scene = ""
	scene_transition_source_scene = ""
	scene_transition_started_msec = 0
	scene_transition_deadline_msec = 0
	scene_transition_last_prepare_sent_msec = 0
	scene_transition_last_ready_sent_msec = 0
	scene_transition_prepare_sender_id = -1
	scene_transition_ready_by_peer.clear()


func _tick_scene_transition_state_machine() -> void:
	if not scene_transition_active:
		return

	var now_msec = Time.get_ticks_msec()

	if scene_transition_role == SCENE_TRANSITION_ROLE_HOST:
		if _all_scene_transition_peers_ready():
			_commit_scene_transition("all_ready")
			return

		if now_msec - scene_transition_last_prepare_sent_msec >= SCENE_TRANSITION_RETRY_MSEC:
			_send_scene_prepare_to_pending_peers(false)

		if now_msec >= scene_transition_deadline_msec:
			ModLoaderLog.warning(
				"Scene transition timeout after %d ms (id=%s, target=%s)"
				% [max(0, now_msec - scene_transition_started_msec), scene_transition_id, scene_transition_target_scene],
				LOG_NAME
			)
			_commit_scene_transition("timeout")
		return

	if scene_transition_role == SCENE_TRANSITION_ROLE_CLIENT:
		if scene_transition_prepare_sender_id <= 0:
			return

		if now_msec - scene_transition_last_ready_sent_msec >= SCENE_TRANSITION_RETRY_MSEC:
			_send_scene_ready(scene_transition_prepare_sender_id)


func _all_scene_transition_peers_ready() -> bool:
	if scene_transition_ready_by_peer.empty():
		return true

	var ready_snapshot: Dictionary = scene_transition_ready_by_peer.duplicate(true)
	for peer_id_value in ready_snapshot.keys():
		var peer_id = int(peer_id_value)
		if peer_id <= 0:
			continue
		if not _is_peer_in_lobby_members(peer_id):
			continue
		if not bool(ready_snapshot.get(peer_id, false)):
			return false
	return true


func _is_peer_in_lobby_members(peer_id: int) -> bool:
	if peer_id == steam_id:
		return true
	for member in lobby_members:
		if int(member) == peer_id:
			return true
	return false


func _reset_interpolation_for_scene_entities() -> void:
	if not is_inside_tree():
		return
	var tree = get_tree()
	if tree == null or tree.current_scene == null:
		return
	_reset_interpolation_for_node(tree.current_scene)


func _reset_interpolation_for_node(node: Node) -> void:
	if node == null:
		return
	if node.has_method("reset_interpolation"):
		node.call_deferred("reset_interpolation")
	for child in node.get_children():
		if child is Node:
			_reset_interpolation_for_node(child)


func _scene_transition_prepare_payload() -> Dictionary:
	return {
		SCENE_TRANSITION_KEY_ID: scene_transition_id,
		SCENE_TRANSITION_KEY_TARGET_SCENE: scene_transition_target_scene,
		SCENE_TRANSITION_KEY_SOURCE_SCENE: scene_transition_source_scene,
		SCENE_TRANSITION_KEY_STARTED_AT_MSEC: scene_transition_started_msec,
		SCENE_TRANSITION_KEY_TIMEOUT_MSEC: SCENE_TRANSITION_TIMEOUT_MSEC,
	}


func _send_scene_prepare_to_pending_peers(send_all: bool) -> void:
	if not scene_transition_active or scene_transition_role != SCENE_TRANSITION_ROLE_HOST:
		return

	var payload = _scene_transition_prepare_payload()
	if send_all:
		send_p2p_packet(payload, MessageType.MESSAGE_TYPE_SCENE_PREPARE)
	else:
		for peer_id_value in scene_transition_ready_by_peer.keys():
			var peer_id = int(peer_id_value)
			if peer_id <= 0 or peer_id == steam_id:
				continue
			if bool(scene_transition_ready_by_peer[peer_id]):
				continue
			send_p2p_packet(payload, MessageType.MESSAGE_TYPE_SCENE_PREPARE, peer_id)

	scene_transition_last_prepare_sent_msec = Time.get_ticks_msec()


func _send_scene_ready(target_peer_id: int) -> void:
	if not scene_transition_active or scene_transition_role != SCENE_TRANSITION_ROLE_CLIENT:
		return
	if target_peer_id <= 0:
		return
	if scene_transition_id.empty():
		return

	var payload = {
		SCENE_TRANSITION_KEY_ID: scene_transition_id,
		SCENE_TRANSITION_KEY_READY_SCENE: _current_scene_path(),
		SCENE_TRANSITION_KEY_READY_AT_MSEC: Time.get_ticks_msec(),
	}
	send_p2p_packet(payload, MessageType.MESSAGE_TYPE_SCENE_READY, target_peer_id)
	scene_transition_last_ready_sent_msec = Time.get_ticks_msec()


func _commit_scene_transition(_reason: String) -> void:
	if not scene_transition_active or scene_transition_role != SCENE_TRANSITION_ROLE_HOST:
		return

	var payload = {
		SCENE_TRANSITION_KEY_ID: scene_transition_id,
		SCENE_TRANSITION_KEY_TARGET_SCENE: scene_transition_target_scene,
		SCENE_TRANSITION_KEY_SOURCE_SCENE: scene_transition_source_scene,
		SCENE_TRANSITION_KEY_STARTED_AT_MSEC: scene_transition_started_msec,
	}
	send_p2p_packet(payload, MessageType.MESSAGE_TYPE_SCENE_COMMIT)
	_apply_scene_commit(scene_transition_target_scene)
	_reset_scene_transition_state()


func _receive_scene_prepare(data: Dictionary, sender_id: int) -> void:
	if is_host():
		return
	if sender_id != game_lobby_owner_id:
		return

	var transition_id = String(data.get(SCENE_TRANSITION_KEY_ID, "")).strip_edges()
	var target_scene = String(data.get(SCENE_TRANSITION_KEY_TARGET_SCENE, "")).strip_edges()
	if transition_id.empty() or target_scene.empty():
		return

	var timeout_msec = int(data.get(SCENE_TRANSITION_KEY_TIMEOUT_MSEC, SCENE_TRANSITION_TIMEOUT_MSEC))
	timeout_msec = int(clamp(timeout_msec, 10000, 15000))
	var now_msec = Time.get_ticks_msec()
	var started_at_msec = int(data.get(SCENE_TRANSITION_KEY_STARTED_AT_MSEC, now_msec))
	if started_at_msec <= 0:
		started_at_msec = now_msec
	if started_at_msec > now_msec:
		started_at_msec = now_msec
	if started_at_msec + timeout_msec < now_msec:
		return

	var is_same_transition = (
		scene_transition_active and
		scene_transition_role == SCENE_TRANSITION_ROLE_CLIENT and
		scene_transition_id == transition_id and
		scene_transition_target_scene == target_scene
	)

	if not is_same_transition:
		scene_transition_active = true
		scene_transition_role = SCENE_TRANSITION_ROLE_CLIENT
		scene_transition_id = transition_id
		scene_transition_target_scene = target_scene
		scene_transition_source_scene = String(data.get(SCENE_TRANSITION_KEY_SOURCE_SCENE, ""))
		scene_transition_started_msec = started_at_msec
	scene_transition_deadline_msec = started_at_msec + timeout_msec

	scene_transition_prepare_sender_id = sender_id
	_send_scene_ready(scene_transition_prepare_sender_id)


func _receive_scene_ready(data: Dictionary, sender_id: int) -> void:
	if not is_host():
		return
	if not scene_transition_active or scene_transition_role != SCENE_TRANSITION_ROLE_HOST:
		return

	var transition_id = String(data.get(SCENE_TRANSITION_KEY_ID, "")).strip_edges()
	if transition_id.empty() or transition_id != scene_transition_id:
		return

	if sender_id > 0:
		scene_transition_ready_by_peer[sender_id] = true

	if _all_scene_transition_peers_ready():
		_commit_scene_transition("all_ready_ack")


func _receive_scene_commit(data: Dictionary, sender_id: int) -> void:
	if sender_id != game_lobby_owner_id and sender_id != steam_id:
		return

	var target_scene = String(data.get(SCENE_TRANSITION_KEY_TARGET_SCENE, "")).strip_edges()
	if target_scene.empty():
		return

	var transition_id = String(data.get(SCENE_TRANSITION_KEY_ID, "")).strip_edges()
	if is_host() and scene_transition_active and scene_transition_role == SCENE_TRANSITION_ROLE_HOST:
		if transition_id == scene_transition_id:
			return

	_apply_scene_commit(target_scene)
	_reset_scene_transition_state()


func _current_scene_path() -> String:
	if not is_inside_tree():
		return ""

	var tree = get_tree()
	if tree == null or tree.current_scene == null:
		return ""

	var scene_path = String(tree.current_scene.filename).strip_edges()
	if not scene_path.empty():
		return scene_path
	return String(tree.current_scene.name).strip_edges()


func _apply_scene_commit(target_scene: String) -> void:
	if target_scene.empty():
		return
	if not is_inside_tree():
		return

	var tree = get_tree()
	if tree == null:
		return
	if tree.current_scene != null:
		var current_scene_path = String(tree.current_scene.filename).strip_edges()
		if current_scene_path == target_scene:
			return

	var _scene_error = tree.change_scene(target_scene)


func _send_rpc_packet(target_peer_id: int, message_type: int, packet_data: PoolByteArray) -> void:
	if target_peer_id <= 0:
		return
	if network_peer == null:
		return
	if int(network_peer.get_connection_status()) != NetworkedMultiplayerPeer.CONNECTION_CONNECTED:
		return

	var previous_channel = _sanitize_transfer_channel(int(network_peer.transfer_channel))
	var previous_mode = int(network_peer.transfer_mode)
	if previous_mode < 0:
		previous_mode = NetworkedMultiplayerPeer.TRANSFER_MODE_RELIABLE

	var transfer_channel = _transfer_channel_for_message(message_type)
	transfer_channel = _sanitize_transfer_channel(transfer_channel)

	var is_unreliable = _is_unreliable_message(message_type)
	var is_reliable = _is_reliable_message(message_type)
	if is_unreliable and is_reliable:
		is_unreliable = false

	var transfer_mode = NetworkedMultiplayerPeer.TRANSFER_MODE_RELIABLE
	if is_unreliable and not is_reliable:
		transfer_mode = NetworkedMultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED

	# Перед отправкой всегда выставляем физический канал и режим доставки.
	network_peer.transfer_channel = transfer_channel
	network_peer.transfer_mode = transfer_mode
	rpc_id(target_peer_id, "_receive_enet_packet", message_type, packet_data)

	if int(network_peer.transfer_channel) != previous_channel:
		network_peer.transfer_channel = previous_channel
	if int(network_peer.transfer_mode) != previous_mode:
		network_peer.transfer_mode = previous_mode


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
		MessageType.MESSAGE_TYPE_SCENE_PREPARE:
			return true
		MessageType.MESSAGE_TYPE_SCENE_READY:
			return true
		MessageType.MESSAGE_TYPE_SCENE_COMMIT:
			return true
	return false


func _transfer_channel_for_message(message_type: int) -> int:
	# Для совместимости RPC в текущей сборке держим единый ENet-канал.
	# Надёжность разделяем через transfer_mode (reliable/unreliable).
	var _unused_message_type = message_type
	return MIN_ENET_TRANSFER_CHANNEL


func _sanitize_transfer_channel(channel: int) -> int:
	if channel < MIN_ENET_TRANSFER_CHANNEL:
		return MIN_ENET_TRANSFER_CHANNEL
	return channel


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
	_log_info("LanConnection", message)
	pending_system_messages.push_back(message)
	emit_signal("global_chat_received", "SYSTEM", message)


func _sync_logger_session_tag(tag: String) -> void:
	var logger_script = load(DIAGNOSTICS_LOGGER_PATH)
	if logger_script == null:
		return
	var session_tag = String(tag).strip_edges()
	if session_tag.empty():
		if logger_script.has_method("clear_session"):
			logger_script.clear_session()
		return
	if logger_script.has_method("set_session"):
		logger_script.set_session(session_tag)


func _log_info(tag: String, message: String) -> void:
	_log_with_level(tag, message, "INFO")


func _log_debug(tag: String, message: String) -> void:
	_log_with_level(tag, message, "DEBUG")


func _log_warn(tag: String, message: String) -> void:
	_log_with_level(tag, message, "WARN")


func _log_error(tag: String, message: String) -> void:
	_log_with_level(tag, message, "ERROR")


func _log_with_level(tag: String, message: String, level: String) -> void:
	var logger_script = load(DIAGNOSTICS_LOGGER_PATH)
	if logger_script == null:
		return
	var options = _get_options()
	match String(level).to_upper():
		"ERROR":
			if logger_script.has_method("log_error_with_options"):
				logger_script.log_error_with_options(options, tag, message)
			elif logger_script.has_method("log_with_options"):
				logger_script.log_with_options(options, tag, message)
		"WARN":
			if logger_script.has_method("log_warn_with_options"):
				logger_script.log_warn_with_options(options, tag, message)
			elif logger_script.has_method("log_with_options"):
				logger_script.log_with_options(options, tag, message)
		"INFO":
			if logger_script.has_method("log_info_with_options"):
				logger_script.log_info_with_options(options, tag, message)
			elif logger_script.has_method("log_with_options"):
				logger_script.log_with_options(options, tag, message)
		_:
			if logger_script.has_method("log_debug_with_options"):
				logger_script.log_debug_with_options(options, tag, message)
			elif logger_script.has_method("log_with_options"):
				logger_script.log_with_options(options, tag, message)


func _show_protocol_mismatch_popup(host_version: int, client_version: int) -> void:
	var message = "Host version %d, You version %d. Please update!" % [host_version, client_version]
	var tree = get_tree()
	if tree == null or tree.current_scene == null:
		_push_system_message(message)
		return

	if _protocol_mismatch_dialog != null and is_instance_valid(_protocol_mismatch_dialog):
		_protocol_mismatch_dialog.dialog_text = message
		_protocol_mismatch_dialog.popup_centered()
		return

	var dialog := AcceptDialog.new()
	dialog.window_title = "Protocol mismatch"
	dialog.dialog_text = message
	dialog.connect("popup_hide", self, "_on_protocol_mismatch_popup_hide")
	dialog.connect("popup_hide", dialog, "queue_free")
	tree.current_scene.add_child(dialog)
	_protocol_mismatch_dialog = dialog
	dialog.popup_centered()


func _on_protocol_mismatch_popup_hide() -> void:
	_protocol_mismatch_dialog = null


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
	if not is_inside_tree():
		return "LOBBY"

	var tree = get_tree()
	if tree != null and tree.current_scene != null:
		var scene_path = String(tree.current_scene.filename)
		var scene_name = String(tree.current_scene.name)
		var scene_phase = _phase_for_scene_identity(scene_path, scene_name)
		if not scene_phase.empty():
			return scene_phase

	var options = _get_options()
	if options != null and options.in_multiplayer_game:
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


func _get_network_metrics_node() -> Node:
	if network_metrics_node != null and is_instance_valid(network_metrics_node):
		return network_metrics_node
	if not is_inside_tree():
		return null
	var tree = get_tree()
	if tree == null or tree.root == null:
		return null
	network_metrics_node = tree.root.get_node_or_null(NETWORK_METRICS_NODE_NAME)
	return network_metrics_node


func _record_packet_sent_metrics(message_type: int, packet_size: int) -> void:
	var metrics = _get_network_metrics_node()
	if metrics != null and metrics.has_method("record_packet_sent"):
		metrics.record_packet_sent(message_type, packet_size)


func _record_packet_received_metrics(message_type: int, packet_size: int) -> void:
	var metrics = _get_network_metrics_node()
	if metrics != null and metrics.has_method("record_packet_received"):
		metrics.record_packet_received(message_type, packet_size)


func _record_packet_ack_metrics(ack_count: int) -> void:
	var metrics = _get_network_metrics_node()
	if metrics != null and metrics.has_method("record_packet_acknowledged"):
		metrics.record_packet_acknowledged(ack_count)


func _record_rtt_sample_metrics(rtt_msec: float) -> void:
	var metrics = _get_network_metrics_node()
	if metrics != null and metrics.has_method("add_rtt_sample"):
		metrics.add_rtt_sample(rtt_msec)


func get_network_metrics_snapshot() -> Dictionary:
	var metrics = _get_network_metrics_node()
	if metrics == null or not metrics.has_method("get_snapshot"):
		return {}
	var snapshot = metrics.get_snapshot()
	if snapshot is Dictionary:
		return snapshot
	return {}


func dump_network_metrics_to_log() -> void:
	var snapshot = get_network_metrics_snapshot()
	if snapshot.empty():
		ModLoaderLog.info("Network metrics unavailable", LOG_NAME)
		return

	var options = _get_options()
	var logger_script = load(DIAGNOSTICS_LOGGER_PATH)
	if logger_script != null:
		if logger_script.has_method("log_network_metrics_with_options"):
			logger_script.log_network_metrics_with_options(options, "NetworkMetrics", snapshot)
		elif logger_script.has_method("log_with_options"):
			logger_script.log_with_options(options, "NetworkMetrics", str(snapshot))

	ModLoaderLog.info(
		(
			"Network metrics: sent=%d received=%d bytes_sent=%d bytes_received=%d loss=%.3f p50=%.2fms p95=%.2fms jitter=%.2fms"
			% [
				int(snapshot.get("packet_sent_count", 0)),
				int(snapshot.get("packet_received_count", 0)),
				int(snapshot.get("bytes_sent", 0)),
				int(snapshot.get("bytes_received", 0)),
				float(snapshot.get("packet_loss_rate", 0.0)),
				float(snapshot.get("rtt_p50_msec", 0.0)),
				float(snapshot.get("rtt_p95_msec", 0.0)),
				float(snapshot.get("jitter_msec", 0.0)),
			]
		),
		LOG_NAME
	)


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


