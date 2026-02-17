extends Node

# TODO rename options to globals

var joining_multiplayer_lobby : bool = false

var in_multiplayer_game : bool = false

var current_network_id : int = 0

const BASE_DIR := "brotato_local_together"
const NETWORK_CONFIG_PATH := "user://brotato_local_together/network.cfg"
const NETWORK_CONFIG_SECTION := "network"
const DEFAULT_HOST_PORT := 24567
const DEFAULT_SAFE_CORE_MODE := true
const DEFAULT_DIAGNOSTICS_LOG_ENABLED := true

var host_port : int = DEFAULT_HOST_PORT
var core_safe_mode : bool = DEFAULT_SAFE_CORE_MODE
var diagnostics_log_enabled : bool = DEFAULT_DIAGNOSTICS_LOG_ENABLED
var preferred_advertise_ip : String = ""
var last_join_endpoint : String = ""
var local_username : String = ""
var last_session_id : String = ""
var last_player_token : String = ""
var last_session_host_endpoint : String = ""
var last_session_seen_unix : int = 0

var batched_enemy_deaths = {}
var batched_unit_flashes = {}
var batched_floating_text = []
var batched_hit_particles = []
var batched_explosions = []
var batched_hit_effects = []
var batched_sounds = []
var batched_2d_sounds = []


func _ready() -> void:
	_load_network_config()


func get_local_username() -> String:
	if not local_username.empty():
		return local_username

	var profile_name := ""
	if OS.has_environment("USERNAME"):
		profile_name = String(OS.get_environment("USERNAME"))
	elif OS.has_environment("USER"):
		profile_name = String(OS.get_environment("USER"))

	if profile_name.empty():
		profile_name = "Player"

	local_username = profile_name
	return local_username


func set_local_username(value: String) -> void:
	local_username = value.strip_edges()
	if local_username.empty():
		local_username = "Player"
	_save_network_config()


func set_host_port(value: int) -> void:
	host_port = clamp(value, 1024, 65535)
	_save_network_config()


func set_last_join_endpoint(value: String) -> void:
	last_join_endpoint = value.strip_edges()
	_save_network_config()


func set_preferred_advertise_ip(value: String) -> void:
	preferred_advertise_ip = value.strip_edges()
	_save_network_config()

func set_diagnostics_log_enabled(value: bool) -> void:
	diagnostics_log_enabled = value
	_save_network_config()


func set_session_credentials(session_id: String, player_token: String, host_endpoint: String) -> void:
	last_session_id = session_id.strip_edges()
	last_player_token = player_token.strip_edges()
	last_session_host_endpoint = host_endpoint.strip_edges()
	last_session_seen_unix = OS.get_unix_time()
	_save_network_config()


func clear_session_credentials() -> void:
	last_session_id = ""
	last_player_token = ""
	last_session_host_endpoint = ""
	last_session_seen_unix = 0
	_save_network_config()


func _load_network_config() -> void:
	var config := ConfigFile.new()
	var load_result = config.load(NETWORK_CONFIG_PATH)
	if load_result != OK:
		return

	host_port = int(config.get_value(NETWORK_CONFIG_SECTION, "host_port", DEFAULT_HOST_PORT))
	host_port = clamp(host_port, 1024, 65535)
	core_safe_mode = bool(config.get_value(NETWORK_CONFIG_SECTION, "core_safe_mode", DEFAULT_SAFE_CORE_MODE))
	diagnostics_log_enabled = bool(config.get_value(NETWORK_CONFIG_SECTION, "diagnostics_log_enabled", DEFAULT_DIAGNOSTICS_LOG_ENABLED))

	preferred_advertise_ip = String(config.get_value(NETWORK_CONFIG_SECTION, "preferred_advertise_ip", ""))
	last_join_endpoint = String(config.get_value(NETWORK_CONFIG_SECTION, "last_join_endpoint", ""))
	local_username = String(config.get_value(NETWORK_CONFIG_SECTION, "local_username", ""))
	last_session_id = String(config.get_value(NETWORK_CONFIG_SECTION, "last_session_id", ""))
	last_player_token = String(config.get_value(NETWORK_CONFIG_SECTION, "last_player_token", ""))
	last_session_host_endpoint = String(config.get_value(NETWORK_CONFIG_SECTION, "last_session_host_endpoint", ""))
	last_session_seen_unix = int(config.get_value(NETWORK_CONFIG_SECTION, "last_session_seen_unix", 0))


func _save_network_config() -> void:
	var config := ConfigFile.new()
	config.set_value(NETWORK_CONFIG_SECTION, "host_port", host_port)
	config.set_value(NETWORK_CONFIG_SECTION, "core_safe_mode", core_safe_mode)
	config.set_value(NETWORK_CONFIG_SECTION, "diagnostics_log_enabled", diagnostics_log_enabled)
	config.set_value(NETWORK_CONFIG_SECTION, "preferred_advertise_ip", preferred_advertise_ip)
	config.set_value(NETWORK_CONFIG_SECTION, "last_join_endpoint", last_join_endpoint)
	config.set_value(NETWORK_CONFIG_SECTION, "local_username", local_username)
	config.set_value(NETWORK_CONFIG_SECTION, "last_session_id", last_session_id)
	config.set_value(NETWORK_CONFIG_SECTION, "last_player_token", last_player_token)
	config.set_value(NETWORK_CONFIG_SECTION, "last_session_host_endpoint", last_session_host_endpoint)
	config.set_value(NETWORK_CONFIG_SECTION, "last_session_seen_unix", last_session_seen_unix)

	var base_dir := Directory.new()
	if base_dir.open("user://") != OK:
		return
	if not base_dir.dir_exists(BASE_DIR):
		var _make_result = base_dir.make_dir(BASE_DIR)

	var _save_result = config.save(NETWORK_CONFIG_PATH)
