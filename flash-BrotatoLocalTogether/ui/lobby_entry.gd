extends HBoxContainer

var lobby_id
var lobby_name

var steam_connection

onready var lobby_name_label = $"%LobbyName"


func _ready():
	steam_connection = $"/root/NetworkConnection"
	lobby_name_label.text = lobby_name


func _on_join_button_pressed():
	steam_connection.join_game_lobby(String(lobby_id))
