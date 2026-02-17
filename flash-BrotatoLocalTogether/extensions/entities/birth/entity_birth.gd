extends "res://entities/birth/entity_birth.gd"

var network_connection
var brotatogether_options
var in_multiplayer_game = false
var network_id = 0
var is_host = false

func _ready():
	network_connection = $"/root/NetworkConnection"
	brotatogether_options = $"/root/BrotogetherOptions"
	in_multiplayer_game = brotatogether_options.in_multiplayer_game
	
	if in_multiplayer_game:
		is_host = network_connection.is_host()
		network_id = brotatogether_options.current_network_id
		brotatogether_options.current_network_id = brotatogether_options.current_network_id + 1
