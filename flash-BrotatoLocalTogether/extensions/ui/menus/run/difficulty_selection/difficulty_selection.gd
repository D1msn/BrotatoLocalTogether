extends "res://ui/menus/run/difficulty_selection/difficulty_selection.gd"

var steam_connection
var brotatogether_options
var is_multiplayer_lobby = false

var inventory_by_string_key : Dictionary
var selection_by_string_key : Dictionary


func _ready():
	steam_connection = $"/root/NetworkConnection"
	_connect_network_signal("difficulty_focused", "_difficulty_focused")
	_connect_network_signal("difficulty_selected", "_difficulty_selected")
	
	brotatogether_options = $"/root/BrotogetherOptions"
	is_multiplayer_lobby = brotatogether_options.joining_multiplayer_lobby
	
	if is_multiplayer_lobby:
		brotatogether_options.joining_multiplayer_lobby = false
		brotatogether_options.in_multiplayer_game = true
		
		for difficulty_data in ItemService.difficulties:
			selection_by_string_key[difficulty_data.value] = difficulty_data
		
		for inventory_item in _get_inventories()[0].get_children():
			inventory_by_string_key[inventory_item.item.value] = inventory_item


func _exit_tree() -> void:
	_disconnect_network_signal("difficulty_focused", "_difficulty_focused")
	_disconnect_network_signal("difficulty_selected", "_difficulty_selected")


func _on_element_focused(element:InventoryElement, inventory_player_index:int, _displayPanelData: bool = true) -> void:
	# Disregard difficulty updates from clients
	if is_multiplayer_lobby:
		if not steam_connection.is_host():
			return
	
	._on_element_focused(element, inventory_player_index)
	
	if is_multiplayer_lobby:
		steam_connection.difficulty_focused()


func _on_element_pressed(element: InventoryElement, _inventory_player_index: int) -> void:
	# Disregard difficulty updates from clients
	if is_multiplayer_lobby:
		if not steam_connection.is_host():
			return
		if not _apply_host_difficulty_selection(element):
			return
		steam_connection.difficulty_pressed()
		_request_host_scene_transition(MenuData.game_scene)
		return

	._on_element_pressed(element, _inventory_player_index)


func _difficulty_selected(difficutly : int) -> void:
	if is_multiplayer_lobby:
		RunData.current_difficulty = difficutly
		return

	if not _can_use_tree():
		return
	var tree = get_tree()
	if tree == null:
		return
	var _error = tree.change_scene(MenuData.game_scene)


func _apply_host_difficulty_selection(element: InventoryElement) -> bool:
	if difficulty_selected:
		return false
	if element == null or element.is_special:
		return false

	difficulty_selected = true
	RunData.current_difficulty = element.item.value
	RunData.reset_elites_spawn()
	RunData.init_elites_spawn()
	RunData.enabled_dlcs = ProgressData.get_active_dlc_ids()
	ProgressData.save()

	for effect in element.item.effects:
		effect.apply(0)

	for player_index in range(RunData.get_player_count()):
		var player_run_data = RunData.players_data[player_index]
		player_run_data.uses_ban = RunData.is_ban_mode_active
		player_run_data.remaining_ban_token = RunData.BAN_MAX_TOKEN

	RunData.init_bosses_spawn()
	RunData.current_run_accessibility_settings = ProgressData.settings.enemy_scaling.duplicate()
	ProgressData.load_status = LoadStatus.SAVE_OK
	ProgressData.increment_stat("run_started")
	ProgressData.data["chal_hourglass_quit_wave"] = false
	return true


func _request_host_scene_transition(target_scene: String) -> void:
	var normalized_target = String(target_scene).strip_edges()
	if normalized_target.empty():
		return

	if not is_multiplayer_lobby:
		var tree = get_tree()
		if tree != null:
			var _error = tree.change_scene(normalized_target)
		return
	if steam_connection == null:
		var fallback_tree = get_tree()
		if fallback_tree != null:
			var _fallback_error = fallback_tree.change_scene(normalized_target)
		return
	if not steam_connection.is_host():
		return
	if steam_connection.has_method("start_scene_transition"):
		var started = bool(steam_connection.start_scene_transition(normalized_target))
		if started:
			return

	var tree = get_tree()
	if tree != null:
		var _error = tree.change_scene(normalized_target)


func _difficulty_focused(difficutly : int) -> void:
	if not is_inside_tree():
		return
	
	# Hosts don't respect update calls
	if is_multiplayer_lobby:
		if steam_connection.is_host():
			return
	
	var selected_item = null
	if selection_by_string_key.has(difficutly):
		selected_item = selection_by_string_key[difficutly]
		
	Utils.get_focus_emulator(0).focused_control = inventory_by_string_key[difficutly]
		
	if selected_item != null:
		_get_panels()[0].visible = true
		_get_panels()[0].set_data(selected_item, 0)


func _connect_network_signal(signal_name: String, method_name: String) -> void:
	if steam_connection == null:
		return
	if steam_connection.is_connected(signal_name, self, method_name):
		return
	var _connect_error = steam_connection.connect(signal_name, self, method_name)


func _disconnect_network_signal(signal_name: String, method_name: String) -> void:
	if steam_connection == null:
		return
	if not steam_connection.is_connected(signal_name, self, method_name):
		return
	steam_connection.disconnect(signal_name, self, method_name)


func _can_use_tree() -> bool:
	if not is_inside_tree():
		return false
	return get_tree() != null
