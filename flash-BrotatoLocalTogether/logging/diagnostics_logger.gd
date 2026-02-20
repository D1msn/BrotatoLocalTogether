extends Reference

const BASE_DIR_NAME := "brotato_local_together"
const BASE_DIR := "user://brotato_local_together"
const LOG_FILE_NAME := "diagnostics.log"
const LOG_ROTATED_1_FILE_NAME := "diagnostics.log.1"
const LOG_ROTATED_2_FILE_NAME := "diagnostics.log.2"
const LOG_PATH := BASE_DIR + "/" + LOG_FILE_NAME
const LOG_ROTATED_1_PATH := BASE_DIR + "/" + LOG_ROTATED_1_FILE_NAME
const LOG_ROTATED_2_PATH := BASE_DIR + "/" + LOG_ROTATED_2_FILE_NAME
const MAX_SIZE_BYTES := 2 * 1024 * 1024

const LEVEL_DEBUG := "DEBUG"
const LEVEL_INFO := "INFO"
const LEVEL_WARN := "WARN"
const LEVEL_ERROR := "ERROR"

const DEFAULT_LEVEL := LEVEL_DEBUG
const DEFAULT_ECHO_STDOUT := true
const RUNTIME_SESSION_TAG_SETTING := "brotato_local_together/runtime_session_tag"

static func set_session(tag: String) -> void:
	ProjectSettings.set_setting(RUNTIME_SESSION_TAG_SETTING, String(tag).strip_edges())


static func clear_session() -> void:
	ProjectSettings.set_setting(RUNTIME_SESSION_TAG_SETTING, "")


static func log_debug_with_options(options_node, tag: String, message: String) -> void:
	_log_with_options_and_level(options_node, LEVEL_DEBUG, tag, message)


static func log_info_with_options(options_node, tag: String, message: String) -> void:
	_log_with_options_and_level(options_node, LEVEL_INFO, tag, message)


static func log_warn_with_options(options_node, tag: String, message: String) -> void:
	_log_with_options_and_level(options_node, LEVEL_WARN, tag, message)


static func log_error_with_options(options_node, tag: String, message: String) -> void:
	_log_with_options_and_level(options_node, LEVEL_ERROR, tag, message)


static func log_with_options(options_node, tag: String, message: String) -> void:
	# Совместимость со старым API: log_with_options == INFO.
	_log_with_options_and_level(options_node, LEVEL_INFO, tag, message)


static func log_network_metrics_with_options(options_node, tag: String, metrics: Dictionary) -> void:
	if metrics.empty():
		log_warn_with_options(options_node, tag, "metrics unavailable")
		return

	var message = (
		"sent=%d recv=%d acked=%d bytes_sent=%d bytes_recv=%d loss=%.3f p50=%.2fms p95=%.2fms jitter=%.2fms samples=%d"
		% [
			int(metrics.get("packet_sent_count", 0)),
			int(metrics.get("packet_received_count", 0)),
			int(metrics.get("packet_acked_count", 0)),
			int(metrics.get("bytes_sent", 0)),
			int(metrics.get("bytes_received", 0)),
			float(metrics.get("packet_loss_rate", 0.0)),
			float(metrics.get("rtt_p50_msec", 0.0)),
			float(metrics.get("rtt_p95_msec", 0.0)),
			float(metrics.get("jitter_msec", 0.0)),
			int(metrics.get("rtt_samples_count", 0)),
		]
	)
	log_info_with_options(options_node, tag, message)


static func log(tag: String, message: String) -> void:
	# Совместимость со старым API: log == INFO без options.
	_log_with_options_and_level(null, LEVEL_INFO, tag, message)


static func _log_with_options_and_level(options_node, level: String, tag: String, message: String) -> void:
	var normalized_level = _normalize_level(level)
	if not _is_logging_enabled(options_node):
		return
	if not _is_level_allowed(options_node, normalized_level):
		return

	_ensure_base_dir()
	_rotate_if_needed()

	var safe_tag = String(tag).strip_edges()
	if safe_tag.empty():
		safe_tag = "General"
	var safe_message = String(message)
	var line = _format_line(options_node, normalized_level, safe_tag, safe_message)
	_write_line(line)

	if _should_echo_stdout(options_node):
		print("[BrotatoLocalTogether][%s][%s] %s" % [normalized_level, safe_tag, safe_message])


static func _format_line(options_node, level: String, tag: String, message: String) -> String:
	return "[%s][%s][session:%s][scene:%s][%s] %s" % [
		_timestamp_iso(),
		level,
		_session_label(options_node),
		_current_scene_label(),
		tag,
		message,
	]


static func _session_label(options_node) -> String:
	var runtime_tag := ""
	if ProjectSettings.has_setting(RUNTIME_SESSION_TAG_SETTING):
		runtime_tag = String(ProjectSettings.get_setting(RUNTIME_SESSION_TAG_SETTING)).strip_edges()
	if not runtime_tag.empty():
		return runtime_tag
	if options_node == null:
		return "-"
	var session_id = String(options_node.get("last_session_id", "")).strip_edges()
	if session_id.empty():
		return "-"
	return session_id


static func _current_scene_label() -> String:
	var main_loop = Engine.get_main_loop()
	if main_loop == null:
		return "-"
	if not (main_loop is SceneTree):
		return "-"
	var tree = main_loop
	if tree.current_scene == null:
		return "-"
	return String(tree.current_scene.name)


static func _is_logging_enabled(options_node) -> bool:
	if options_node == null:
		return true
	var enabled_value = options_node.get("diagnostics_log_enabled")
	if typeof(enabled_value) == TYPE_BOOL:
		return enabled_value
	return true


static func _is_level_allowed(options_node, line_level: String) -> bool:
	var min_level = DEFAULT_LEVEL
	if options_node != null:
		var value = options_node.get("diagnostics_log_level")
		if value != null:
			min_level = String(value)

	return _level_weight(line_level) >= _level_weight(_normalize_level(min_level))


static func _should_echo_stdout(options_node) -> bool:
	if options_node == null:
		return DEFAULT_ECHO_STDOUT
	var echo_value = options_node.get("diagnostics_log_echo_stdout")
	if typeof(echo_value) == TYPE_BOOL:
		return echo_value
	return DEFAULT_ECHO_STDOUT


static func _normalize_level(level: String) -> String:
	var normalized = String(level).strip_edges().to_upper()
	if normalized == LEVEL_DEBUG:
		return LEVEL_DEBUG
	if normalized == LEVEL_INFO:
		return LEVEL_INFO
	if normalized == LEVEL_WARN:
		return LEVEL_WARN
	if normalized == LEVEL_ERROR:
		return LEVEL_ERROR
	return DEFAULT_LEVEL


static func _level_weight(level: String) -> int:
	if level == LEVEL_DEBUG:
		return 10
	if level == LEVEL_INFO:
		return 20
	if level == LEVEL_WARN:
		return 30
	if level == LEVEL_ERROR:
		return 40
	return 20


static func _ensure_base_dir() -> void:
	var dir := Directory.new()
	if dir.open("user://") != OK:
		return
	if not dir.dir_exists(BASE_DIR_NAME):
		var _mkdir_result = dir.make_dir(BASE_DIR_NAME)


static func _rotate_if_needed() -> void:
	var file := File.new()
	if not file.file_exists(LOG_PATH):
		return
	if file.open(LOG_PATH, File.READ) != OK:
		return
	var current_len = file.get_len()
	file.close()
	if current_len <= MAX_SIZE_BYTES:
		return

	var dir := Directory.new()
	if dir.open(BASE_DIR) != OK:
		return

	if dir.file_exists(LOG_ROTATED_2_FILE_NAME):
		var _remove_result = dir.remove(LOG_ROTATED_2_FILE_NAME)
	if dir.file_exists(LOG_ROTATED_1_FILE_NAME):
		var _rename_1_result = dir.rename(LOG_ROTATED_1_FILE_NAME, LOG_ROTATED_2_FILE_NAME)
	if dir.file_exists(LOG_FILE_NAME):
		var _rename_0_result = dir.rename(LOG_FILE_NAME, LOG_ROTATED_1_FILE_NAME)


static func _write_line(line: String) -> void:
	var file_exists = File.new().file_exists(LOG_PATH)
	if not file_exists:
		print("BrotatoLocalTogether diagnostics path: " + ProjectSettings.globalize_path(LOG_PATH))

	var file := File.new()
	var open_result = file.open(LOG_PATH, File.READ_WRITE)
	if open_result != OK:
		open_result = file.open(LOG_PATH, File.WRITE)
		if open_result != OK:
			return
		file.store_line(line)
		file.close()
		return

	file.seek_end()
	file.store_line(line)
	file.close()


static func _timestamp_iso() -> String:
	var dt = OS.get_datetime()
	return "%04d-%02d-%02d %02d:%02d:%02d" % [
		int(dt.year),
		int(dt.month),
		int(dt.day),
		int(dt.hour),
		int(dt.minute),
		int(dt.second),
	]
