extends "res://ui/menus/global/focus_emulator.gd"

const DiagnosticsLogger = preload("res://mods-unpacked/flash-BrotatoLocalTogether/logging/diagnostics_logger.gd")

var global_focused_control
var steam_connection
var brotatogether_options


func _ready() -> void:
	_ready_base_safe()
	_resolve_singletons_if_needed()
	_diag("ready index=%s device=%s" % [str(player_index), str(_device)])
	if not is_inside_tree():
		return
	var viewport = get_viewport()
	if viewport != null and not viewport.is_connected("gui_focus_changed", self, "_on_focus_changed_multiplayer"):
		var _err = viewport.connect("gui_focus_changed", self, "_on_focus_changed_multiplayer")


func _exit_tree() -> void:
	if CoopService != null and CoopService.is_connected("connected_players_updated", self, "_on_connected_players_updated"):
		CoopService.disconnect("connected_players_updated", self, "_on_connected_players_updated")
		_diag("disconnect connected_players_updated")
	var viewport = get_viewport()
	if viewport != null and viewport.is_connected("gui_focus_changed", self, "_on_focus_changed"):
		viewport.disconnect("gui_focus_changed", self, "_on_focus_changed")
		_diag("disconnect gui_focus_changed(base)")
	if viewport != null and viewport.is_connected("gui_focus_changed", self, "_on_focus_changed_multiplayer"):
		viewport.disconnect("gui_focus_changed", self, "_on_focus_changed_multiplayer")
		_diag("disconnect gui_focus_changed(multiplayer)")


func _on_focus_changed_multiplayer(control:Control) -> void:
	if control != null:
		global_focused_control = control


# Have line edit eat inputs so that you can send messages
func _handle_input(event:InputEvent) -> bool:
	if not is_inside_tree():
		return false
	if _device >= 50:
		# Remote player slots не должны читать локальный InputMap
		# (иначе ошибки вида ui_right_101).
		return false
	_resolve_singletons_if_needed()

	var tree = get_tree()
	if tree == null or tree.current_scene == null:
		return false

	if tree.current_scene.name == "CoopShop" and brotatogether_options != null and brotatogether_options.in_multiplayer_game:
		if event is InputEventKey:
			if event.pressed:
				if steam_connection == null:
					return ._handle_input(event)
				var player_container = tree.current_scene._get_coop_player_container(steam_connection.get_my_index())
				if player_container != null:
					var carousel = player_container.get("carousel")
					if carousel != null:
						if event.scancode == KEY_R:
							carousel._on_ArrowRight_pressed()
						if event.scancode == KEY_L:
							carousel._on_ArrowLeft_pressed()
	
	if global_focused_control != null and is_instance_valid(global_focused_control) and global_focused_control is LineEdit:
		return false
	return ._handle_input(event)


func _get_focus_neighbour_for_event(event: InputEvent, target: Control)->GetFocusNeighbourForEventResult:
	if _device >= 50:
		return GetFocusNeighbourForEventResult.new()
	
	return ._get_focus_neighbour_for_event(event,target)


func _handle_popup_menu_input(event: InputEvent, popup: PopupMenu) -> bool:
	if _device >= 50:
		return false
	return ._handle_popup_menu_input(event, popup)


func _handle_hslider_input(event: InputEvent, slider: HSlider) -> bool:
	if _device >= 50:
		return false
	return ._handle_hslider_input(event, slider)


func _resolve_singletons_if_needed() -> void:
	if not is_inside_tree():
		return
	if brotatogether_options == null:
		brotatogether_options = get_node_or_null("/root/BrotogetherOptions")
	if steam_connection == null:
		steam_connection = get_node_or_null("/root/NetworkConnection")


func _ready_base_safe() -> void:
	_on_connected_players_updated(CoopService.connected_players)
	if not CoopService.is_connected("connected_players_updated", self, "_on_connected_players_updated"):
		var _connect_players = CoopService.connect("connected_players_updated", self, "_on_connected_players_updated")
		_diag("connect connected_players_updated")

	_focus_base_nodes.clear()
	for base in focus_base_data:
		var node = get_node_or_null(base.path)
		if node == null:
			printerr("Focus base not found: %s" % base.path)
			continue
		_focus_base_nodes.append(node)

	var viewport = get_viewport()
	if viewport != null and not viewport.is_connected("gui_focus_changed", self, "_on_focus_changed"):
		var _connect_focus = viewport.connect("gui_focus_changed", self, "_on_focus_changed")
		_diag("connect gui_focus_changed(base)")


func _diag(message: String) -> void:
	DiagnosticsLogger.log_with_options(brotatogether_options, "FocusEmulatorExt", message)
