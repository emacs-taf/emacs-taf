extends Node
## Godot fixture for the shared frame strip publisher.
## SPDX-License-Identifier: GPL-3.0-or-later

var strips = null
var published := 0
var message := ""

func _init() -> void:
	var native_dir: String = Engine.get_meta("gamekit_native_dir")
	strips = load(native_dir.path_join("frame_strips.gd")).new()

func capabilities() -> Array:
	return ["publish"]

func command(operation: String, args: Dictionary) -> String:
	if operation != "publish":
		return "Unknown operation"
	var directory: String = str(args.get("directory", ""))
	if directory.is_empty():
		return "Publish needs a directory"
	var identity := int(args.get("id", published + 1))
	if published == 0:
		strips.configure(int(args.get("block", 16)), int(args.get("line", 16)),
				int(args.get("width", 64)), int(args.get("height", 32)))
		strips.base.fill(Color(0.2, 0.4, 0.8))
		strips.mark_all()
	strips.begin()
	strips.draw("dot", _dot(), Vector2i(0, 0))
	if int(args.get("variant", 0)) == 1:
		strips.draw("extra", _dot(), Vector2i(4, 0))
	message = strips.publish(directory, identity)
	published = identity
	return message

func _dot() -> Image:
	var image := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return image

func observe() -> Dictionary:
	return {"schema": "fixture/frame", "published": published, "message": message,
		"frame": null if published == 0 else strips.description()}
