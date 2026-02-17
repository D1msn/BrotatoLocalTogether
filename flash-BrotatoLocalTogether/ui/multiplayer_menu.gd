extends Control

const LobbyEntry = preload("res://mods-unpacked/flash-BrotatoLocalTogether/ui/lobby_entry.tscn")

onready var lobbies_list = $"%Lobbies"
onready var create_lobby_button : Button = $"%CreateLobbyButton"
onready var refresh_lobbies_button : Button = $"HBoxContainer/ChatContainer2/VBoxContainer/HBoxContainer/RefreshLobbiesButton"
onready var controls_root : VBoxContainer = $"HBoxContainer/ChatContainer2/VBoxContainer"
onready var primary_controls_row : HBoxContainer = $"HBoxContainer/ChatContainer2/VBoxContainer/HBoxContainer"
onready var lobbies_scroll : ScrollContainer = $"HBoxContainer/ChatContainer2/VBoxContainer/ScrollContainer"

var steam_connection
var brotatogether_options

var host_port_input : LineEdit
var advertise_ip_input : LineEdit
var join_endpoint_input : LineEdit
var join_endpoint_button : Button
var resume_snapshot_button : Button
var reset_sessions_button : Button
var host_controls_row : HBoxContainer
var join_controls_row : HBoxContainer
var session_controls_row : HBoxContainer
var endpoints_label : Label

var shown_lobbies : Dictionary = {}


func _ready() -> void:
	steam_connection = $"/root/NetworkConnection"
	steam_connection.connect("game_lobby_found", self, "_game_lobby_found")

	brotatogether_options = $"/root/BrotogetherOptions"
	_build_network_controls()

	for message in steam_connection.pending_system_messages:
		_append_system_message(String(message))
	steam_connection.pending_system_messages.clear()

	if is_inside_tree():
		create_lobby_button.call_deferred("grab_focus")
	CoopService.clear_coop_players()
	_on_refresh_lobbies_button_pressed()


func _build_network_controls() -> void:
	primary_controls_row.custom_constants/separation = 10
	controls_root.custom_constants/separation = 14
	create_lobby_button.text = "Create Lobby"
	refresh_lobbies_button.text = "Refresh Endpoints"
	refresh_lobbies_button.rect_min_size = Vector2(260, 0)

	host_controls_row = HBoxContainer.new()
	host_controls_row.name = "HostControlsRow"
	host_controls_row.custom_constants/separation = 10
	_insert_row_before_scroll(host_controls_row)

	var host_label = _make_section_label("Host")
	host_controls_row.add_child(host_label)
	host_port_input = LineEdit.new()
	host_port_input.name = "HostPortInput"
	host_port_input.placeholder_text = "Port"
	host_port_input.rect_min_size = Vector2(120, 0)
	host_port_input.text = str(brotatogether_options.host_port)
	host_port_input.connect("text_entered", self, "_on_host_port_text_entered")
	host_controls_row.add_child(host_port_input)

	advertise_ip_input = LineEdit.new()
	advertise_ip_input.name = "AdvertiseIpInput"
	advertise_ip_input.placeholder_text = "Advertise IP (optional)"
	advertise_ip_input.rect_min_size = Vector2(280, 0)
	advertise_ip_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	advertise_ip_input.text = brotatogether_options.preferred_advertise_ip
	advertise_ip_input.connect("text_entered", self, "_on_advertise_ip_text_entered")
	host_controls_row.add_child(advertise_ip_input)

	join_controls_row = HBoxContainer.new()
	join_controls_row.name = "JoinControlsRow"
	join_controls_row.custom_constants/separation = 10
	_insert_row_before_scroll(join_controls_row)

	var join_label = _make_section_label("Join")
	join_controls_row.add_child(join_label)

	join_endpoint_input = LineEdit.new()
	join_endpoint_input.name = "JoinEndpointInput"
	join_endpoint_input.placeholder_text = "host:port"
	join_endpoint_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_endpoint_input.rect_min_size = Vector2(320, 0)
	join_endpoint_input.text = brotatogether_options.last_join_endpoint
	join_endpoint_input.connect("text_entered", self, "_on_join_endpoint_text_entered")
	join_controls_row.add_child(join_endpoint_input)

	join_endpoint_button = Button.new()
	join_endpoint_button.name = "JoinEndpointButton"
	join_endpoint_button.text = "Join Endpoint"
	join_endpoint_button.rect_min_size = Vector2(190, 0)
	join_endpoint_button.connect("pressed", self, "_on_join_endpoint_button_pressed")
	join_controls_row.add_child(join_endpoint_button)

	session_controls_row = HBoxContainer.new()
	session_controls_row.name = "SessionControlsRow"
	session_controls_row.custom_constants/separation = 10
	_insert_row_before_scroll(session_controls_row)

	var session_label = _make_section_label("Sessions")
	session_controls_row.add_child(session_label)

	resume_snapshot_button = Button.new()
	resume_snapshot_button.name = "ResumeSnapshotButton"
	resume_snapshot_button.text = "Resume Snapshot"
	resume_snapshot_button.rect_min_size = Vector2(210, 0)
	resume_snapshot_button.connect("pressed", self, "_on_resume_snapshot_button_pressed")
	session_controls_row.add_child(resume_snapshot_button)

	reset_sessions_button = Button.new()
	reset_sessions_button.name = "ResetSessionsButton"
	reset_sessions_button.text = "Reset Sessions"
	reset_sessions_button.rect_min_size = Vector2(190, 0)
	reset_sessions_button.connect("pressed", self, "_on_reset_sessions_button_pressed")
	session_controls_row.add_child(reset_sessions_button)

	endpoints_label = _make_section_label("Available Endpoints")
	_insert_row_before_scroll(endpoints_label)

	_update_resume_button_state()


func _update_resume_button_state() -> void:
	if resume_snapshot_button == null:
		return
	resume_snapshot_button.disabled = not steam_connection.has_recovery_snapshot()


func _append_system_message(message : String) -> void:
	print("[BrotatoLocalTogether] " + message)


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
		return brotatogether_options.host_port

	var raw_value = host_port_input.text.strip_edges()
	if raw_value.empty() or not raw_value.is_valid_integer():
		return brotatogether_options.host_port

	return int(clamp(int(raw_value), 1024, 65535))


func _on_host_port_text_entered(_value: String) -> void:
	_on_create_lobby_button_pressed()


func _on_advertise_ip_text_entered(_value: String) -> void:
	_commit_advertise_ip()


func _commit_advertise_ip() -> void:
	if advertise_ip_input == null:
		return
	brotatogether_options.set_preferred_advertise_ip(advertise_ip_input.text)


func _on_create_lobby_button_pressed() -> void:
	var host_port = _read_host_port()
	host_port_input.text = str(host_port)
	brotatogether_options.set_host_port(host_port)
	_commit_advertise_ip()
	steam_connection.create_new_game_lobby(host_port)


func _on_join_endpoint_text_entered(_value: String) -> void:
	_on_join_endpoint_button_pressed()


func _on_join_endpoint_button_pressed() -> void:
	if join_endpoint_input == null:
		return

	var endpoint = join_endpoint_input.text.strip_edges()
	if endpoint.empty():
		endpoint = brotatogether_options.last_join_endpoint

	if endpoint.empty():
		_append_system_message("Endpoint is empty")
		return

	join_endpoint_input.text = endpoint
	brotatogether_options.set_last_join_endpoint(endpoint)
	steam_connection.join_game_lobby(endpoint)


func _on_resume_snapshot_button_pressed() -> void:
	if not steam_connection.has_recovery_snapshot():
		_append_system_message("No recovery snapshot found")
		_update_resume_button_state()
		return

	if not steam_connection.resume_from_latest_snapshot():
		_append_system_message("Failed to restore snapshot")
		_update_resume_button_state()


func _on_reset_sessions_button_pressed() -> void:
	if steam_connection == null:
		return

	steam_connection.reset_saved_sessions()
	if join_endpoint_input != null:
		join_endpoint_input.text = ""
	_append_system_message("Session data reset. Start from clean state.")
	_on_refresh_lobbies_button_pressed()


func _on_refresh_lobbies_button_pressed() -> void:
	for child in lobbies_list.get_children():
		child.queue_free()
	shown_lobbies.clear()

	steam_connection.request_lobby_search()
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


