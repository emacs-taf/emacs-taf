extends Node
## Public Godot SDK fixture: an autonomous clock, controlled through commands.
## SPDX-License-Identifier: GPL-3.0-or-later
var seconds := 0.0
var running := false
var tags: Array = []

func _physics_process(delta: float) -> void:
	if running:
		seconds += delta

func capabilities() -> Array:
	return ["run", "tag"]

func command(operation: String, args: Dictionary) -> String:
	if operation == "tag":
		tags.append(args.get("value"))
		return ""
	if operation != "run":
		return "Unknown clock action"
	seconds = 0.0
	running = true
	return ""

func observe() -> Dictionary:
	return {"seconds": seconds, "running": running, "tags": tags}
