extends "res://singletons/utils.gd"


func is_player_action_released(event: InputEvent, player_index: int, action: String)->bool:
	if CoopService.get_remapped_player_device(player_index) >= 50:
		return false
	
	return .is_player_action_released(event, player_index, action)


func focus_player_control(control: Control, player_index: int, focus_emulator: FocusEmulator = null) -> void :
	if not is_instance_valid(control):
		return
	if not control.is_visible_in_tree():
		return
	if focus_emulator == null:
		focus_emulator = get_focus_emulator(player_index)
	if RunData.is_coop_run:
		if focus_emulator == null or not is_instance_valid(focus_emulator):
			return
		if not focus_emulator.is_inside_tree():
			return
		focus_emulator.set_deferred("focused_control", control)
	else:
		call_deferred("_safe_grab_focus_control", control)


func _safe_grab_focus_control(control: Control) -> void:
	if not is_instance_valid(control):
		return
	if not control.is_inside_tree():
		return
	control.grab_focus()
