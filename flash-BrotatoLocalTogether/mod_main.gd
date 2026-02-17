extends Node

const LanConnection = preload("res://mods-unpacked/flash-BrotatoLocalTogether/lan_connection.gd")
const LanOptions = preload("res://mods-unpacked/flash-BrotatoLocalTogether/lan_options.gd")
const CompatBootstrap = preload("res://mods-unpacked/flash-BrotatoLocalTogether/compat_bootstrap.gd")
const ExtensionRegistry = preload("res://mods-unpacked/flash-BrotatoLocalTogether/extension_registry.gd")

const LOG_NAME := "BrotatoLocalTogether:Bootstrap"

const MOD_DIR = "flash-BrotatoLocalTogether/"
const CONNECTION_NODE_NAME := "NetworkConnection"
const OPTIONS_NODE_NAME := "BrotogetherOptions"
const TRACE_DIR := "brotato_local_together"
const TRACE_PATH := "user://brotato_local_together/bootstrap_trace.log"

var dir = ""
var ext_dir = ""
var trans_dir = ""
var compat_bootstrap = null

func _init():
	_reset_bootstrap_trace()
	_append_bootstrap_trace("bootstrap init started")
	dir = ModLoaderMod.get_unpacked_dir() + MOD_DIR
	ext_dir = dir + "extensions/"
	trans_dir = dir + "translations/"
	_append_bootstrap_trace("paths resolved: ext_dir=%s" % ext_dir)
	_initialize_safe_bootstrap()
	_install_extensions_with_safe_bootstrap()
	_append_bootstrap_trace("bootstrap init finished")


func _ready():
	_append_bootstrap_trace("_ready start")
	_ensure_root_node(CONNECTION_NODE_NAME, LanConnection)
	_ensure_root_node(OPTIONS_NODE_NAME, LanOptions)
	_append_bootstrap_trace("_ready end")


func _ensure_root_node(node_name: String, script_resource) -> void:
	if not is_inside_tree():
		_append_bootstrap_trace("ensure_root_node failed (outside tree): %s" % node_name)
		ModLoaderLog.warning(
			"BrotatoLocalTogether bootstrap: попытка создать %s вне scene tree." % node_name,
			LOG_NAME
		)
		return

	var root = get_tree().root
	if root == null:
		_append_bootstrap_trace("ensure_root_node failed (root null): %s" % node_name)
		ModLoaderLog.warning(
			"BrotatoLocalTogether bootstrap: root недоступен, не удалось создать %s." % node_name,
			LOG_NAME
		)
		return

	if root.get_node_or_null(node_name) != null:
		_append_bootstrap_trace("ensure_root_node skipped (already exists): %s" % node_name)
		ModLoaderLog.info(
			"BrotatoLocalTogether bootstrap: нода %s уже существует." % node_name,
			LOG_NAME
		)
		return

	var instance = script_resource.new()
	if instance == null:
		_append_bootstrap_trace("ensure_root_node failed (instance null): %s" % node_name)
		ModLoaderLog.warning(
			"BrotatoLocalTogether bootstrap: не удалось создать инстанс для %s." % node_name,
			LOG_NAME
		)
		return

	instance.set_name(node_name)
	root.call_deferred("add_child", instance)
	_append_bootstrap_trace("ensure_root_node added: %s" % node_name)
	ModLoaderLog.info(
		"BrotatoLocalTogether bootstrap: добавлена нода /root/%s." % node_name,
		LOG_NAME
	)


func _initialize_safe_bootstrap() -> void:
	compat_bootstrap = CompatBootstrap.new()
	compat_bootstrap.load_config(ExtensionRegistry.get_default_enabled_groups())
	compat_bootstrap.add_forced_disabled_paths(ExtensionRegistry.get_forced_disabled_extension_paths(ext_dir))
	_append_bootstrap_trace(
		"safe_bootstrap config loaded: enabled=%s rollout=%s"
		% [str(compat_bootstrap.safe_bootstrap_enabled), str(compat_bootstrap.extension_rollout_count)]
	)
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
		_append_bootstrap_trace("group start: %s" % group_id)
		if forced_disabled_groups.has(group_id):
			disabled_reasons[group_id] = "forced_disabled_by_registry"
			_append_bootstrap_trace("group forced disabled: %s" % group_id)
			ModLoaderLog.warning(
				"BrotatoLocalTogether safe-bootstrap: группа \"%s\" принудительно отключена для стабильности."
				% group_id,
				LOG_NAME
			)
			continue

		if not groups.has(group_id):
			disabled_reasons[group_id] = "group_not_declared"
			_append_bootstrap_trace("group missing declaration: %s" % group_id)
			ModLoaderLog.warning("BrotatoLocalTogether safe-bootstrap: группа \"%s\" не объявлена." % group_id, LOG_NAME)
			continue

		if not compat_bootstrap.is_group_enabled(group_id):
			disabled_reasons[group_id] = "disabled_by_config"
			_append_bootstrap_trace("group disabled by config: %s" % group_id)
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
			_append_bootstrap_trace("group installed: %s" % group_id)
			continue

		disabled_reasons[group_id] = install_error
		_append_bootstrap_trace("group disabled by error: %s (%s)" % [group_id, install_error])
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
	_append_bootstrap_trace("safe_bootstrap finished")


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
		_append_bootstrap_trace("extension check: %s" % extension_label)

		if child_path.empty() or parent_path.empty():
			disabled_extensions.push_back("%s (empty_path)" % extension_label)
			return {
				"error": "empty_path",
				"next_extension_index": extension_index + 1,
			}

		if not compat_bootstrap.is_extension_enabled(child_path, extension_index):
			_append_bootstrap_trace("extension skipped by config/forced path: %s" % extension_label)
			disabled_extensions.push_back("%s (disabled_by_rollout_config_or_forced_path)" % extension_label)
			extension_index += 1
			continue

		if not ResourceLoader.exists(child_path):
			_append_bootstrap_trace("extension missing child resource: %s" % child_path)
			disabled_extensions.push_back("%s (missing_child)" % extension_label)
			return {
				"error": "missing_child:%s" % child_path,
				"next_extension_index": extension_index + 1,
			}
		if not ResourceLoader.exists(parent_path):
			_append_bootstrap_trace("extension missing parent resource: %s" % parent_path)
			disabled_extensions.push_back("%s (missing_parent)" % extension_label)
			return {
				"error": "missing_parent:%s" % parent_path,
				"next_extension_index": extension_index + 1,
			}

		_append_bootstrap_trace("extension load child start: %s" % child_path)
		var child_script = load(child_path)
		_append_bootstrap_trace("extension load child done: %s" % child_path)
		if child_script == null:
			disabled_extensions.push_back("%s (failed_to_load_child)" % extension_label)
			return {
				"error": "failed_to_load_child:%s" % child_path,
				"next_extension_index": extension_index + 1,
			}

		_append_bootstrap_trace("extension resolve base start: %s" % child_path)
		var base_script = child_script.get_base_script()
		_append_bootstrap_trace("extension resolve base done: %s" % child_path)
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

		_append_bootstrap_trace("install_script_extension start: %s" % child_path)
		ModLoaderMod.install_script_extension(child_path)
		_append_bootstrap_trace("install_script_extension done: %s" % child_path)
		_append_bootstrap_trace("extension installed: %s" % extension_label)
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


func _reset_bootstrap_trace() -> void:
	var directory := Directory.new()
	if directory.open("user://") != OK:
		return
	if not directory.dir_exists(TRACE_DIR):
		var _make_dir_result = directory.make_dir(TRACE_DIR)

	var file := File.new()
	if file.open(TRACE_PATH, File.WRITE) != OK:
		return
	file.store_line("=== BrotatoLocalTogether bootstrap trace ===")
	file.store_line(str(OS.get_datetime()))
	file.close()


func _append_bootstrap_trace(message: String) -> void:
	var file := File.new()
	if file.open(TRACE_PATH, File.READ_WRITE) != OK:
		return
	file.seek_end()
	file.store_line("[%s] %s" % [str(Time.get_ticks_msec()), message])
	file.close()


