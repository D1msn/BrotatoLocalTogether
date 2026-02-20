extends Reference

const GROUP_CORE_MAIN := "core_main"
const GROUP_GAMEPLAY_ENTITIES := "gameplay_entities"
const GROUP_GAMEPLAY_GLOBAL := "gameplay_global"
const GROUP_GAMEPLAY_SINGLETONS := "gameplay_singletons"
const GROUP_UI_MAIN_MENU := "ui_main_menu"
const GROUP_UI_INGAME := "ui_ingame"
const GROUP_UI_RUN := "ui_run"
const GROUP_UI_SHOP := "ui_shop"


static func get_default_enabled_groups() -> Array:
	# По умолчанию все группы готовы к загрузке, но rollout ограничивает количество.
	return get_group_load_order().duplicate()


static func get_group_load_order() -> Array:
	return [
		GROUP_CORE_MAIN,
		GROUP_GAMEPLAY_ENTITIES,
		GROUP_GAMEPLAY_GLOBAL,
		GROUP_GAMEPLAY_SINGLETONS,
		GROUP_UI_MAIN_MENU,
		GROUP_UI_INGAME,
		GROUP_UI_RUN,
		GROUP_UI_SHOP,
	]


static func get_forced_disabled_groups() -> Array:
	# core_main включен: safe-core поведение настраивается внутри extensions/main.gd.
	return []


static func get_forced_disabled_extension_paths(ext_dir: String) -> Array:
	# turret extension на части сборок 1.1.14.1 вызывает hard-crash
	# до появления обычных логов; держим отключенным до отдельной адаптации.
	return [
		ext_dir + "entities/structures/turret/turret.gd",
	]


static func get_forced_reenabled_extension_paths(ext_dir: String) -> Array:
	# После стабилизации remote-device обработки возвращаем focus_emulator
	# в активный набор по умолчанию.
	return [
		ext_dir + "ui/menus/global/focus_emulator.gd",
	]


static func get_groups(ext_dir: String) -> Dictionary:
	return {
		GROUP_CORE_MAIN: [
			_make_entry(ext_dir + "main.gd", "res://main.gd"),
		],
		GROUP_GAMEPLAY_ENTITIES: [
			_make_entry(ext_dir + "entities/units/unit/unit.gd", "res://entities/units/unit/unit.gd"),
			_make_entry(ext_dir + "entities/units/player/player.gd", "res://entities/units/player/player.gd"),
			_make_entry(ext_dir + "entities/structures/turret/turret.gd", "res://entities/structures/turret/turret.gd"),
			_make_entry(ext_dir + "entities/entity.gd", "res://entities/entity.gd"),
			_make_entry(ext_dir + "entities/birth/entity_birth.gd", "res://entities/birth/entity_birth.gd"),
			_make_entry(
				ext_dir + "entities/units/movement_behaviors/player_movement_behavior.gd",
				"res://entities/units/movement_behaviors/player_movement_behavior.gd"
			),
		],
		GROUP_GAMEPLAY_GLOBAL: [
			_make_entry(ext_dir + "global/entity_spawner.gd", "res://global/entity_spawner.gd"),
			_make_entry(ext_dir + "items/global/item.gd", "res://items/global/item.gd"),
			_make_entry(ext_dir + "projectiles/player_explosion.gd", "res://projectiles/player_explosion.gd"),
		],
		GROUP_GAMEPLAY_SINGLETONS: [
			_make_entry(ext_dir + "singletons/coop_service.gd", "res://singletons/coop_service.gd"),
			_make_entry(ext_dir + "singletons/run_data.gd", "res://singletons/run_data.gd"),
			_make_entry(ext_dir + "singletons/sound_manager.gd", "res://singletons/sound_manager.gd"),
			_make_entry(ext_dir + "singletons/sound_manager_2d.gd", "res://singletons/sound_manager_2d.gd"),
			_make_entry(ext_dir + "singletons/utils.gd", "res://singletons/utils.gd"),
		],
		GROUP_UI_MAIN_MENU: [
			_make_entry(ext_dir + "ui/menus/pages/main_menu.gd", "res://ui/menus/pages/main_menu.gd"),
			_make_entry(ext_dir + "ui/menus/global/focus_emulator.gd", "res://ui/menus/global/focus_emulator.gd"),
		],
		GROUP_UI_INGAME: [
			_make_entry(
				ext_dir + "ui/menus/ingame/coop_upgrades_ui_player_container.gd",
				"res://ui/menus/ingame/coop_upgrades_ui_player_container.gd"
			),
			_make_entry(ext_dir + "ui/menus/ingame/pause_menu.gd", "res://ui/menus/ingame/pause_menu.gd"),
		],
		GROUP_UI_RUN: [
			_make_entry(ext_dir + "ui/menus/run/character_selection.gd", "res://ui/menus/run/character_selection.gd"),
			_make_entry(
				ext_dir + "ui/menus/run/difficulty_selection/difficulty_selection.gd",
				"res://ui/menus/run/difficulty_selection/difficulty_selection.gd"
			),
			_make_entry(ext_dir + "ui/menus/run/weapon_selection.gd", "res://ui/menus/run/weapon_selection.gd"),
		],
		GROUP_UI_SHOP: [
			_make_entry(ext_dir + "ui/menus/shop/coop_shop.gd", "res://ui/menus/shop/coop_shop.gd"),
			_make_entry(ext_dir + "ui/menus/shop/shop.gd", "res://ui/menus/shop/shop.gd"),
			_make_entry(ext_dir + "ui/menus/shop/shop_item.gd", "res://ui/menus/shop/shop_item.gd"),
			_make_entry(ext_dir + "ui/menus/shop/player_gear_container.gd", "res://ui/menus/shop/player_gear_container.gd"),
		],
	}


static func _make_entry(child_path: String, parent_path: String) -> Dictionary:
	return {
		"child_path": child_path,
		"parent_path": parent_path,
	}
