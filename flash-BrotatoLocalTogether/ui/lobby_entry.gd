extends HBoxContainer

var lobby_id
var lobby_name

var network_connection

onready var lobby_name_label = $"%LobbyName"


func _ready():
	network_connection = $"/root/NetworkConnection"
	lobby_name_label.text = lobby_name


func _on_join_button_pressed():
	network_connection.join_game_lobby(String(lobby_id))
