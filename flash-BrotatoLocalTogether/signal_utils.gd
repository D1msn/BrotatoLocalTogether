extends Reference


static func safe_connect(source: Object, signal_name: String, target: Object, method: String, binds: Array = [], flags: int = 0) -> int:
	if source == null or target == null:
		return ERR_INVALID_PARAMETER
	if not source.has_signal(signal_name):
		return ERR_UNAVAILABLE
	if source.is_connected(signal_name, target, method):
		return OK
	return source.connect(signal_name, target, method, binds, flags)


static func safe_disconnect(source: Object, signal_name: String, target: Object, method: String) -> int:
	if source == null or target == null:
		return ERR_INVALID_PARAMETER
	if not source.has_signal(signal_name):
		return ERR_UNAVAILABLE
	if not source.is_connected(signal_name, target, method):
		return OK
	source.disconnect(signal_name, target, method)
	return OK
