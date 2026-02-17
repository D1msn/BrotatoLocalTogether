extends "res://ui/menus/ingame/coop_upgrades_ui_player_container.gd"

var network_connection
var brotatogether_options
var in_multiplayer_game = false


func _ready():
	network_connection = $"/root/NetworkConnection"
	brotatogether_options = $"/root/BrotogetherOptions"
	in_multiplayer_game = brotatogether_options.in_multiplayer_game


func _on_RerollButton_pressed() -> void:
	if in_multiplayer_game:
		if network_connection.is_host():
			._on_RerollButton_pressed()
		else:
			network_connection.send_main_scene_client_reroll_button_ressed()
	else:
		._on_RerollButton_pressed()


func _on_choose_button_pressed(upgrade: UpgradeData) -> void:
	if in_multiplayer_game:
		if network_connection.is_host():
			._on_choose_button_pressed(upgrade)
		else:
			var upgrade_dict = {
				"UPGRADE_ID" : upgrade.my_id
			}
			network_connection.send_main_scene_client_choose_upgrade_pressed(upgrade_dict)
	else:
		._on_choose_button_pressed(upgrade)


func _on_TakeButton_pressed():
	if in_multiplayer_game:
		if network_connection.is_host():
			._on_TakeButton_pressed()
		else:
			network_connection.send_main_scene_client_take_button_pressed()
	else:
		._on_TakeButton_pressed()


func _on_DiscardButton_pressed():
	if in_multiplayer_game:
		if network_connection.is_host():
			._on_DiscardButton_pressed()
		else:
			network_connection.send_main_scene_client_discard_button_pressed()
	else:
		._on_DiscardButton_pressed()
