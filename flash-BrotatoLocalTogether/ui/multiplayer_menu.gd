extends Control

const LobbyEntry = preload("res://mods-unpacked/flash-BrotatoLocalTogether/ui/lobby_entry.tscn")
const SignalUtils = preload("res://mods-unpacked/flash-BrotatoLocalTogether/signal_utils.gd")
const DiagnosticsLogger = preload("res://mods-unpacked/flash-BrotatoLocalTogether/logging/diagnostics_logger.gd")

onready var lobbies_list = $"%Lobbies"
onready var create_lobby_button : Button = $"%CreateLobbyButton"
onready var refresh_lobbies_button : Button = $"HBoxContainer/ChatContainer2/VBoxContainer/HBoxContainer/RefreshLobbiesButton"
onready var controls_root : VBoxContainer = $"HBoxContainer/ChatContainer2/VBoxContainer"
onready var primary_controls_row : HBoxContainer = $"HBoxContainer/ChatContainer2/VBoxContainer/HBoxContainer"
onready var lobbies_scroll : ScrollContainer = $"HBoxContainer/ChatContainer2/VBoxContainer/ScrollContainer"

var network_connection
var brotatogether_options

var host_port_input : LineEdit
var advertise_ip_input : LineEdit
var join_endpoint_input : LineEdit
var join_endpoint_button : Button
var resume_snapshot_button : Button
var reset_sessions_button : Button
var log_metrics_button : Button
var host_controls_row : HBoxContainer
var join_controls_row : HBoxContainer
var session_controls_row : HBoxContainer
var endpoints_label : Label
var _join_button_pressed_count : int = 0
var _join_button_down_count : int = 0
var _join_button_connect_result : int = ERR_UNAVAILABLE

var shown_lobbies : Dictionary = {}
const DEFAULT_HOST_PORT := 24567


func _ready() -> void:
	_resolve_dependencies(true)

	_build_network_controls()
	_update_network_buttons_state()

	if network_connection != null:
		for message in network_connection.pending_system_messages:
			_append_system_message(String(message))
		network_connection.pending_system_messages.clear()

	if is_inside_tree():
		call_deferred("_safe_focus_create_lobby_button")
	CoopService.clear_coop_players()
	_on_refresh_lobbies_button_pressed()
	set_process(true)


func _exit_tree() -> void:
	if network_connection != null:
		SignalUtils.safe_disconnect(network_connection, "game_lobby_found", self, "_game_lobby_found")
	if host_port_input != null:
		SignalUtils.safe_disconnect(host_port_input, "text_entered", self, "_on_host_port_text_entered")
	if advertise_ip_input != null:
		SignalUtils.safe_disconnect(advertise_ip_input, "text_entered", self, "_on_advertise_ip_text_entered")
	if join_endpoint_input != null:
		SignalUtils.safe_disconnect(join_endpoint_input, "text_entered", self, "_on_join_endpoint_text_entered")
	if join_endpoint_button != null:
		SignalUtils.safe_disconnect(join_endpoint_button, "pressed", self, "_on_join_endpoint_button_pressed")
		SignalUtils.safe_disconnect(join_endpoint_button, "button_down", self, "_on_join_endpoint_button_down")
		SignalUtils.safe_disconnect(join_endpoint_button, "button_up", self, "_on_join_endpoint_button_up")
	if resume_snapshot_button != null:
		SignalUtils.safe_disconnect(resume_snapshot_button, "pressed", self, "_on_resume_snapshot_button_pressed")
	if reset_sessions_button != null:
		SignalUtils.safe_disconnect(reset_sessions_button, "pressed", self, "_on_reset_sessions_button_pressed")
	if log_metrics_button != null:
		SignalUtils.safe_disconnect(log_metrics_button, "pressed", self, "_on_log_metrics_button_pressed")


func _build_network_controls() -> void:
	primary_controls_row.add_constant_override("separation", 10)
	controls_root.add_constant_override("separation", 14)
	create_lobby_button.text = "Create Lobby"
	refresh_lobbies_button.text = "Refresh Endpoints"
	refresh_lobbies_button.rect_min_size = Vector2(260, 0)

	host_controls_row = HBoxContainer.new()
	host_controls_row.name = "HostControlsRow"
	host_controls_row.add_constant_override("separation", 10)
	_insert_row_before_scroll(host_controls_row)

	var host_label = _make_section_label("Host")
	host_controls_row.add_child(host_label)
	host_port_input = LineEdit.new()
	host_port_input.name = "HostPortInput"
	host_port_input.placeholder_text = "Port"
	host_port_input.rect_min_size = Vector2(120, 0)
	host_port_input.text = str(_get_host_port_fallback())
	SignalUtils.safe_connect(host_port_input, "text_entered", self, "_on_host_port_text_entered")
	host_controls_row.add_child(host_port_input)

	advertise_ip_input = LineEdit.new()
	advertise_ip_input.name = "AdvertiseIpInput"
	advertise_ip_input.placeholder_text = "Advertise IP (optional)"
	advertise_ip_input.rect_min_size = Vector2(280, 0)
	advertise_ip_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	advertise_ip_input.text = _get_preferred_advertise_ip_fallback()
	SignalUtils.safe_connect(advertise_ip_input, "text_entered", self, "_on_advertise_ip_text_entered")
	host_controls_row.add_child(advertise_ip_input)

	join_controls_row = HBoxContainer.new()
	join_controls_row.name = "JoinControlsRow"
	join_controls_row.add_constant_override("separation", 10)
	_insert_row_before_scroll(join_controls_row)

	var join_label = _make_section_label("Join")
	join_controls_row.add_child(join_label)

	join_endpoint_input = LineEdit.new()
	join_endpoint_input.name = "JoinEndpointInput"
	join_endpoint_input.placeholder_text = "host:port"
	join_endpoint_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_endpoint_input.rect_min_size = Vector2(320, 0)
	join_endpoint_input.text = _get_last_join_endpoint_fallback()
	SignalUtils.safe_connect(join_endpoint_input, "text_entered", self, "_on_join_endpoint_text_entered")
	join_controls_row.add_child(join_endpoint_input)

	join_endpoint_button = Button.new()
	join_endpoint_button.name = "JoinEndpointButton"
	join_endpoint_button.text = "Join Endpoint"
	join_endpoint_button.rect_min_size = Vector2(190, 0)
	_join_button_connect_result = SignalUtils.safe_connect(join_endpoint_button, "pressed", self, "_on_join_endpoint_button_pressed")
	SignalUtils.safe_connect(join_endpoint_button, "button_down", self, "_on_join_endpoint_button_down")
	SignalUtils.safe_connect(join_endpoint_button, "button_up", self, "_on_join_endpoint_button_up")
	join_controls_row.add_child(join_endpoint_button)

	session_controls_row = HBoxContainer.new()
	session_controls_row.name = "SessionControlsRow"
	session_controls_row.add_constant_override("separation", 10)
	_insert_row_before_scroll(session_controls_row)

	var session_label = _make_section_label("Sessions")
	session_controls_row.add_child(session_label)

	resume_snapshot_button = Button.new()
	resume_snapshot_button.name = "ResumeSnapshotButton"
	resume_snapshot_button.text = "Resume Snapshot"
	resume_snapshot_button.rect_min_size = Vector2(210, 0)
	SignalUtils.safe_connect(resume_snapshot_button, "pressed", self, "_on_resume_snapshot_button_pressed")
	session_controls_row.add_child(resume_snapshot_button)

	reset_sessions_button = Button.new()
	reset_sessions_button.name = "ResetSessionsButton"
	reset_sessions_button.text = "Reset Sessions"
	reset_sessions_button.rect_min_size = Vector2(190, 0)
	SignalUtils.safe_connect(reset_sessions_button, "pressed", self, "_on_reset_sessions_button_pressed")
	session_controls_row.add_child(reset_sessions_button)

	log_metrics_button = Button.new()
	log_metrics_button.name = "LogMetricsButton"
	log_metrics_button.text = "Log Metrics"
	log_metrics_button.rect_min_size = Vector2(170, 0)
	SignalUtils.safe_connect(log_metrics_button, "pressed", self, "_on_log_metrics_button_pressed")
	session_controls_row.add_child(log_metrics_button)

	endpoints_label = _make_section_label("Available Endpoints")
	_insert_row_before_scroll(endpoints_label)

	_update_resume_button_state()
	call_deferred("_run_join_button_probe", "build_controls")


func _update_resume_button_state() -> void:
	if resume_snapshot_button == null:
		return
	if network_connection == null:
		resume_snapshot_button.disabled = true
		return
	resume_snapshot_button.disabled = not network_connection.has_recovery_snapshot()


func _update_network_buttons_state() -> void:
	var has_network = network_connection != null
	if create_lobby_button != null:
		create_lobby_button.disabled = not has_network
	if refresh_lobbies_button != null:
		refresh_lobbies_button.disabled = not has_network
	if join_endpoint_button != null:
		join_endpoint_button.disabled = not has_network
	if reset_sessions_button != null:
		reset_sessions_button.disabled = not has_network
	if log_metrics_button != null:
		log_metrics_button.disabled = not has_network
	_update_resume_button_state()


func _resolve_dependencies(log_missing_once: bool = false) -> void:
	var had_network = network_connection != null
	var had_options = brotatogether_options != null

	if network_connection == null:
		network_connection = get_node_or_null("/root/NetworkConnection")
		if network_connection != null:
			SignalUtils.safe_connect(network_connection, "game_lobby_found", self, "_game_lobby_found")
			_append_system_message("NetworkConnection resolved")
		elif log_missing_once:
			_append_system_message("NetworkConnection is missing at /root/NetworkConnection")

	if brotatogether_options == null:
		brotatogether_options = get_node_or_null("/root/BrotogetherOptions")
		if brotatogether_options != null:
			_append_system_message("BrotogetherOptions resolved")
			if host_port_input != null:
				host_port_input.text = str(_get_host_port_fallback())
			if advertise_ip_input != null:
				advertise_ip_input.text = _get_preferred_advertise_ip_fallback()
			if join_endpoint_input != null and join_endpoint_input.text.strip_edges().empty():
				join_endpoint_input.text = _get_last_join_endpoint_fallback()
		elif log_missing_once:
			_append_system_message("BrotogetherOptions is missing at /root/BrotogetherOptions")

	if (had_network != (network_connection != null)) or (had_options != (brotatogether_options != null)):
		_update_network_buttons_state()
		if join_endpoint_button != null:
			call_deferred("_run_join_button_probe", "deps_changed")


func _process(_delta: float) -> void:
	if network_connection == null or brotatogether_options == null:
		_resolve_dependencies()
	else:
		set_process(false)


func _append_system_message(message : String) -> void:
	print("[BrotatoLocalTogether] " + message)
	DiagnosticsLogger.log_info_with_options(brotatogether_options, "MultiplayerMenu", message)


func _input(event:InputEvent) -> void:
	manage_back(event)


func manage_back(event:InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		RunData.current_zone = 0
		RunData.reload_music = false
		var _error = get_tree().change_scene(MenuData.title_screen_scene)


func _on_back_button_pressed() -> void:
	RunData.reload_music = false
	var _error = get_tree().change_scene(MenuData.title_screen_scene)


func _read_host_port() -> int:
	if host_port_input == null:
		return _get_host_port_fallback()

	var raw_value = host_port_input.text.strip_edges()
	if raw_value.empty() or not raw_value.is_valid_integer():
		return _get_host_port_fallback()

	return int(clamp(int(raw_value), 1024, 65535))


func _on_host_port_text_entered(_value: String) -> void:
	_on_create_lobby_button_pressed()


func _on_advertise_ip_text_entered(_value: String) -> void:
	_commit_advertise_ip()


func _commit_advertise_ip() -> void:
	_resolve_dependencies()
	if advertise_ip_input == null or brotatogether_options == null:
		return
	brotatogether_options.set_preferred_advertise_ip(advertise_ip_input.text)


func _on_create_lobby_button_pressed() -> void:
	_resolve_dependencies()
	if network_connection == null:
		_append_system_message("Cannot create lobby: NetworkConnection is unavailable")
		return
	var host_port = _read_host_port()
	host_port_input.text = str(host_port)
	if brotatogether_options != null:
		brotatogether_options.set_host_port(host_port)
	_commit_advertise_ip()
	network_connection.create_new_game_lobby(host_port)


func _on_join_endpoint_text_entered(_value: String) -> void:
	_on_join_endpoint_button_pressed()


func _on_join_endpoint_button_pressed() -> void:
	_join_button_pressed_count += 1
	_resolve_dependencies()
	DiagnosticsLogger.log_info_with_options(
		brotatogether_options,
		"JoinButton",
		"pressed count=%d connect_result=%d disabled=%s" % [
			_join_button_pressed_count,
			_join_button_connect_result,
			str(join_endpoint_button != null and join_endpoint_button.disabled),
		]
	)
	if join_endpoint_input == null:
		DiagnosticsLogger.log_warn_with_options(brotatogether_options, "JoinButton", "join_endpoint_input is null")
		return
	if network_connection == null:
		DiagnosticsLogger.log_warn_with_options(brotatogether_options, "JoinButton", "network_connection is null")
		_append_system_message("Cannot join endpoint: NetworkConnection is unavailable")
		return

	var endpoint = join_endpoint_input.text.strip_edges()
	DiagnosticsLogger.log_debug_with_options(
		brotatogether_options,
		"JoinButton",
		"raw endpoint='%s'" % endpoint
	)
	if endpoint.empty() and brotatogether_options != null:
		endpoint = brotatogether_options.last_join_endpoint
		DiagnosticsLogger.log_debug_with_options(
			brotatogether_options,
			"JoinButton",
			"fallback endpoint='%s'" % endpoint
		)

	if endpoint.empty():
		DiagnosticsLogger.log_warn_with_options(brotatogether_options, "JoinButton", "endpoint is empty after fallback")
		_append_system_message("Endpoint is empty")
		return

	join_endpoint_input.text = endpoint
	if brotatogether_options != null:
		brotatogether_options.set_last_join_endpoint(endpoint)
	DiagnosticsLogger.log_info_with_options(
		brotatogether_options,
		"JoinButton",
		"join_game_lobby('%s') called" % endpoint
	)
	network_connection.join_game_lobby(endpoint)


func _on_join_endpoint_button_down() -> void:
	_join_button_down_count += 1
	var mouse_over = false
	if join_endpoint_button != null and is_instance_valid(join_endpoint_button):
		mouse_over = join_endpoint_button.get_global_rect().has_point(get_global_mouse_position())
	DiagnosticsLogger.log_info_with_options(
		brotatogether_options,
		"JoinButton",
		"button_down count=%d mouse_over=%s disabled=%s" % [
			_join_button_down_count,
			str(mouse_over),
			str(join_endpoint_button != null and join_endpoint_button.disabled),
		]
	)


func _on_join_endpoint_button_up() -> void:
	DiagnosticsLogger.log_debug_with_options(
		brotatogether_options,
		"JoinButton",
		"button_up count=%d pressed_count=%d" % [_join_button_down_count, _join_button_pressed_count]
	)


func _on_resume_snapshot_button_pressed() -> void:
	_resolve_dependencies()
	if network_connection == null:
		_append_system_message("Cannot resume snapshot: NetworkConnection is unavailable")
		_update_resume_button_state()
		return

	if not network_connection.has_recovery_snapshot():
		_append_system_message("No recovery snapshot found")
		_update_resume_button_state()
		return

	if not network_connection.resume_from_latest_snapshot():
		_append_system_message("Failed to restore snapshot")
		_update_resume_button_state()


func _on_reset_sessions_button_pressed() -> void:
	_resolve_dependencies()
	if network_connection == null:
		return

	network_connection.reset_saved_sessions()
	if join_endpoint_input != null:
		join_endpoint_input.text = ""
	_append_system_message("Session data reset. Start from clean state.")
	_on_refresh_lobbies_button_pressed()


func _on_log_metrics_button_pressed() -> void:
	_resolve_dependencies()
	if network_connection == null:
		return
	if network_connection.has_method("dump_network_metrics_to_log"):
		network_connection.dump_network_metrics_to_log()
		_append_system_message("Network metrics logged.")


func _on_refresh_lobbies_button_pressed() -> void:
	_resolve_dependencies()
	for child in lobbies_list.get_children():
		child.queue_free()
	shown_lobbies.clear()

	if network_connection == null:
		_append_system_message("Cannot refresh endpoints: NetworkConnection is unavailable")
		_update_resume_button_state()
		return

	network_connection.request_lobby_search()
	_update_resume_button_state()


func _game_lobby_found(lobby_id, lobby_name) -> void:
	var lobby_key = String(lobby_id)
	if shown_lobbies.has(lobby_key):
		return

	shown_lobbies[lobby_key] = true

	var new_lobby_entry = LobbyEntry.instance()
	new_lobby_entry.lobby_id = lobby_id
	new_lobby_entry.lobby_name = lobby_name
	lobbies_list.add_child(new_lobby_entry)


func _insert_row_before_scroll(node: Control) -> void:
	controls_root.add_child(node)
	var scroll_index = lobbies_scroll.get_index()
	controls_root.move_child(node, scroll_index)


func _make_section_label(text_value: String) -> Label:
	var label = Label.new()
	label.text = text_value
	label.self_modulate = Color(0.86, 0.88, 0.93, 1.0)
	label.valign = Label.VALIGN_CENTER
	label.rect_min_size = Vector2(120, 0)
	return label


func _safe_focus_create_lobby_button() -> void:
	if not is_inside_tree():
		return
	if create_lobby_button == null or not is_instance_valid(create_lobby_button):
		return
	if not create_lobby_button.is_inside_tree():
		return
	create_lobby_button.grab_focus()


func _run_join_button_probe(stage: String) -> void:
	if join_endpoint_button == null:
		DiagnosticsLogger.log_warn_with_options(brotatogether_options, "JoinProbe", "stage=%s button is null" % stage)
		return
	var pressed_connected = join_endpoint_button.is_connected("pressed", self, "_on_join_endpoint_button_pressed")
	var down_connected = join_endpoint_button.is_connected("button_down", self, "_on_join_endpoint_button_down")
	var up_connected = join_endpoint_button.is_connected("button_up", self, "_on_join_endpoint_button_up")
	DiagnosticsLogger.log_info_with_options(
		brotatogether_options,
		"JoinProbe",
		"stage=%s disabled=%s visible=%s inside_tree=%s pressed_conn=%s down_conn=%s up_conn=%s focus_mode=%d mouse_filter=%d" % [
			stage,
			str(join_endpoint_button.disabled),
			str(join_endpoint_button.visible),
			str(join_endpoint_button.is_inside_tree()),
			str(pressed_connected),
			str(down_connected),
			str(up_connected),
			int(join_endpoint_button.focus_mode),
			int(join_endpoint_button.mouse_filter),
		]
	)


func _get_host_port_fallback() -> int:
	if brotatogether_options == null:
		return DEFAULT_HOST_PORT
	return int(brotatogether_options.host_port)


func _get_preferred_advertise_ip_fallback() -> String:
	if brotatogether_options == null:
		return ""
	return String(brotatogether_options.preferred_advertise_ip)


func _get_last_join_endpoint_fallback() -> String:
	if brotatogether_options == null:
		return ""
	return String(brotatogether_options.last_join_endpoint)


