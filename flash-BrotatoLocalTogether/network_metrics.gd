extends Node

const MAX_RTT_SAMPLES := 256

var packet_sent_count : int = 0
var packet_received_count : int = 0
var packet_acked_count : int = 0
var bytes_sent : int = 0
var bytes_received : int = 0

var rtt_samples : Array = []
var jitter_msec : float = 0.0
var _last_rtt_msec : float = -1.0

var packets_sent_by_type : Dictionary = {}
var packets_received_by_type : Dictionary = {}


func reset() -> void:
	packet_sent_count = 0
	packet_received_count = 0
	packet_acked_count = 0
	bytes_sent = 0
	bytes_received = 0
	rtt_samples.clear()
	jitter_msec = 0.0
	_last_rtt_msec = -1.0
	packets_sent_by_type.clear()
	packets_received_by_type.clear()


func record_packet_sent(message_type: int, size_bytes: int) -> void:
	packet_sent_count += 1
	bytes_sent += max(0, int(size_bytes))
	packets_sent_by_type[message_type] = int(packets_sent_by_type.get(message_type, 0)) + 1


func record_packet_received(message_type: int, size_bytes: int) -> void:
	packet_received_count += 1
	bytes_received += max(0, int(size_bytes))
	packets_received_by_type[message_type] = int(packets_received_by_type.get(message_type, 0)) + 1


func record_packet_acknowledged(count: int = 1) -> void:
	packet_acked_count += max(0, count)
	if packet_acked_count > packet_sent_count:
		packet_acked_count = packet_sent_count


func add_rtt_sample(rtt_msec: float) -> void:
	var normalized_rtt = max(0.0, float(rtt_msec))
	rtt_samples.push_back(normalized_rtt)
	if rtt_samples.size() > MAX_RTT_SAMPLES:
		rtt_samples.pop_front()

	if _last_rtt_msec < 0.0:
		jitter_msec = 0.0
	else:
		var delta = abs(normalized_rtt - _last_rtt_msec)
		jitter_msec += (delta - jitter_msec) / 16.0
	_last_rtt_msec = normalized_rtt


func get_packet_loss_rate() -> float:
	if packet_sent_count <= 0:
		return 0.0
	var lost_packets = max(0, packet_sent_count - packet_acked_count)
	return float(lost_packets) / float(packet_sent_count)


func get_snapshot() -> Dictionary:
	var p50 = _percentile(rtt_samples, 0.50)
	var p95 = _percentile(rtt_samples, 0.95)
	return {
		"packet_sent_count": packet_sent_count,
		"packet_received_count": packet_received_count,
		"packet_acked_count": packet_acked_count,
		"bytes_sent": bytes_sent,
		"bytes_received": bytes_received,
		"packet_loss_rate": get_packet_loss_rate(),
		"rtt_samples_count": rtt_samples.size(),
		"rtt_p50_msec": p50,
		"rtt_p95_msec": p95,
		"jitter_msec": jitter_msec,
		"packets_sent_by_type": packets_sent_by_type.duplicate(true),
		"packets_received_by_type": packets_received_by_type.duplicate(true),
	}


func _percentile(values: Array, percentile: float) -> float:
	if values.empty():
		return 0.0
	var sorted_values = values.duplicate()
	sorted_values.sort()
	var clamped_percentile = clamp(percentile, 0.0, 1.0)
	var index = int(round((sorted_values.size() - 1) * clamped_percentile))
	index = int(clamp(index, 0, sorted_values.size() - 1))
	return float(sorted_values[index])
