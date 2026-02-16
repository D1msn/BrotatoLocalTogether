extends Node

const BASE_DIR := "brotato_local_together"
const SNAPSHOT_DIR := "user://brotato_local_together/snapshots"
const LATEST_SNAPSHOT_PATH := SNAPSHOT_DIR + "/latest.json"
const ROTATION_COUNT := 3
const SNAPSHOT_VERSION := 1


func has_snapshot() -> bool:
	var file := File.new()
	return file.file_exists(LATEST_SNAPSHOT_PATH)


func load_latest_snapshot() -> Dictionary:
	var file := File.new()
	if not file.file_exists(LATEST_SNAPSHOT_PATH):
		return {}
	if file.open(LATEST_SNAPSHOT_PATH, File.READ) != OK:
		return {}

	var raw_text := file.get_as_text()
	file.close()

	var parsed = parse_json(raw_text)
	if not parsed is Dictionary:
		return {}

	return parsed


func clear_snapshots() -> void:
	var directory := Directory.new()
	if directory.open("user://") != OK:
		return

	if not directory.dir_exists(BASE_DIR):
		return

	if directory.change_dir(BASE_DIR) != OK:
		return

	if not directory.dir_exists("snapshots"):
		return

	_clear_snapshot_directory(directory)


func save_snapshot(snapshot_payload: Dictionary) -> bool:
	var payload := snapshot_payload.duplicate(true)
	payload["snapshot_version"] = SNAPSHOT_VERSION
	payload["saved_at_unix"] = OS.get_unix_time()
	payload["saved_at_iso"] = _iso_utc_string()

	if not _ensure_snapshot_dir():
		return false

	_rotate_snapshots()

	var temp_path := SNAPSHOT_DIR + "/latest.tmp"
	var file := File.new()
	if file.open(temp_path, File.WRITE) != OK:
		return false

	file.store_string(to_json(payload))
	file.close()

	var directory := Directory.new()
	if directory.open(SNAPSHOT_DIR) != OK:
		return false

	var target_file_name := "latest.json"
	if directory.file_exists(target_file_name):
		var _remove_result = directory.remove(target_file_name)

	return directory.rename("latest.tmp", target_file_name) == OK


func _ensure_snapshot_dir() -> bool:
	var directory := Directory.new()
	if directory.open("user://") != OK:
		return false

	if not directory.dir_exists(BASE_DIR):
		if directory.make_dir(BASE_DIR) != OK:
			return false

	if directory.change_dir(BASE_DIR) != OK:
		return false

	if not directory.dir_exists("snapshots"):
		if directory.make_dir("snapshots") != OK:
			return false

	return true


func _rotate_snapshots() -> void:
	var directory := Directory.new()
	if directory.open(SNAPSHOT_DIR) != OK:
		return

	var newest_index := ROTATION_COUNT - 1
	for idx in range(newest_index, -1, -1):
		var from_name := "latest.json" if idx == 0 else "latest_%d.json" % idx
		var to_name := "latest_%d.json" % (idx + 1)

		if not directory.file_exists(from_name):
			continue

		if idx + 1 >= ROTATION_COUNT and directory.file_exists(to_name):
			var _remove_oldest = directory.remove(to_name)

		if directory.file_exists(to_name):
			var _remove_existing = directory.remove(to_name)

		var _rename_result = directory.rename(from_name, to_name)


func _clear_snapshot_directory(directory: Directory) -> void:
	if directory.change_dir("snapshots") != OK:
		return

	var _begin_result = directory.list_dir_begin(true, true)
	var file_name := directory.get_next()
	while file_name != "":
		if not directory.current_is_dir():
			var _remove_result = directory.remove(file_name)
		file_name = directory.get_next()
	directory.list_dir_end()

	directory.change_dir("..")
	var _remove_dir_result = directory.remove("snapshots")


func _iso_utc_string() -> String:
	var dt := OS.get_datetime(true)
	return "%04d-%02d-%02dT%02d:%02d:%02dZ" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
