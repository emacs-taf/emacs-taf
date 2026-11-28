extends Node
## GameKit adapter for Iron Tide: stage flow, commands, frames and snapshots.
## SPDX-License-Identifier: GPL-3.0-or-later
##
## stdout belongs to GameKit. Rules live in battle.gd, map text in
## stage_map.gd, artwork in art.gd and frame strips in canvas.gd. The
## simulation advances on the fixed physics clock; frames are composed only
## when something changed, and only changed strips are written. The frame
## rate paces steady animation; a frame answering player input is drawn on
## the next physics step instead of waiting for the next paced frame.

const StageMap := preload("res://stage_map.gd")
const Battle := preload("res://battle.gd")
const Canvas := preload("res://canvas.gd")
const CAPABILITIES := ["menu", "edit", "begin", "next", "restart", "pause", "drive", "aim", "stop", "fire",
	"settings", "display", "save", "load"]
const INTRO := 1.6
const SETTING_RANGES := {"speed": [0.5, 2.0], "player_speed": [0.5, 2.0], "hold": [0.05, 1.0], "repeat": [0.03, 0.5]}

var phase := "menu"
var paused := false
var battle = null
var map_text := ""
var preview := {}
var preview_error := ""
var cursor := {"x": 0, "y": 0, "size": 2}
var intro := 0.0
var canvas = Canvas.new()
var directory := ""
var frame_id := 0
var dirty := true
var prompt := false
var since_frame := 1.0
var settings := {"speed": 1.0, "player_speed": 1.0, "hold": 0.28, "repeat": 0.12, "latch": false, "frame_rate": 60}
var events: Array = []
var serial := [0]
var tally := {}
var stage := 1
var title := ""
var difficulty := "normal"
var rng := RandomNumberGenerator.new()

func _ready() -> void:
	rng.randomize()

func capabilities() -> Array:
	return CAPABILITIES

static func _integer(value, low: int, high: int) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and float(value) == floorf(float(value)) and int(value) >= low and int(value) <= high

static func _number(value, low: float, high: float) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and float(value) >= low and float(value) <= high

func _physics_process(delta: float) -> void:
	since_frame += delta
	match phase:
		"intro":
			if not paused:
				intro -= delta
				if intro <= 0.0:
					phase = "play"
					dirty = true
		"play":
			if not paused:
				battle.step(delta * settings.speed)
				dirty = true
				if battle.finished():
					_conclude()
	if dirty and not directory.is_empty() and (prompt or since_frame >= 1.0 / settings.frame_rate - 0.002):
		_render()

func _render() -> void:
	match phase:
		"menu":
			canvas.compose_map(preview, null)
		"edit":
			canvas.compose_map(preview, cursor)
		_:
			canvas.compose_battle(battle)
			if phase == "intro":
				canvas.banner("STAGE %d" % stage, "text")
			elif phase == "over" or battle.outcome == "lost":
				canvas.banner("GAME OVER", "danger", phase == "over")
			elif phase == "cleared":
				canvas.banner("STAGE CLEAR", "text")
			elif paused:
				canvas.banner("PAUSE", "text")
	frame_id += 1
	var failure: String = canvas.publish(directory, frame_id)
	if not failure.is_empty():
		_event("画面写入失败", failure, "danger")
		directory = ""
	dirty = false
	prompt = false
	since_frame = 0.0

func _event(heading: String, detail: String, kind := "info") -> void:
	if battle != null:
		battle.event(heading, detail, kind)
		return
	serial[0] += 1
	events.append({"id": serial[0], "title": heading, "detail": detail, "kind": kind})
	if events.size() > 4:
		events.pop_front()

func _conclude() -> void:
	var points: Array = []
	for kind in 4:
		points.append(battle.kills[kind] * Battle.KIND_POINTS[kind])
	tally = {"kills": battle.kills.duplicate(), "points": points, "score": battle.score,
		"lives": battle.lives, "star": battle.star, "next_life": battle.next_life, "cleared": battle.outcome == "cleared"}
	phase = "cleared" if battle.outcome == "cleared" else "over"
	paused = false
	dirty = true

func _new_battle(parsed: Dictionary, number: int, level: String, carry: Dictionary, seed: int):
	var next = Battle.new()
	next.events = events
	next.serial = serial
	next.setup(parsed, number, level, carry, seed)
	_apply_settings(next)
	return next

func _apply_settings(target) -> void:
	if target == null:
		return
	target.player_speed = settings.player_speed
	target.hold_first = settings.hold
	target.hold_repeat = settings.repeat
	target.latch = settings.latch
	if not settings.latch and target.player != null:
		target.player.latched = false

func _start(parsed: Dictionary, text: String, number: int, level: String, carry: Dictionary, seed: int) -> void:
	events.clear()
	battle = _new_battle(parsed, number, level, carry, seed)
	map_text = text
	stage = number
	difficulty = level
	title = parsed.name
	phase = "intro"
	intro = INTRO
	paused = false
	tally = {}
	dirty = true

func _carry(args: Dictionary, defaults: Dictionary) -> Variant:
	var carry := defaults.duplicate()
	for key in ["lives", "score", "star", "next_life"]:
		if args.has(key):
			var limits: Array = {"lives": [1, 99], "score": [0, 99999999], "star": [0, 3], "next_life": [1, 100000000]}[key]
			if not _integer(args[key], limits[0], limits[1]):
				return "参数无效：" + key
			carry[key] = int(args[key])
	return carry

func command(operation: String, args: Dictionary) -> String:
	match operation:
		"display":
			return _display(args)
		"settings":
			return _settings(args)
		"menu":
			if args.has("map") and not args.map is String:
				return "地图必须是文本"
			battle = null
			events.clear()
			phase = "menu"
			paused = false
			_preview(args.get("map", ""))
			return ""
		"edit":
			if not args.get("map") is String:
				return "地图必须是文本"
			if not _integer(args.get("x", 0), 0, StageMap.MAX_WIDTH - 1) or not _integer(args.get("y", 0), 0, StageMap.MAX_HEIGHT - 1) or not _integer(args.get("size", 2), 1, 2):
				return "光标或笔刷参数无效"
			battle = null
			events.clear()
			phase = "edit"
			paused = false
			_preview(args.map)
			cursor = {"x": int(args.get("x", 0)), "y": int(args.get("y", 0)), "size": int(args.get("size", 2))}
			return ""
		"begin":
			if not args.get("map") is String:
				return "地图必须是文本"
			if not _integer(args.get("stage", 1), 1, 999):
				return "关卡编号必须是 1–999 的整数"
			if not args.get("difficulty", "normal") in Battle.DIFFICULTIES:
				return "难度必须是 easy、normal 或 hard"
			if args.has("seed") and not _integer(args.seed, 0, 2147483647):
				return "随机种子必须是非负整数"
			var parsed: Dictionary = StageMap.parse(args.map)
			if not parsed.ok:
				return "地图无效：" + parsed.error
			var carry = _carry(args, {})
			if carry is String:
				return carry
			_start(parsed, args.map, int(args.get("stage", 1)), args.get("difficulty", "normal"), carry,
				int(args.seed) if args.has("seed") else rng.randi())
			return ""
		"next":
			if phase != "cleared":
				return "只有过关后才能进入下一关"
			if not args.get("map") is String or not _integer(args.get("stage"), 1, 999):
				return "下一关需要地图文本和关卡编号"
			var parsed: Dictionary = StageMap.parse(args.map)
			if not parsed.ok:
				return "地图无效：" + parsed.error
			var carry := {"lives": tally.lives, "score": tally.score, "star": tally.star, "next_life": tally.next_life}
			_start(parsed, args.map, int(args.stage), difficulty, carry, rng.randi())
			return ""
		"restart":
			if battle == null:
				return "当前没有可重开的关卡"
			_start(StageMap.parse(map_text), map_text, stage, difficulty, battle.start_carry, rng.randi())
			return ""
		"pause":
			if phase != "play" and phase != "intro":
				return "当前没有进行中的战斗"
			var wanted = args.get("paused")
			if wanted != null and not wanted is bool:
				return "暂停参数必须是布尔值"
			paused = (not paused) if wanted == null else wanted
			if paused:
				battle.stop()
			dirty = true
			prompt = true
			return ""
		"drive", "aim":
			var direction: int = Battle.FACINGS.find(args.get("direction"))
			if direction < 0:
				return "方向必须是 n、e、s 或 w"
			if battle == null or phase in ["menu", "edit"]:
				return "当前不在战斗中"
			if phase == "play" and not paused and battle.outcome != "lost":
				if operation == "drive":
					battle.drive(direction)
				else:
					battle.aim(direction)
				dirty = true
				prompt = true
			return ""
		"stop":
			if battle != null:
				battle.stop()
			return ""
		"fire":
			if battle == null or phase in ["menu", "edit"]:
				return "当前不在战斗中"
			if phase == "play" and not paused and battle.outcome != "lost" and battle.fire(battle.player):
				dirty = true
				prompt = true
			return ""
		"save", "load":
			if not args.get("path") is String or args.path.is_empty():
				return "请指定存档路径"
			return _save(args.path) if operation == "save" else _load(args.path)
	return "不支持的操作：" + operation

func _preview(text: String) -> void:
	preview = {}
	preview_error = ""
	if text.is_empty():
		return
	var parsed: Dictionary = StageMap.parse(text, false)
	preview_error = parsed.error
	if parsed.has("terrain"):
		preview = parsed
	dirty = true

func _display(args: Dictionary) -> String:
	var theme = args.get("theme", "dark")
	var block = args.get("block", 32)
	var height = args.get("line", 32)
	if not args.get("directory", "") is String or not theme in Canvas.Art.PALETTES:
		return "画面参数无效"
	if not _integer(block, 8, 96) or int(block) % 2 != 0 or not _integer(height, 6, 256):
		return "画面尺寸无效：每格须为 8–96 的偶数，行高须为 6–256"
	var target: String = args.get("directory", "")
	if not target.is_empty() and not DirAccess.dir_exists_absolute(target):
		return "画面目录不存在"
	directory = target
	if theme != canvas.theme or int(block) != canvas.block or int(height) != canvas.line or canvas.cw == 0:
		canvas.configure(theme, int(block), int(height))
		if battle != null:
			battle.terrain_reset = true
	dirty = true
	since_frame = 1.0
	return ""

func _settings(args: Dictionary) -> String:
	var next := settings.duplicate()
	for key in args:
		if SETTING_RANGES.has(key):
			if not _number(args[key], SETTING_RANGES[key][0], SETTING_RANGES[key][1]):
				return "设置超出范围：" + key
			next[key] = float(args[key])
		elif key == "latch":
			if not args[key] is bool:
				return "驾驶方式必须是布尔值"
			next[key] = args[key]
		elif key == "frame_rate":
			if not _integer(args[key], 10, 60):
				return "帧率必须是 10–60 的整数"
			next[key] = int(args[key])
		else:
			return "未知设置：" + str(key)
	settings = next
	_apply_settings(battle)
	return ""

func _save(path: String) -> String:
	if battle == null or not phase in ["intro", "play"]:
		return "只有战斗中才能存档"
	var data: Dictionary = battle.snapshot(map_text)
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		return "无法写入存档：" + error_string(FileAccess.get_open_error())
	file.store_string(JSON.stringify(data))
	file.close()
	var result := DirAccess.rename_absolute(path + ".tmp", path)
	return "" if result == OK else "无法发布存档：" + error_string(result)

func _load(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > 1024 * 1024:
		return "无法读取存档，或文件超过 1 MiB"
	var decoder := JSON.new()
	if decoder.parse(file.get_as_text()) != OK:
		return "无效的存档 JSON"
	var data = decoder.data
	if not data is Dictionary or data.get("format") != "iron-tide/2" or not data.get("map") is String:
		return "不兼容或无效的存档"
	if not _integer(data.get("stage"), 1, 999) or not data.get("difficulty") in Battle.DIFFICULTIES:
		return "存档的关卡或难度无效"
	var parsed: Dictionary = StageMap.parse(data.map)
	if not parsed.ok:
		return "存档地图无效：" + parsed.error
	var restored = Battle.new()
	restored.setup(parsed, int(data.stage), data.difficulty, {}, rng.randi())
	var failure: String = restored.restore(data)
	if not failure.is_empty():
		return failure
	events.clear()
	restored.events = events
	restored.serial = serial
	restored.event("已读取存档", "战斗已暂停；在途炮弹与出场动画已清空。", "info")
	_apply_settings(restored)
	battle = restored
	map_text = data.map
	stage = int(data.stage)
	difficulty = data.difficulty
	title = parsed.name
	phase = "play"
	paused = true
	tally = {}
	dirty = true
	return ""

func observe() -> Dictionary:
	var result := {"schema": "tanks/2", "phase": phase, "paused": paused, "stage": stage, "title": title,
		"difficulty": difficulty, "settings": settings, "size": null,
		"frame": null if directory.is_empty() or canvas.published == 0 else canvas.description(),
		"events": events}
	if phase in ["menu", "edit"]:
		result["map_error"] = preview_error
		if preview.has("terrain"):
			result["size"] = [preview.width, preview.height]
		if phase == "edit":
			result["editor"] = cursor
	if battle != null:
		var player = battle.player
		var at: Vector2 = battle.player_spawn if player == null else player.pos
		result["size"] = [battle.blocks_w, battle.blocks_h]
		result["hud"] = {"lives": battle.lives, "score": battle.score, "star": battle.star,
			"alive": player != null, "shield": player != null and player.shield > 0.0,
			"remaining": battle.remaining(), "field": battle.field(), "total": battle.roster.size(),
			"kills": battle.kills, "freeze": battle.freeze > 0.0, "fortify": battle.fortify > 0.0,
			"base": battle.base_alive, "bonus": null if battle.bonus == null else Battle.BONUSES[battle.bonus.kind]}
		result["actor"] = {"x": snappedf(at.x / Battle.BLOCK, 0.125), "y": snappedf(at.y / Battle.BLOCK, 0.125),
			"facing": Battle.FACINGS[0 if player == null else player.facing],
			"moving": player != null and player.moving, "shots": battle.shots, "can_fire": battle.can_fire()}
		if directory.is_empty():
			result["world"] = battle.world()
	if not tally.is_empty():
		result["tally"] = tally
	return result
