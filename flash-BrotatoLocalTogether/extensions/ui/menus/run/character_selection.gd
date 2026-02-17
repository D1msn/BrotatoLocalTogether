extends "res://ui/menus/run/character_selection.gd"

const UsernameLabel = preload("res://mods-unpacked/flash-BrotatoLocalTogether/ui/username_label.tscn")

const MULTIPLAYER_CLIENT_PLAYER_TYPE = 10
const DIAG_DIR := "user://brotato_local_together"
const DIAG_LOG_PATH := DIAG_DIR + "/diagnostics.log"

var steam_connection
var brotatogether_options

var is_multiplayer_lobby = false
var _input_ready = false

# Mapped inventory item by item keys.  Used to reset focus based on external
# calls.
var inventory_by_string_key : Dictionary = {}

# Mapped Selections by item keys.  Kept independent of itnentory items to
# avoid complications around randoms, locked items, etc.
var selections_by_string_key : Dictionary = {}

var username_labels = []
var external_focus = false
var lobby_member_count_at_scene_init : int = -1


func _enter_tree() -> void:
	# Блокируем input callback до завершения полной инициализации lobby.
	set_process_input(false)


func _ready():
	steam_connection = get_node_or_null("/root/NetworkConnection")
	if steam_connection == null:
		_diag("ready abort: no /root/NetworkConnection")
		return
	_diag("ready start")
	_connect_steam_signal("player_focused_character", "_player_focused_character")
	_connect_steam_signal("player_selected_character", "_player_selected_character")
	_connect_steam_signal("character_lobby_update", "_lobby_characters_updated")
	_connect_steam_signal("request_character_lobby_update", "_character_lobby_update_requested")
	_connect_steam_signal("character_selection_complete", "_host_character_selection_complete")
	
	# Перезагрузка сцены на каждое событие лобби вызывала фриз/зацикливание.
	_connect_steam_signal("lobby_players_updated", "_on_lobby_players_updated")
	
	brotatogether_options = get_node_or_null("/root/BrotogetherOptions")
	if brotatogether_options == null:
		_diag("ready abort: no /root/BrotogetherOptions")
		_input_ready = true
		set_process_input(true)
		return
	is_multiplayer_lobby = brotatogether_options.joining_multiplayer_lobby
	_diag("ready lobby=%s current_mode=%s players=%s" % [
		str(is_multiplayer_lobby),
		str(current_mode),
		str(RunData.get_player_count()),
	])
	
	if is_multiplayer_lobby:
		inventory_by_string_key.clear()
		selections_by_string_key.clear()
		username_labels.clear()
		ProgressData.settings.coop_mode_toggled = true
		var need_coop_mode = current_mode != RunData.PlayMode.COOP
		if need_coop_mode:
			# initialize=true: избегаем промежуточного clear_coop_players() в базовом коде.
			_play_mode_init(RunData.PlayMode.COOP, true)

		_coop_button.hide()
		var run_options_top_panel = _run_options_panel.get_node("MarginContainer/VBoxContainer/HBoxContainer")
		var run_options_icon = run_options_top_panel.get_node_or_null("Icon")
		if run_options_icon != null:
			run_options_top_panel.remove_child(run_options_icon)
		
		var username_label_player_1 : Label = UsernameLabel.instance()
		$"MarginContainer/VBoxContainer/DescriptionContainer/HBoxContainer/Panel1/vboxContainer".add_child(username_label_player_1)
		$"MarginContainer/VBoxContainer/DescriptionContainer/HBoxContainer/Panel1/vboxContainer".move_child(username_label_player_1, 0)
		username_labels.push_back(username_label_player_1)
		
		var username_label_player_2 : Label = UsernameLabel.instance()
		$"MarginContainer/VBoxContainer/DescriptionContainer/HBoxContainer/Panel2/vboxContainer".add_child(username_label_player_2)
		$"MarginContainer/VBoxContainer/DescriptionContainer/HBoxContainer/Panel2/vboxContainer".move_child(username_label_player_2, 0)
		username_labels.push_back(username_label_player_2)
		
		var username_label_player_3 : Label = UsernameLabel.instance()
		$"MarginContainer/VBoxContainer/DescriptionContainer/HBoxContainer/Panel3/vboxContainer".add_child(username_label_player_3)
		$"MarginContainer/VBoxContainer/DescriptionContainer/HBoxContainer/Panel3/vboxContainer".move_child(username_label_player_3, 0)
		username_labels.push_back(username_label_player_3)
		
		var username_label_player_4 : Label = UsernameLabel.instance()
		$"MarginContainer/VBoxContainer/DescriptionContainer/HBoxContainer/Panel4/vboxContainer".add_child(username_label_player_4)
		$"MarginContainer/VBoxContainer/DescriptionContainer/HBoxContainer/Panel4/vboxContainer".move_child(username_label_player_4, 0)
		username_labels.push_back(username_label_player_4)
		
		_update_username_labels()
		lobby_member_count_at_scene_init = steam_connection.lobby_members.size()
		_sync_coop_players_with_lobby()
			
		for character_data in _get_all_possible_elements(0):
			selections_by_string_key[character_item_to_string(character_data)] = character_data
		
		# Find the random element in the inventory
		for character_data in _get_inventories()[0].get_children():
			if character_data.is_random:
				inventory_by_string_key[character_item_to_string(character_data)] = character_data
				selections_by_string_key[character_item_to_string(character_data)] = character_data
			else:
				inventory_by_string_key[character_item_to_string(character_data.item)] = character_data
	_input_ready = true
	set_process_input(true)
	_diag("ready end")


func _input(event: InputEvent) -> void:
	if not _input_ready:
		return
	var focus_owner = get_focus_owner()
	if RunData.is_coop_run and RunData.get_player_count() == 0 and focus_owner == null and event.is_action_pressed("ui_up"):
		_diag("input ui_up with zero players; schedule safe focus")
		call_deferred("_safe_focus_coop_button")


func _play_mode_init(mode: int, initialize: bool) -> void:
	var effective_initialize = initialize
	if is_multiplayer_lobby and not initialize and mode == current_mode:
		# Базовый CharacterSelection при mode==current_mode всё равно делает clear_coop_players(),
		# что даёт краткий player_count=0 и гонку вокруг deferred focus.
		effective_initialize = true
		_diag("play_mode_init adjusted: mode=%s initialize=false -> true" % str(mode))
	._play_mode_init(mode, effective_initialize)


func _safe_focus_coop_button() -> void:
	if not is_inside_tree():
		_diag("safe_focus_coop_button skipped: scene out of tree")
		return
	if _coop_button == null or not is_instance_valid(_coop_button):
		_diag("safe_focus_coop_button skipped: coop_button invalid")
		return
	if not _coop_button.is_inside_tree():
		_diag("safe_focus_coop_button skipped: coop_button out of tree")
		return
	_coop_button.grab_focus()
	_diag("safe_focus_coop_button done")


func _exit_tree() -> void:
	_disconnect_steam_signal("player_focused_character", "_player_focused_character")
	_disconnect_steam_signal("player_selected_character", "_player_selected_character")
	_disconnect_steam_signal("character_lobby_update", "_lobby_characters_updated")
	_disconnect_steam_signal("request_character_lobby_update", "_character_lobby_update_requested")
	_disconnect_steam_signal("character_selection_complete", "_host_character_selection_complete")
	_disconnect_steam_signal("lobby_players_updated", "_on_lobby_players_updated")
	._exit_tree()


func _connect_steam_signal(signal_name: String, method_name: String) -> void:
	if steam_connection == null:
		return
	if steam_connection.is_connected(signal_name, self, method_name):
		return
	var _connect_error = steam_connection.connect(signal_name, self, method_name)


func _disconnect_steam_signal(signal_name: String, method_name: String) -> void:
	if steam_connection == null:
		return
	if not steam_connection.is_connected(signal_name, self, method_name):
		return
	steam_connection.disconnect(signal_name, self, method_name)


func _on_lobby_players_updated() -> void:
	if not is_multiplayer_lobby:
		return
	if not is_inside_tree():
		return

	var lobby_member_count = steam_connection.lobby_members.size()
	if lobby_member_count_at_scene_init < 0:
		lobby_member_count_at_scene_init = lobby_member_count

	if lobby_member_count != lobby_member_count_at_scene_init:
		lobby_member_count_at_scene_init = lobby_member_count
		# Избегаем смены сцены: reload давал гонку deferred grab_focus и !is_inside_tree.
		_sync_coop_players_with_lobby()

	_update_username_labels()


func _sync_coop_players_with_lobby() -> void:
	set_process_input(false)
	var used_devices := {0: true}
	var local_added := false
	var target_connected_players: Array = []

	for member_index in range(steam_connection.lobby_members.size()):
		var member_id = steam_connection.lobby_members[member_index]
		if member_id == steam_connection.steam_id:
			target_connected_players.push_back([0, MULTIPLAYER_CLIENT_PLAYER_TYPE])
			local_added = true
			_diag("add_player member=%s device=0 local=true" % str(member_index))
		else:
			var remote_device = _allocate_remote_device(used_devices)
			target_connected_players.push_back([remote_device, MULTIPLAYER_CLIENT_PLAYER_TYPE])
			_diag("add_player member=%s device=%s local=false" % [str(member_index), str(remote_device)])

	if not local_added:
		target_connected_players.push_back([0, MULTIPLAYER_CLIENT_PLAYER_TYPE])
		_diag("add_player local fallback device=0")

	_apply_connected_players(target_connected_players)

	if _input_ready:
		set_process_input(true)


func _apply_connected_players(target_connected_players: Array) -> void:
	if _connected_players_equal(CoopService.connected_players, target_connected_players):
		_diag("sync_players skipped: connected_players unchanged")
		return

	# Применяем одним обновлением, чтобы не провоцировать промежуточный player_count=0.
	CoopService.connected_players = target_connected_players.duplicate(true)
	CoopService.emit_signal("connected_players_updated", CoopService.connected_players)
	_diag("sync_players applied: count=%s" % str(CoopService.connected_players.size()))


func _connected_players_equal(current_players: Array, target_players: Array) -> bool:
	return to_json(current_players) == to_json(target_players)


func _update_username_labels() -> void:
	for index in username_labels.size():
		if index < steam_connection.lobby_member_names.size():
			username_labels[index].text = String(steam_connection.lobby_member_names[index])
		else:
			username_labels[index].text = ""


func _on_element_focused(element:InventoryElement, inventory_player_index:int, _displayPanelData: bool = true) -> void:
	if is_multiplayer_lobby and RunData.is_coop_run:
		var emitted_player_index = FocusEmulatorSignal.get_player_index(element)
		if emitted_player_index < 0 and inventory_player_index >= 0:
			# В сетевом лобби события фокуса иногда приходят вне FocusEmulatorSignal.
			# Подставляем ожидаемый control/index, чтобы базовый код не падал.
			FocusEmulatorSignal.set_expected_control(element, inventory_player_index)
	._on_element_focused(element, inventory_player_index)
	
	if is_multiplayer_lobby:
		var element_string = ""
		if element.item != null:
			element_string = element.item.name
		elif element.is_random:
			element_string = "RANDOM"
		if not external_focus:
			steam_connection.character_focused(element_string)
		else:
			external_focus = false


func character_item_to_string(item : Resource) -> String:
	if item == null:
		return "RANDOM"
	return item.name


func _player_focused_character(player_index : int , character : String) -> void:
	var selected_item = null
	var focused_element = null
	
	if selections_by_string_key.has(character):
		selected_item = selections_by_string_key[character]
		
	if inventory_by_string_key.has(character):
		focused_element = inventory_by_string_key[character]
		
	_clear_selected_element(player_index)
	_player_characters[player_index] = selected_item
	if player_index < RunData.get_player_count() and player_index != steam_connection.get_my_index():
		if focused_element != null:
			if Utils.get_focus_emulator(player_index).focused_control != focused_element:
				external_focus = true
				Utils.get_focus_emulator(player_index).focused_control = focused_element
	
	var panel = _get_panels()[player_index]
	
	if panel.visible:
		if selected_item != null:
			if character == "RANDOM":
				panel.set_custom_data("RANDOM", selected_item.get_inventory_icon())
			else:
				panel.set_data(selected_item, player_index)


func _player_selected_character(player_index : int) -> void:
	_set_selected_element(player_index)


func reload_scene() -> void:
	if not is_inside_tree():
		return
	var tree = get_tree()
	if tree == null:
		return
	$"/root/BrotogetherOptions".joining_multiplayer_lobby = true
	var _error = tree.change_scene(MenuData.character_selection_scene)


func _lobby_characters_updated(player_characters : Array, has_player_selected : Array) -> void:
	for player_index in RunData.get_player_count():
		if player_characters[player_index] != null:
			_player_focused_character(player_index, player_characters[player_index])
	
	var all_selected = true
	for player_index in RunData.get_player_count():
		if has_player_selected[player_index]:
			_set_selected_element(player_index)
		else:
			all_selected = false
			_clear_selected_element(player_index)
	
	if all_selected and steam_connection.is_host():
		_selections_completed_timer.start()


func _set_selected_element(player_index:int) -> void:
	if _has_player_selected[player_index]:
		return
	
	._set_selected_element(player_index)
	
	# В локальном лобби с одним участником (только host) базовая логика coop
	# не завершает выбор автоматически. Для ручной проверки и solo-host
	# режима продолжаем ран сразу.
	if is_multiplayer_lobby and steam_connection.is_host() and steam_connection.lobby_members.size() <= 1:
		_on_selections_completed()
		return

	if steam_connection.get_lobby_index_for_player(steam_connection.steam_id) == player_index:
		steam_connection.character_selected()


func _character_lobby_update_requested() -> void:
	var currently_focused_characters = []
	for panel in _get_panels():
		var selected_item = panel.item_data
		if selected_item == null:
			currently_focused_characters.push_back("RANDOM")
		else:
			currently_focused_characters.push_back(character_item_to_string(selected_item))
	
	steam_connection.send_character_lobby_update(currently_focused_characters, _has_player_selected)


func _on_selections_completed() -> void:
	if is_multiplayer_lobby:
		if not steam_connection.is_host():
			return
	else:
		._on_selections_completed()
		return
	
	var currently_focused_characters = []
	# Sad dupe of inner logic to make things simpler
	for player_index in RunData.get_player_count():
		var chosen_item = _get_panels()[player_index]
		
		var character = _player_characters[player_index]
		if chosen_item.item_data == null:
			var available_elements: = []
			for element in ItemService.characters:
				if not element.is_locked:
					available_elements.push_back(element)
			character = Utils.get_rand_element(available_elements)
			_player_characters[player_index] = character
		
		RunData.add_character(character, player_index)
		currently_focused_characters.push_back(character_item_to_string(character))
	
	steam_connection.send_character_selection_completed(RunData.some_player_has_weapon_slots(), currently_focused_characters)
	if RunData.some_player_has_weapon_slots():
		_change_scene(MenuData.weapon_selection_scene)
	else:
		_change_scene(MenuData.difficulty_selection_scene)
	

func _host_character_selection_complete(some_player_has_weapon_slots : bool, selected_characters : Array) -> void:
	# Sad dupe of inner logic to make things simpler
	for player_index in selected_characters.size():
		if selected_characters[player_index] != null:
			_player_focused_character(player_index, selected_characters[player_index])
	
	for player_index in RunData.get_player_count():
		var character = _player_characters[player_index]
		RunData.add_character(character, player_index)
	
	if some_player_has_weapon_slots:
		_change_scene(MenuData.weapon_selection_scene)
	else:
		_change_scene(MenuData.difficulty_selection_scene)


func _allocate_remote_device(used_devices: Dictionary) -> int:
	for candidate in range(1, CoopService.REMAP_END):
		if not used_devices.has(candidate):
			used_devices[candidate] = true
			return candidate
	# Fallback на валидный action-суффикс, даже если устройств больше ожидаемого.
	return 1


func _on_CoopButton_focus_entered():
	# В сетевом лобби возможен фокус без FocusEmulatorSignal метаданных.
	# Безопасно деградируем до игрока 0 и избегаем push_error в базовом скрипте.
	if _coop_button == null or not is_instance_valid(_coop_button):
		return
	var player_index = FocusEmulatorSignal.get_player_index(_coop_button)
	if player_index < 0:
		player_index = 0
	if player_index != 0:
		return
	if player_index >= _latest_focused_element.size():
		return
	__restore_player0_element = _latest_focused_element[player_index]


func _diag(message: String) -> void:
	if brotatogether_options != null:
		var enabled_value = brotatogether_options.get("diagnostics_log_enabled")
		if typeof(enabled_value) == TYPE_BOOL and not enabled_value:
			return

	var dir := Directory.new()
	if dir.open("user://") != OK:
		return
	if not dir.dir_exists("brotato_local_together"):
		var _make_result = dir.make_dir("brotato_local_together")

	var dt = OS.get_datetime()
	var ts = "%04d-%02d-%02d %02d:%02d:%02d" % [
		int(dt.year),
		int(dt.month),
		int(dt.day),
		int(dt.hour),
		int(dt.minute),
		int(dt.second),
	]
	var line = "[%s] CharacterSelectionExt: %s" % [ts, message]

	var file := File.new()
	var open_result = file.open(DIAG_LOG_PATH, File.READ_WRITE)
	if open_result != OK:
		open_result = file.open(DIAG_LOG_PATH, File.WRITE)
		if open_result != OK:
			return
		print("BrotatoLocalTogether diagnostics path: " + ProjectSettings.globalize_path(DIAG_LOG_PATH))
		file.store_line(line)
		file.close()
		return

	file.seek_end()
	file.store_line(line)
	file.close()


