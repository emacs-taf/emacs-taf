extends SceneTree
## Shared JSON-lines bridge. Game projects implement capabilities/command/observe.
## SPDX-License-Identifier: GPL-3.0-or-later

const MAX_MESSAGE := 1024 * 1024
var game: Node
var reader := Thread.new()
var mutex := Mutex.new()
var pending: Array = []
var revision := 0
var connected := false
var elapsed := 0.0
var observation_interval := 0.05
var last_observation := ""
var output := PackedStringArray()

func _initialize() -> void:
	var rate = ProjectSettings.get_setting("gamekit/observation_hz", 20.0)
	if not (rate is int or rate is float) or not is_finite(float(rate)) or rate < 1 or rate > 60:
		printerr("gamekit/observation_hz must be a number between 1 and 60")
		quit(2)
		return
	observation_interval = 1.0 / float(rate)
	Engine.max_fps = 60
	# Store the directory, not a loaded script object: Godot 4.7 aborts at exit
	# when Engine metadata holds a GDScript.
	Engine.set_meta("gamekit_native_dir", get_script().resource_path.get_base_dir())
	call_deferred("_start_game")

func _start_game() -> void:
	var source: String = ProjectSettings.get_setting("gamekit/game_script", "res://game.gd")
	var script = load(source)
	if script == null:
		push_error("GameKit cannot load " + source)
		quit(2)
		return
	game = script.new()
	for method in ["capabilities", "command", "observe"]:
		if not game.has_method(method):
			push_error("GameKit game is missing " + method)
			quit(2)
			return
	root.add_child(game)
	reader.start(_read_input)

func _enqueue(value: Dictionary) -> void:
	mutex.lock()
	pending.append(value)
	mutex.unlock()

func _read_input() -> void:
	# Stdin blocks, so only this worker touches it. Scene/game work stays on main.
	var bytes := PackedByteArray()
	var previous := 0
	while true:
		var byte := OS.read_buffer_from_stdin(1)
		if byte.is_empty():
			_enqueue({"_eof": true})
			return
		if byte[0] != 10:
			bytes.append(byte[0])
			if bytes.size() > MAX_MESSAGE:
				_enqueue({"_fatal": "Request exceeds 1 MiB"})
				return
			continue
		var text := bytes.get_string_from_utf8()
		bytes.clear()
		if text.strip_edges().is_empty():
			continue
		var decoder := JSON.new()
		if decoder.parse(text) != OK:
			_enqueue({"_fatal": "Malformed GameKit JSON"})
			return
		var request = decoder.data
		if not request is Dictionary or request.get("version") != 1 or not request.get("id") is float or not request.get("op") is String or not request.get("args") is Dictionary:
			_enqueue({"_fatal": "Malformed GameKit request"})
			return
		var identifier := int(request.id)
		if identifier <= previous or float(identifier) != request.id:
			_enqueue({"_fatal": "Request IDs must increase"})
			return
		previous = identifier
		request.id = identifier
		_enqueue(request)

func _emit(identifier, failure = null) -> void:
	var observation: Dictionary = game.observe()
	var serialized := JSON.stringify(observation)
	if identifier == null and serialized == last_observation:
		return
	last_observation = serialized
	revision += 1
	output.append(JSON.stringify({"version": 1, "id": identifier, "revision": revision,
		"capabilities": game.capabilities(), "observation": observation, "error": failure}))

func _flush_output() -> void:
	if not output.is_empty():
		print("\n".join(output))
		output.clear()

func _physics_process(_delta: float) -> bool:
	if game == null:
		return false
	mutex.lock()
	var requests := pending
	pending = []
	mutex.unlock()
	for request in requests:
		if request.has("_fatal"):
			_flush_output()
			printerr(request._fatal)
			quit(2)
			return true
		if request.has("_eof"):
			_flush_output()
			return true
		var failure: String = ""
		if request.op == "start" and not connected:
			connected = true
		elif not connected or request.op == "start":
			failure = "Start once before sending advertised actions"
		else:
			failure = game.command(request.op, request.args)
		_emit(request.id, null if failure.is_empty() else failure)
	return false

func _process(delta: float) -> bool:
	if game == null:
		return false
	elapsed += delta
	if connected and elapsed >= observation_interval:
		elapsed = fmod(elapsed, observation_interval)
		_emit(null)
	_flush_output()
	return false

func _finalize() -> void:
	if reader.is_started():
		reader.wait_to_finish()
