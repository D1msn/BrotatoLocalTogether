extends "res://entities/units/movement_behaviors/player_movement_behavior.gd"

var _steam_connection = null
var _brotatogether_options = null

func get_movement()->Vector2:
	if _is_remote_network_player():
		return get_parent()._current_movement
	
	return .get_movement()


func _is_remote_network_player() -> bool:
	# Старый режим remote-устройств (100+) оставляем как fallback.
	if device >= 50:
		return true

	if not is_inside_tree():
		return false

	if _brotatogether_options == null:
		_brotatogether_options = get_node_or_null("/root/BrotogetherOptions")
	if _steam_connection == null:
		_steam_connection = get_node_or_null("/root/NetworkConnection")

	if _brotatogether_options == null or _steam_connection == null:
		return false
	if not bool(_brotatogether_options.get("in_multiplayer_game")):
		return false
	if not _steam_connection.has_method("get_my_index"):
		return false

	var my_index = int(_steam_connection.get_my_index())
	if my_index < 0:
		return false

	var player = get_parent()
	if player == null:
		return false
	var player_index_value = player.get("player_index")
	if typeof(player_index_value) != TYPE_INT:
		return false

	return int(player_index_value) != my_index
