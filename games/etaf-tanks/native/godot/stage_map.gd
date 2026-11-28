extends RefCounted
## Text stage maps: parse, validate and normalize one battlefield.
## SPDX-License-Identifier: GPL-3.0-or-later
##
## A map is a header of "key: value" lines, then "map:" and one row per block
## line. Blocks are 8 px; tanks, the base and spawn points occupy 2x2 blocks.
##   .  open ground      #  brick           @  steel
##   ~  water           *  forest           =  ice
##   H  base (one 2x2)  P  player spawn (one 2x2)
##   E  enemy spawn (one to four 2x2 groups)
## Lines starting with ";" before "map:" are comments.

const EMPTY := 0
const BRICK := 1
const STEEL := 2
const WATER := 3
const FOREST := 4
const ICE := 5
const MIN_WIDTH := 12
const MAX_WIDTH := 52
const MIN_HEIGHT := 12
const MAX_HEIGHT := 40
const MAX_ENEMIES := 60
const TERRAIN := {".": EMPTY, "#": BRICK, "@": STEEL, "~": WATER, "*": FOREST, "=": ICE}
const MARKS := ["H", "P", "E"]

static func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message}

## Parse TEXT. STRICT rejects any defect; lenient parsing keeps every
## recognizable block for the editor and reports the first defect in "error".
static func parse(text: String, strict := true) -> Dictionary:
	if text.length() > 64 * 1024:
		return _fail("地图文件超过 64 KiB")
	var name := ""
	var counts: Array = [18, 2, 0, 0]
	var rows: PackedStringArray = []
	var in_map := false
	var ended := false
	var problem := ""
	var line_number := 0
	for raw in text.replace("\r", "").split("\n"):
		line_number += 1
		var line: String = raw
		if not in_map:
			var stripped := line.strip_edges()
			if stripped.is_empty() or stripped.begins_with(";"):
				continue
			if stripped == "map:":
				in_map = true
				continue
			var colon := stripped.find(":")
			if colon <= 0:
				return _fail("第 %d 行应为「键: 值」或 map:" % line_number)
			var key := stripped.substr(0, colon).strip_edges()
			var value := stripped.substr(colon + 1).strip_edges()
			match key:
				"name":
					if value.is_empty() or value.length() > 24:
						return _fail("地图名称需要 1–24 个字符")
					name = value
				"enemies":
					var parts := value.split(" ", false)
					if parts.size() != 4:
						return _fail("enemies 需要四个数：普通 快速 重炮 装甲")
					counts = []
					var total := 0
					for part in parts:
						if not part.is_valid_int() or int(part) < 0:
							return _fail("enemies 必须是非负整数")
						counts.append(int(part))
						total += int(part)
					if total < 1 or total > MAX_ENEMIES:
						return _fail("敌车总数需要 1–%d 辆" % MAX_ENEMIES)
				_:
					return _fail("未知的地图字段：" + key)
			continue
		var row := line.strip_edges(false, true)
		if row.is_empty():
			ended = not rows.is_empty()
			continue
		if ended:
			return _fail("地图行之间不能有空行")
		rows.append(row)
	if not in_map or rows.is_empty():
		return _fail("缺少 map: 段")
	var height := rows.size()
	var width := rows[0].length()
	if width < MIN_WIDTH or width > MAX_WIDTH or height < MIN_HEIGHT or height > MAX_HEIGHT:
		return _fail("地图尺寸需要 %d–%d 列、%d–%d 行" % [MIN_WIDTH, MAX_WIDTH, MIN_HEIGHT, MAX_HEIGHT])
	var terrain := PackedByteArray()
	terrain.resize(width * height)
	var marks := PackedStringArray()
	marks.resize(width * height)
	for y in height:
		var row: String = rows[y]
		if row.length() != width:
			if problem.is_empty():
				problem = "第 %d 行长度应为 %d" % [y + 1, width]
			if strict:
				return _fail(problem)
		for x in width:
			var symbol := row[x] if x < row.length() else "."
			var index := y * width + x
			if TERRAIN.has(symbol):
				terrain[index] = TERRAIN[symbol]
				marks[index] = ""
			elif symbol in MARKS:
				terrain[index] = EMPTY
				marks[index] = symbol
			else:
				terrain[index] = EMPTY
				marks[index] = ""
				if problem.is_empty():
					problem = "第 %d 行第 %d 列有未知符号 %s" % [y + 1, x + 1, symbol]
				if strict:
					return _fail(problem)
	var groups := {"H": [], "P": [], "E": []}
	var seen := {}
	for y in height:
		for x in width:
			var mark: String = marks[y * width + x]
			if mark.is_empty() or seen.has(y * width + x):
				continue
			var square := x + 1 < width and y + 1 < height
			if square:
				for offset in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
					var other: int = (y + offset.y) * width + x + offset.x
					square = square and marks[other] == mark and not seen.has(other)
			if not square:
				if problem.is_empty():
					problem = "第 %d 行第 %d 列的 %s 必须组成 2×2 方块" % [y + 1, x + 1, mark]
				continue
			for offset in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
				seen[(y + offset.y) * width + x + offset.x] = true
			groups[mark].append(Vector2i(x, y))
	if problem.is_empty():
		if groups.H.size() != 1:
			problem = "地图需要恰好一个 2×2 基地 H"
		elif groups.P.size() != 1:
			problem = "地图需要恰好一个 2×2 玩家出生点 P"
		elif groups.E.is_empty() or groups.E.size() > 4:
			problem = "地图需要 1–4 个 2×2 敌军出生点 E"
	if strict and not problem.is_empty():
		return _fail(problem)
	return {"ok": problem.is_empty(), "error": problem, "name": name if not name.is_empty() else "未命名",
		"counts": counts, "width": width, "height": height, "terrain": terrain, "marks": marks,
		"base": groups.H[0] if groups.H.size() == 1 else null,
		"player": groups.P[0] if groups.P.size() == 1 else null,
		"spawns": groups.E, "rows": rows}

## Return TEXT's normalized serialization from a strict parse RESULT.
static func serialize(result: Dictionary) -> String:
	var counts: Array = result.counts
	return "name: %s\nenemies: %d %d %d %d\nmap:\n%s\n" % [result.name, counts[0], counts[1], counts[2], counts[3], "\n".join(result.rows)]
