extends Node

const LanConnection = preload("res://mods-unpacked/flash-BrotatoLocalTogether/lan_connection.gd")
const LanOptions = preload("res://mods-unpacked/flash-BrotatoLocalTogether/lan_options.gd")
const CompatBootstrap = preload("res://mods-unpacked/flash-BrotatoLocalTogether/compat_bootstrap.gd")
const ExtensionRegistry = preload("res://mods-unpacked/flash-BrotatoLocalTogether/extension_registry.gd")

const LOG_NAME := "BrotatoLocalTogether:Bootstrap"

const MOD_DIR = "flash-BrotatoLocalTogether/"

var dir = ""
var ext_dir = ""
var trans_dir = ""
var compat_bootstrap = null

func _init():
	dir = ModLoaderMod.get_unpacked_dir() + MOD_DIR
	ext_dir = dir + "extensions/"
	trans_dir = dir + "translations/"
	_initialize_safe_bootstrap()
	_install_extensions_with_safe_bootstrap()


func _ready():
	var lan_connection = LanConnection.new()
	# Оставляем старое имя ноды для совместимости с существующими extension-скриптами.
	lan_connection.set_name("SteamConnection")
	$"/root".call_deferred("add_child", lan_connection)
	
	var options_node = LanOptions.new()
	# Оставляем старое имя ноды для совместимости с существующими extension-скриптами.
	options_node.set_name("BrotogetherOptions")
	$"/root".call_deferred("add_child", options_node)


func _initialize_safe_bootstrap() -> void:
	compat_bootstrap = CompatBootstrap.new()
	compat_bootstrap.load_config(ExtensionRegistry.get_default_enabled_groups())
	compat_bootstrap.add_forced_disabled_paths(ExtensionRegistry.get_forced_disabled_extension_paths(ext_dir))
	ModLoaderLog.info(
		(
			"BrotatoLocalTogether safe-bootstrap активен: %s, rollout_count=%s, группы по умолчанию: %s"
			% [
				str(compat_bootstrap.safe_bootstrap_enabled),
				str(compat_bootstrap.extension_rollout_count),
				str(compat_bootstrap.enabled_extension_groups),
			]
		),
		LOG_NAME
	)


func _install_extensions_with_safe_bootstrap() -> void:
	var groups: Dictionary = ExtensionRegistry.get_groups(ext_dir)
	var load_order: Array = ExtensionRegistry.get_group_load_order()
	var forced_disabled_groups: Array = ExtensionRegistry.get_forced_disabled_groups()
	var enabled_groups: Array = []
	var disabled_reasons: Dictionary = {}
	var enabled_extensions: Array = []
	var disabled_extensions: Array = []
	var extension_index := 0

	for group_id in load_order:
		if forced_disabled_groups.has(group_id):
			disabled_reasons[group_id] = "forced_disabled_by_registry"
			ModLoaderLog.warning(
				"BrotatoLocalTogether safe-bootstrap: группа \"%s\" принудительно отключена для стабильности."
				% group_id,
				LOG_NAME
			)
			continue

		if not groups.has(group_id):
			disabled_reasons[group_id] = "group_not_declared"
			ModLoaderLog.warning("BrotatoLocalTogether safe-bootstrap: группа \"%s\" не объявлена." % group_id, LOG_NAME)
			continue

		if not compat_bootstrap.is_group_enabled(group_id):
			disabled_reasons[group_id] = "disabled_by_config"
			ModLoaderLog.info("BrotatoLocalTogether safe-bootstrap: группа \"%s\" отключена в конфиге." % group_id, LOG_NAME)
			continue

		var install_result := _install_group(
			group_id,
			groups[group_id],
			extension_index,
			enabled_extensions,
			disabled_extensions
		)
		extension_index = int(install_result.get("next_extension_index", extension_index))

		var install_error := String(install_result.get("error", ""))
		if install_error.empty():
			enabled_groups.push_back(group_id)
			continue

		disabled_reasons[group_id] = install_error
		ModLoaderLog.warning(
			"BrotatoLocalTogether safe-bootstrap: группа \"%s\" отключена (%s)." % [group_id, install_error],
			LOG_NAME
		)

	compat_bootstrap.save_runtime_report(
		enabled_groups,
		disabled_reasons,
		enabled_extensions,
		disabled_extensions
	)
	ModLoaderLog.info(
		(
			"BrotatoLocalTogether safe-bootstrap итог: enabled_groups=%s disabled_groups=%s enabled_extensions=%s disabled_extensions=%s"
			% [
				str(enabled_groups),
				str(disabled_reasons.keys()),
				str(enabled_extensions),
				str(disabled_extensions),
			]
		),
		LOG_NAME
	)


func _install_group(
	group_id: String,
	entries: Array,
	start_index: int,
	enabled_extensions: Array,
	disabled_extensions: Array
) -> Dictionary:
	var extension_index := start_index
	var installed_in_group := 0

	for entry in entries:
		if not (entry is Dictionary):
			return {
				"error": "invalid_entry",
				"next_extension_index": extension_index,
			}

		var child_path := String(entry.get("child_path", ""))
		var parent_path := String(entry.get("parent_path", ""))
		var extension_label := "%s#%s:%s" % [group_id, str(extension_index), child_path]

		if child_path.empty() or parent_path.empty():
			disabled_extensions.push_back("%s (empty_path)" % extension_label)
			return {
				"error": "empty_path",
				"next_extension_index": extension_index + 1,
			}

		if not compat_bootstrap.is_extension_enabled(child_path, extension_index):
			disabled_extensions.push_back("%s (disabled_by_rollout_config_or_forced_path)" % extension_label)
			extension_index += 1
			continue

		if not ResourceLoader.exists(child_path):
			disabled_extensions.push_back("%s (missing_child)" % extension_label)
			return {
				"error": "missing_child:%s" % child_path,
				"next_extension_index": extension_index + 1,
			}
		if not ResourceLoader.exists(parent_path):
			disabled_extensions.push_back("%s (missing_parent)" % extension_label)
			return {
				"error": "missing_parent:%s" % parent_path,
				"next_extension_index": extension_index + 1,
			}

		var child_script = load(child_path)
		if child_script == null:
			disabled_extensions.push_back("%s (failed_to_load_child)" % extension_label)
			return {
				"error": "failed_to_load_child:%s" % child_path,
				"next_extension_index": extension_index + 1,
			}

		var base_script = child_script.get_base_script()
		if base_script == null:
			disabled_extensions.push_back("%s (missing_base_script)" % extension_label)
			return {
				"error": "missing_base_script:%s" % child_path,
				"next_extension_index": extension_index + 1,
			}
		if base_script.resource_path != parent_path:
			disabled_extensions.push_back("%s (base_mismatch)" % extension_label)
			return {
				"error": "base_mismatch:%s->%s" % [child_path, base_script.resource_path],
				"next_extension_index": extension_index + 1,
			}

		ModLoaderMod.install_script_extension(child_path)
		enabled_extensions.push_back(extension_label)
		installed_in_group += 1
		ModLoaderLog.info(
			"BrotatoLocalTogether safe-bootstrap: подключено расширение %s (группа %s)."
			% [child_path, group_id],
			LOG_NAME
		)
		extension_index += 1

	if installed_in_group > 0:
		return {
			"error": "",
			"next_extension_index": extension_index,
		}

	return {
		"error": "no_extensions_installed",
		"next_extension_index": extension_index,
	}


