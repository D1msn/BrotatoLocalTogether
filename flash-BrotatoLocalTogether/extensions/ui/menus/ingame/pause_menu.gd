extends "res://ui/menus/ingame/pause_menu.gd"

const SignalUtils = preload("res://mods-unpacked/flash-BrotatoLocalTogether/signal_utils.gd")

var steam_connection
var brotatogether_options

var is_multiplayer_lobby = false


# Called when the node enters the scene tree for the first time.
func _ready():
	steam_connection = $"/root/NetworkConnection"
	brotatogether_options = $"/root/BrotogetherOptions"


func on_game_lost_focus()->void :
	if steam_connection.game_lobby_id > 0:
		return
	.on_game_lost_focus()


func _connect_network_signal(signal_name: String, method_name: String) -> void:
	if steam_connection == null:
		return
	var _connect_error = SignalUtils.safe_connect(steam_connection, signal_name, self, method_name)


func _disconnect_network_signal(signal_name: String, method_name: String) -> void:
	if steam_connection == null:
		return
	SignalUtils.safe_disconnect(steam_connection, signal_name, self, method_name)
