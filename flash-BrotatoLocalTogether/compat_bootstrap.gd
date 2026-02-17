extends Reference

const LOG_NAME := "BrotatoLocalTogether:Compat"
const BASE_DIR := "brotato_local_together"
const CONFIG_PATH := "user://brotato_local_together/compat.cfg"
const CONFIG_SECTION := "bootstrap"
const DEFAULT_SAFE_BOOTSTRAP_ENABLED := true
const DEFAULT_EXTENSION_ROLLOUT_COUNT := -1
const LEGACY_EXTENSION_ROLLOUT_COUNT := 8
const CONFIG_KEY_ROLLOUT_MIGRATED := "rollout_migrated_to_full"

var safe_bootstrap_enabled := DEFAULT_SAFE_BOOTSTRAP_ENABLED
var extension_rollout_count := DEFAULT_EXTENSION_ROLLOUT_COUNT
var enabled_extension_groups: Array = []
var disabled_extension_groups: Array = []
var disabled_extension_paths: Array = []


func load_config(default_enabled_groups: Array) -> void:
	enabled_extension_groups = default_enabled_groups.duplicate()
	disabled_extension_groups = []
	disabled_extension_paths = []
	safe_bootstrap_enabled = DEFAULT_SAFE_BOOTSTRAP_ENABLED
	extension_rollout_count = DEFAULT_EXTENSION_ROLLOUT_COUNT

	var config := ConfigFile.new()
	var load_result = config.load(CONFIG_PATH)
	if load_result == OK:
		safe_bootstrap_enabled = bool(config.get_value(
			CONFIG_SECTION,
			"safe_bootstrap_enabled",
			DEFAULT_SAFE_BOOTSTRAP_ENABLED
		))
		extension_rollout_count = int(config.get_value(
			CONFIG_SECTION,
			"extension_rollout_count",
			DEFAULT_EXTENSION_ROLLOUT_COUNT
		))
		var rollout_migrated = bool(config.get_value(
			CONFIG_SECTION,
			CONFIG_KEY_ROLLOUT_MIGRATED,
			false
		))
		# Миграция старых конфигов: rollout=8 отсекал UI/singleton-extensions
		# и приводил к запуску базовых скриптов без наших safety-фиксов.
		if not rollout_migrated and extension_rollout_count == LEGACY_EXTENSION_ROLLOUT_COUNT:
			extension_rollout_count = DEFAULT_EXTENSION_ROLLOUT_COUNT
			config.set_value(CONFIG_SECTION, "extension_rollout_count", extension_rollout_count)
			config.set_value(CONFIG_SECTION, CONFIG_KEY_ROLLOUT_MIGRATED, true)
			var migrate_result = config.save(CONFIG_PATH)
			if migrate_result != OK:
				ModLoaderLog.warning(
					"Не удалось сохранить миграцию rollout в compat.cfg (код %s)." % str(migrate_result),
					LOG_NAME
				)

		var stored_enabled = config.get_value(CONFIG_SECTION, "enabled_extension_groups", default_enabled_groups)
		if stored_enabled is Array:
			enabled_extension_groups = stored_enabled.duplicate()

		var stored_disabled = config.get_value(CONFIG_SECTION, "disabled_extension_groups", [])
		if stored_disabled is Array:
			disabled_extension_groups = stored_disabled.duplicate()

		var stored_disabled_paths = config.get_value(CONFIG_SECTION, "disabled_extension_paths", [])
		if stored_disabled_paths is Array:
			disabled_extension_paths = stored_disabled_paths.duplicate()
		return

	# Создаем файл с дефолтами при первом запуске.
	_save_config(default_enabled_groups, [], [])


func add_forced_disabled_paths(paths: Array) -> void:
	for path in paths:
		var normalized_path := String(path).strip_edges()
		if normalized_path.empty():
			continue
		if disabled_extension_paths.has(normalized_path):
			continue
		disabled_extension_paths.push_back(normalized_path)


func remove_disabled_paths(paths: Array) -> void:
	for path in paths:
		var normalized_path := String(path).strip_edges()
		if normalized_path.empty():
			continue
		if disabled_extension_paths.has(normalized_path):
			disabled_extension_paths.erase(normalized_path)


func is_group_enabled(group_id: String) -> bool:
	if disabled_extension_groups.has(group_id):
		return false

	if not safe_bootstrap_enabled:
		return true

	return enabled_extension_groups.has(group_id)


func is_extension_enabled(child_path: String, extension_index: int) -> bool:
	if disabled_extension_paths.has(child_path):
		return false

	if not safe_bootstrap_enabled:
		return true

	if extension_rollout_count >= 0 and extension_index >= extension_rollout_count:
		return false

	return true


func save_runtime_report(
	enabled_groups: Array,
	disabled_reasons: Dictionary,
	enabled_extensions: Array,
	disabled_extensions: Array
) -> void:
	var disabled_report: Array = []
	for group_id in disabled_reasons.keys():
		disabled_report.push_back({
			"group_id": group_id,
			"reason": String(disabled_reasons[group_id]),
		})

	_save_config(enabled_extension_groups, enabled_groups, disabled_report, enabled_extensions, disabled_extensions)


func _save_config(
	config_enabled_groups: Array,
	last_enabled_groups: Array,
	last_disabled_groups: Array,
	last_enabled_extensions: Array = [],
	last_disabled_extensions: Array = []
) -> void:
	if not _ensure_base_dir():
		ModLoaderLog.warning("Не удалось создать директорию user://brotato_local_together для compat.cfg", LOG_NAME)
		return

	var config := ConfigFile.new()
	var _load_result = config.load(CONFIG_PATH)

	config.set_value(CONFIG_SECTION, "safe_bootstrap_enabled", safe_bootstrap_enabled)
	config.set_value(CONFIG_SECTION, "extension_rollout_count", extension_rollout_count)
	config.set_value(CONFIG_SECTION, "enabled_extension_groups", config_enabled_groups)
	config.set_value(CONFIG_SECTION, "disabled_extension_groups", disabled_extension_groups)
	config.set_value(CONFIG_SECTION, "disabled_extension_paths", disabled_extension_paths)
	config.set_value(CONFIG_SECTION, CONFIG_KEY_ROLLOUT_MIGRATED, true)
	config.set_value(CONFIG_SECTION, "last_enabled_groups", last_enabled_groups)
	config.set_value(CONFIG_SECTION, "last_disabled_groups", last_disabled_groups)
	config.set_value(CONFIG_SECTION, "last_enabled_extensions", last_enabled_extensions)
	config.set_value(CONFIG_SECTION, "last_disabled_extensions", last_disabled_extensions)
	config.set_value(CONFIG_SECTION, "last_boot_unix", OS.get_unix_time())

	var save_result = config.save(CONFIG_PATH)
	if save_result != OK:
		ModLoaderLog.warning("Не удалось сохранить compat.cfg (код %s)." % str(save_result), LOG_NAME)


func _ensure_base_dir() -> bool:
	var directory := Directory.new()
	if directory.open("user://") != OK:
		return false

	if not directory.dir_exists(BASE_DIR):
		if directory.make_dir(BASE_DIR) != OK:
			return false

	return true

