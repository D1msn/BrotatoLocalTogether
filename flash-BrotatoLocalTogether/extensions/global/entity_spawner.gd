extends "res://global/entity_spawner.gd"

var network_connection
var brotatogether_options


func _ready():
	network_connection = $"/root/NetworkConnection"
	brotatogether_options = $"/root/BrotogetherOptions"


func spawn(queue_from: Array, player_index: = - 1) -> void:
	if not brotatogether_options.in_multiplayer_game:
		.spawn(queue_from, player_index)
		return
	
	if not network_connection.is_host():
		queue_from.pop_back()
		return
	
	.spawn(queue_from, player_index)
