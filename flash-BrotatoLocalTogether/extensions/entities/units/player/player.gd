extends "res://entities/units/player/player.gd"

# Совместимый набор enum, чтобы корректно читать сетевые пакеты игрока.
enum EntityState {
	ENTITY_STATE_NETWORK_ID,
	ENTITY_STATE_X_POS,
	ENTITY_STATE_Y_POS,
	ENTITY_STATE_X_MOVE,
	ENTITY_STATE_Y_MOVE,
	ENTITY_STATE_CURRENT_HP,
	ENTITY_STATE_MAX_HP,
	ENTITY_STATE_SPRITE_SCALE,
	ENTITY_STATE_PLAYER_GOLD,
	ENTITY_STATE_PLAYER_CURRENT_XP,
	ENTITY_STATE_PLAYER_NEXT_LEVEL_XP,
	ENTITY_STATE_PLAYER_NUM_UPGRADES,
	ENTITY_STATE_PLAYER_WEAPONS,
	ENTITY_STATE_PLAYER_LEVEL,
}

enum WeaponState {
	WEAPON_STATE_X_POS,
	WEAPON_STATE_Y_POS,
	WEAPON_STATE_ROTATION,
	WEAPON_STATE_SPRITE_ROTATION,
	WEAPON_STATE_IS_SHOOTING,
}


func update_external_player_position(player_dict : Dictionary) -> void:
	if not (player_dict is Dictionary):
		return

	if player_dict.has(EntityState.ENTITY_STATE_X_POS) and player_dict.has(EntityState.ENTITY_STATE_Y_POS):
		position = Vector2(
			float(player_dict[EntityState.ENTITY_STATE_X_POS]),
			float(player_dict[EntityState.ENTITY_STATE_Y_POS])
		)

	var sprite_node = get("sprite")
	if sprite_node != null and is_instance_valid(sprite_node) and player_dict.has(EntityState.ENTITY_STATE_SPRITE_SCALE):
		sprite_node.scale.x = float(player_dict[EntityState.ENTITY_STATE_SPRITE_SCALE])

	var has_move = false
	var movement = Vector2.ZERO
	if player_dict.has(EntityState.ENTITY_STATE_X_MOVE):
		movement.x = float(player_dict[EntityState.ENTITY_STATE_X_MOVE])
		has_move = true
	if player_dict.has(EntityState.ENTITY_STATE_Y_MOVE):
		movement.y = float(player_dict[EntityState.ENTITY_STATE_Y_MOVE])
		has_move = true

	if has_move:
		set("_current_movement", movement)
		if has_method("update_animation"):
			update_animation(movement)


func update_client_player(player_dict : Dictionary, player_index : int) -> void:
	if not (player_dict is Dictionary):
		return
	if player_index < 0 or player_index >= RunData.players_data.size():
		return

	if player_dict.has(EntityState.ENTITY_STATE_PLAYER_CURRENT_XP) and player_dict.has(EntityState.ENTITY_STATE_PLAYER_NEXT_LEVEL_XP):
		var current_xp = int(player_dict[EntityState.ENTITY_STATE_PLAYER_CURRENT_XP])
		var next_level_xp = int(player_dict[EntityState.ENTITY_STATE_PLAYER_NEXT_LEVEL_XP])
		RunData.players_data[player_index].current_xp = current_xp
		RunData.emit_signal("xp_added", current_xp, next_level_xp, player_index)

	var current_stats = get("current_stats")
	var max_stats = get("max_stats")
	var current_hp = 0.0
	var max_hp = 0.0
	var should_send_hp_signal = false

	if current_stats != null:
		current_hp = float(current_stats.get("health"))
	if max_stats != null:
		max_hp = float(max_stats.get("health"))

	if player_dict.has(EntityState.ENTITY_STATE_CURRENT_HP):
		var next_hp = float(player_dict[EntityState.ENTITY_STATE_CURRENT_HP])
		if next_hp != current_hp:
			should_send_hp_signal = true
		current_hp = next_hp
		if current_stats != null:
			current_stats.set("health", current_hp)

	if player_dict.has(EntityState.ENTITY_STATE_MAX_HP):
		var next_max_hp = float(player_dict[EntityState.ENTITY_STATE_MAX_HP])
		if next_max_hp != max_hp:
			should_send_hp_signal = true
		max_hp = next_max_hp
		if max_stats != null:
			max_stats.set("health", max_hp)

	if should_send_hp_signal and has_signal("health_updated"):
		emit_signal("health_updated", self, current_hp, max_hp)

	if player_dict.has(EntityState.ENTITY_STATE_PLAYER_GOLD):
		RunData.players_data[player_index].gold = int(player_dict[EntityState.ENTITY_STATE_PLAYER_GOLD])
		RunData.emit_signal("gold_changed", RunData.players_data[player_index].gold, player_index)

	if player_dict.has(EntityState.ENTITY_STATE_PLAYER_LEVEL):
		RunData.players_data[player_index].current_level = int(player_dict[EntityState.ENTITY_STATE_PLAYER_LEVEL])

	var weapons_array = player_dict.get(EntityState.ENTITY_STATE_PLAYER_WEAPONS, [])
	if not (weapons_array is Array):
		return

	var current_weapons = get("current_weapons")
	if not (current_weapons is Array):
		return

	var limit = min(weapons_array.size(), current_weapons.size())
	for weapon_index in range(limit):
		var weapon_dict = weapons_array[weapon_index]
		if not (weapon_dict is Dictionary):
			continue

		var weapon = current_weapons[weapon_index]
		if weapon == null or not is_instance_valid(weapon):
			continue

		var weapon_sprite = weapon.get("sprite")
		if weapon_sprite != null and is_instance_valid(weapon_sprite):
			if weapon_dict.has(WeaponState.WEAPON_STATE_X_POS):
				weapon_sprite.position.x = float(weapon_dict[WeaponState.WEAPON_STATE_X_POS])
			if weapon_dict.has(WeaponState.WEAPON_STATE_Y_POS):
				weapon_sprite.position.y = float(weapon_dict[WeaponState.WEAPON_STATE_Y_POS])
			if weapon_dict.has(WeaponState.WEAPON_STATE_SPRITE_ROTATION):
				weapon_sprite.rotation = float(weapon_dict[WeaponState.WEAPON_STATE_SPRITE_ROTATION])

		if weapon_dict.has(WeaponState.WEAPON_STATE_ROTATION):
			weapon.rotation = float(weapon_dict[WeaponState.WEAPON_STATE_ROTATION])
		if weapon_dict.has(WeaponState.WEAPON_STATE_IS_SHOOTING):
			weapon.set("_is_shooting", bool(weapon_dict[WeaponState.WEAPON_STATE_IS_SHOOTING]))
		weapon.set("_current_cooldown", 9999)
