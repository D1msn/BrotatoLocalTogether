class_name InterpolationBuffer

const RENDER_DELAY_MSEC := 80
const MAX_SNAPSHOTS := 20

var _buffer : Array = []
var _last_position : Vector2 = Vector2.ZERO


func clear() -> void:
	_buffer.clear()
	_last_position = Vector2.ZERO


func add_snapshot(pos: Vector2, timestamp_msec: int = -1) -> void:
	var snapshot_time = timestamp_msec
	if snapshot_time < 0:
		snapshot_time = Time.get_ticks_msec()

	_buffer.push_back({
		"t": snapshot_time,
		"pos": pos,
	})
	_last_position = pos

	while _buffer.size() > MAX_SNAPSHOTS:
		_buffer.pop_front()


func get_pos(timestamp_msec: int = -1) -> Vector2:
	if _buffer.empty():
		return _last_position
	if _buffer.size() == 1:
		return _buffer[0]["pos"]

	var render_time = timestamp_msec
	if render_time < 0:
		render_time = Time.get_ticks_msec() - RENDER_DELAY_MSEC

	while _buffer.size() > 2 and int(_buffer[1]["t"]) <= render_time:
		_buffer.pop_front()

	var first = _buffer[0]
	var second = _buffer[1]
	var first_time = int(first["t"])
	var second_time = int(second["t"])
	var first_pos: Vector2 = first["pos"]
	var second_pos: Vector2 = second["pos"]

	if render_time <= first_time:
		return first_pos
	if render_time >= second_time:
		return second_pos

	var range = second_time - first_time
	if range <= 0:
		return second_pos

	var alpha = float(render_time - first_time) / float(range)
	alpha = clamp(alpha, 0.0, 1.0)
	return first_pos.linear_interpolate(second_pos, alpha)
