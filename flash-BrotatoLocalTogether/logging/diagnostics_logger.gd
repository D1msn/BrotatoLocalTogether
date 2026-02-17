extends Reference

const BASE_DIR := "user://brotato_local_together"
const LOG_PATH := BASE_DIR + "/diagnostics.log"
const MAX_SIZE_BYTES := 1024 * 1024


static func log_with_options(options_node, tag: String, message: String) -> void:
	if options_node != null:
		var enabled_value = options_node.get("diagnostics_log_enabled")
		if typeof(enabled_value) == TYPE_BOOL and not enabled_value:
			return
	log(tag, message)


static func log_network_metrics_with_options(options_node, tag: String, metrics: Dictionary) -> void:
	if metrics.empty():
		log_with_options(options_node, tag, "metrics unavailable")
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
	log_with_options(options_node, tag, message)


static func log(tag: String, message: String) -> void:
	var dir := Directory.new()
	if dir.open("user://") != OK:
		return
	if not dir.dir_exists("brotato_local_together"):
		var _make_result = dir.make_dir("brotato_local_together")

	var line := "[%s] %s: %s" % [_timestamp_iso(), tag, message]
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

	if file.get_len() > MAX_SIZE_BYTES:
		file.close()
		file = File.new()
		if file.open(LOG_PATH, File.WRITE) != OK:
			return
	else:
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
