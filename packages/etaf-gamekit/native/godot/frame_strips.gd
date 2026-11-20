extends RefCounted
## Shared publisher for native frame canvases.
## SPDX-License-Identifier: GPL-3.0-or-later
##
## A game composes its canvas from a background image plus ordered draw
## operations, and this class encodes only the changed strips as numbered PNG
## files for `etaf-gamekit-frame-canvas`.  One strip is one text line tall:
## `line` device pixels, `width` device pixels wide.  PNG encoding dominates a
## frame's cost, so a publication repaints and encodes only dirty strips, in
## parallel on the worker pool, and retires old files only after KEEP newer
## versions exist.
##
## The game keeps ownership of its artwork, layers and simulation; it paints
## `base` directly, calls `mark_all()` or `mark_rows()` after changing it, and
## records each frame's sprites with `draw()`.  A game script loads this class
## from the bridge's directory, exposed as `Engine.get_meta("gamekit_native_dir")`.

const CLEAR := Color(0, 0, 0, 0)
## File versions kept per strip; older ones are deleted after a publication.
const KEEP := 16

## Device pixels per logical block, as configured by the application.
var block := 16
## Device pixel height of one strip, as configured by the application.
var line := 16
## Device pixel canvas width.
var width := 0
## Device pixel canvas height.
var height := 0
## Number of strips covering HEIGHT.
var strips := 0
## Background layer the game paints; the size of the configured canvas.
var base: Image = null
## Composed canvas: WIDTH x (STRIPS * LINE) device pixels.
var frame: Image = null
## Draw operations of the frame being composed.
var ops: Array = []
## Per-strip operation signatures of the last composed frame.
var signatures := PackedStringArray()
## Strips to repaint on the next publication.
var dirty := PackedByteArray()
## Publication id of each strip's newest file.
var serials := PackedInt32Array()
## File paths kept per strip, oldest first.
var versions: Array = []
## Id of the newest complete publication.
var published := 0
## Directory holding the published strip files.
var directory := ""
var batch := PackedInt32Array()
var batch_id := 0
var failures := PackedStringArray()
var mutex := Mutex.new()

## Adopt DEVICE_BLOCK pixels per logical block, DEVICE_LINE pixels per strip
## and a canvas of CANVAS_WIDTH x CANVAS_HEIGHT device pixels.  A changed shape
## reallocates BASE and FRAME and repaints every strip on the next publication;
## a game that repaints BASE for another reason calls `mark_all()`.
func configure(device_block: int, device_line: int, canvas_width: int, canvas_height: int) -> void:
	var reshape: bool = (frame == null or canvas_width != width or canvas_height != height
		or device_line != line)
	block = device_block
	line = device_line
	if reshape:
		width = canvas_width
		height = canvas_height
		strips = ceili(float(height) / line)
		base = Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
		frame = Image.create_empty(width, strips * line, false, Image.FORMAT_RGBA8)
		signatures.resize(strips)
		dirty.resize(strips)
		dirty.fill(1)
		serials.resize(strips)
		var previous := versions.size()
		versions.resize(strips)
		for index in range(previous, strips):
			versions[index] = []
	published = 0

## Start a frame: drop the previous frame's draw operations.
func begin() -> void:
	ops.clear()

## Record IMAGE's SOURCE rectangle (all of it by default) at device pixel AT.
## KEY identifies the drawing for change detection; an empty KEY draws a
## background-derived layer whose changes the game marks itself.
func draw(key: String, image: Image, at: Vector2i, source := Rect2i()) -> void:
	ops.append([key, image, Rect2i(Vector2i.ZERO, image.get_size()) if source.size == Vector2i.ZERO else source, at])

## Mark the strips covering device pixel rows TOP to BOTTOM; call after
## changing BASE over that range.
func mark_rows(top: int, bottom: int) -> void:
	if strips == 0 or bottom <= top:
		return
	var first := clampi(top / line, 0, strips - 1)
	var last := clampi((bottom - 1) / line, 0, strips - 1)
	for index in range(first, last + 1):
		dirty[index] = 1

## Mark every strip dirty; call after changing BASE over the whole canvas.
func mark_all() -> void:
	dirty.fill(1)

## Repaint and write the changed strips of frame ID into TARGET.
## Return "" on success or a message describing the write failure.
func publish(target: String, id: int) -> String:
	if target != directory:
		directory = target
		for index in strips:
			versions[index] = []
		dirty.fill(1)
	_finish()
	batch.clear()
	for index in strips:
		if dirty[index]:
			batch.append(index)
	if batch.is_empty():
		return ""
	batch_id = id
	failures.clear()
	var task := WorkerThreadPool.add_group_task(_write, batch.size(), -1, true, "GameKit frame strips")
	WorkerThreadPool.wait_for_group_task_completion(task)
	if not failures.is_empty():
		return failures[0]
	for index in batch:
		var kept: Array = versions[index]
		kept.append(_strip_path(index, id))
		while kept.size() > KEEP:
			DirAccess.remove_absolute(kept.pop_front())
		serials[index] = id
		dirty[index] = 0
	published = id
	return ""

## Describe the newest publication for the observation.
func description() -> Dictionary:
	return {"id": published, "block": block, "line": line, "width": width, "strips": Array(serials)}

## Mark strips whose operation signatures changed since the last frame.
func _finish() -> void:
	var tags: Array = []
	tags.resize(strips)
	tags.fill("")
	for op in ops:
		var at: Vector2i = op[3]
		var top := maxi(at.y, 0)
		var bottom := mini(at.y + op[2].size.y, height)
		if top >= bottom or op[0].is_empty():
			continue
		var tag := "%s@%d,%d|" % [op[0], at.x, at.y]
		for strip in range(top / line, (bottom - 1) / line + 1):
			tags[strip] += tag
	for index in strips:
		var signature: String = tags[index]
		if signature != signatures[index]:
			signatures[index] = signature
			dirty[index] = 1

## Repaint device rows TOP to BOTTOM from BASE and the operations.
func _paint(top: int, bottom: int) -> void:
	var limit := mini(bottom, height)
	if limit > top:
		frame.blit_rect(base, Rect2i(0, top, width, limit - top), Vector2i(0, top))
	if bottom > limit:
		frame.fill_rect(Rect2i(0, maxi(top, limit), width, bottom - maxi(top, limit)), CLEAR)
	for op in ops:
		var source: Rect2i = op[2]
		var at: Vector2i = op[3]
		var first := maxi(at.y, top)
		var last := mini(at.y + source.size.y, limit)
		if first < last:
			frame.blend_rect(op[1], Rect2i(source.position.x, source.position.y + first - at.y, source.size.x, last - first), Vector2i(at.x, first))

## Encode and atomically write the batch's Nth strip; runs on the worker pool.
func _write(n: int) -> void:
	var index := batch[n]
	_paint(index * line, (index + 1) * line)
	var image := frame.get_region(Rect2i(0, index * line, width, line))
	if (index + 1) * line <= height:
		image.convert(Image.FORMAT_RGB8)
	var path := _strip_path(index, batch_id)
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		failure("Cannot write frame file: " + error_string(FileAccess.get_open_error()))
		return
	file.store_buffer(image.save_png_to_buffer())
	file.close()
	var result := DirAccess.rename_absolute(path + ".tmp", path)
	if result != OK:
		failure("Cannot publish frame file: " + error_string(result))

## Record one write failure for the publishing thread.
func failure(message: String) -> void:
	mutex.lock()
	failures.append(message)
	mutex.unlock()

func _strip_path(index: int, id: int) -> String:
	return "%s/%d-%d.png" % [directory, index, id]
