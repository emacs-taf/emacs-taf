extends RefCounted
## Original Iron Tide artwork, generated as SVG documents.
## SPDX-License-Identifier: GPL-3.0-or-later
##
## One art unit is one eighth of a map block, the same scale as the
## simulation's coordinates. Every sprite is an SVG document measured in
## units; canvas.gd rasterizes it at the display's device pixels per unit.
## Themes are token tables, so both palettes share one set of shapes: flat
## surfaces with soft top-left light, rounded corners and gentle gradients.

const PALETTES := {
	"dark": {
		"ground": "#1b2029", "ground_tile": "#1f2530", "ground_dot": "#262d3a",
		"brick": "#c9673d", "brick_hi": "#e58c5e", "brick_lo": "#a24a29", "mortar": "#4a2418",
		"steel": "#8e9bb0", "steel_hi": "#d3dbe7", "steel_lo": "#5b677b", "steel_rivet": "#e8edf4",
		"water": "#1d5d9c", "water_hi": "#3f86c8", "water_wave": "#7cc0f0",
		"forest": "#2f8a4a", "forest_hi": "#5cc06e", "forest_lo": "#1c5b31",
		"ice": "#b6d3e4", "ice_hi": "#e6f3fa", "ice_lo": "#93b6cc",
		"plinth": "#384152", "plinth_hi": "#4d5870",
		"emblem": "#f2bb3e", "emblem_hi": "#ffe08a", "emblem_lo": "#b9821c",
		"ruin": "#3a3530", "ruin_hi": "#5d554c",
		"shell_core": "#fff7dc", "shell_glow": "#ffbe55",
		"text": "#f4f1e8", "text_shadow": "#07090d", "danger": "#ff6b5e",
		"panel": "#10141b", "panel_edge": "#ffffff", "panel_opacity": 0.86,
		"cursor": "#ffd166", "cursor_edge": "#07090d", "mark": "#ff4f6d",
		"shade": "#05070a80", "grid": "#ffffff14", "shadow": 0.6,
	},
	"light": {
		"ground": "#e8e2d2", "ground_tile": "#e2dbc9", "ground_dot": "#d7cfbb",
		"brick": "#c86a43", "brick_hi": "#e8936a", "brick_lo": "#a3502e", "mortar": "#7a3d26",
		"steel": "#9aa6b8", "steel_hi": "#e1e7f0", "steel_lo": "#6a7689", "steel_rivet": "#f4f7fb",
		"water": "#3b86c9", "water_hi": "#5ea3de", "water_wave": "#b4dcf7",
		"forest": "#3d9a54", "forest_hi": "#73cc80", "forest_lo": "#287040",
		"ice": "#d4e7f2", "ice_hi": "#ffffff", "ice_lo": "#b2cfe0",
		"plinth": "#5b6577", "plinth_hi": "#76829a",
		"emblem": "#f0b43a", "emblem_hi": "#ffe08a", "emblem_lo": "#b47c18",
		"ruin": "#6a6058", "ruin_hi": "#8d8279",
		"shell_core": "#3a2a10", "shell_glow": "#ff9b3d",
		"text": "#2a2620", "text_shadow": "#ffffff", "danger": "#d43d31",
		"panel": "#fbf8f1", "panel_edge": "#000000", "panel_opacity": 0.9,
		"cursor": "#e0602b", "cursor_edge": "#ffffff", "mark": "#e0335a",
		"shade": "#3a33264a", "grid": "#00000012", "shadow": 0.4,
	},
}

## Tank colourways: body, highlight, shade and turret.
const COLORWAYS := {
	"player": ["#f0b43a", "#ffe08a", "#b47c18", "#f7c75a"],
	"basic": ["#9aa7ba", "#dbe3ee", "#66738a", "#b0bccd"],
	"fast": ["#3fc1c9", "#a6eef2", "#1f8a92", "#5fd3da"],
	"power": ["#ef6a5b", "#ffb2a6", "#b23e31", "#f5877a"],
	"armor4": ["#8b7cf0", "#cbc3ff", "#5a4bc0", "#a093f5"],
	"armor3": ["#b36be0", "#e3bdfa", "#7d3fae", "#c487ea"],
	"armor2": ["#e06bb4", "#f8bde0", "#a83f82", "#ea88c6"],
	"armor1": ["#a59fc4", "#dcd8f2", "#6f6994", "#b8b3d6"],
	"bonus": ["#ff4f6d", "#ffc0cb", "#c22745", "#ff7690"],
	"flash": ["#ffffff", "#ffffff", "#c9ced8", "#ffffff"],
}

## Hull rectangle, turret radius, barrel width and top, and options.
const SHAPES := {
	"player0": {"hull": [3.4, 3.2, 9.2, 10.4], "turret": 3.1, "barrel": [1.7, 0.6]},
	"player1": {"hull": [3.4, 3.2, 9.2, 10.4], "turret": 3.2, "barrel": [1.8, 0.2], "brake": true},
	"player2": {"hull": [3.2, 3.0, 9.6, 10.8], "turret": 3.3, "barrel": [1.8, 0.2], "brake": true, "plates": true},
	"player3": {"hull": [3.0, 2.8, 10.0, 11.0], "turret": 3.5, "barrel": [1.4, 0.2], "twin": true, "plates": true},
	"basic": {"hull": [3.4, 3.4, 9.2, 10.2], "turret": 3.0, "barrel": [1.6, 1.0]},
	"fast": {"hull": [4.0, 3.0, 8.0, 10.6], "turret": 2.7, "barrel": [1.4, 1.4], "nose": true},
	"power": {"hull": [3.4, 3.4, 9.2, 10.2], "turret": 3.2, "barrel": [2.2, 0.0], "brake": true},
	"armor": {"hull": [2.8, 3.0, 10.4, 10.8], "turret": 3.4, "barrel": [2.0, 0.8], "plates": true},
}

const BONUS_ICONS := {
	"star": "<path d=\"M8 3.4 L9.4 6.4 L12.6 6.7 L10.2 8.9 L10.9 12.1 L8 10.4 L5.1 12.1 L5.8 8.9 L3.4 6.7 L6.6 6.4 Z\" fill=\"#ffffff\"/>",
	"helmet": "<path d=\"M3.6 10.4 Q3.6 4 8 4 Q12.4 4 12.4 10.4 Z\" fill=\"#ffffff\"/><rect x=\"3\" y=\"10\" width=\"10\" height=\"1.6\" rx=\"0.8\" fill=\"#ffffff\"/>",
	"clock": "<circle cx=\"8\" cy=\"7.6\" r=\"4.2\" fill=\"none\" stroke=\"#ffffff\" stroke-width=\"1.2\"/><path d=\"M8 5.2 V7.8 L9.8 9\" stroke=\"#ffffff\" stroke-width=\"1\" fill=\"none\" stroke-linecap=\"round\"/>",
	"shovel": "<path d=\"M8 3.2 V8.6\" stroke=\"#ffffff\" stroke-width=\"1.1\" stroke-linecap=\"round\"/><path d=\"M5.4 8 H10.6 L10 11 Q8 12.8 6 11 Z\" fill=\"#ffffff\"/>",
	"grenade": "<circle cx=\"8\" cy=\"8.6\" r=\"3.6\" fill=\"#ffffff\"/><rect x=\"6.9\" y=\"3.4\" width=\"2.2\" height=\"2\" rx=\"0.5\" fill=\"#ffffff\"/>",
	"tank": "<rect x=\"4\" y=\"5.6\" width=\"8\" height=\"5.6\" rx=\"1.2\" fill=\"#ffffff\"/><rect x=\"7.3\" y=\"3\" width=\"1.4\" height=\"4\" rx=\"0.5\" fill=\"#ffffff\"/>",
}

## 5x7 glyphs for the board's banners and score popups.
const FONT := {
	"0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
	"1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
	"2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
	"3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
	"4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
	"5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
	"6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
	"7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
	"8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
	"9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
	"A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
	"C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
	"D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
	"E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
	"G": ["01110", "10001", "10000", "10111", "10001", "10001", "01111"],
	"L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
	"M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
	"O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
	"P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
	"R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
	"S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
	"T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
	"U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
	"V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
	"Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
}

# ------------------------------------------------------------------ helpers

static func _n(value: float) -> String:
	return ("%.3f" % value).rstrip("0").rstrip(".")

static func _svg(w: float, h: float, body: String, defs := "") -> String:
	return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%s\" height=\"%s\" viewBox=\"0 0 %s %s\"><defs>%s</defs>%s</svg>" % [_n(w), _n(h), _n(w), _n(h), defs, body]

static func _stops(stops: Array) -> String:
	var text := ""
	for stop in stops:
		text += "<stop offset=\"%s\" stop-color=\"%s\" stop-opacity=\"%s\"/>" % [_n(stop[0]), stop[1], _n(stop[2])]
	return text

static func _linear(id: String, stops: Array, x1 := 0.0, y1 := 0.0, x2 := 0.0, y2 := 1.0) -> String:
	return "<linearGradient id=\"%s\" x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\">%s</linearGradient>" % [id, _n(x1), _n(y1), _n(x2), _n(y2), _stops(stops)]

static func _radial(id: String, stops: Array, cx := 0.5, cy := 0.5, r := 0.5) -> String:
	return "<radialGradient id=\"%s\" cx=\"%s\" cy=\"%s\" r=\"%s\">%s</radialGradient>" % [id, _n(cx), _n(cy), _n(r), _stops(stops)]

static func _rect(x: float, y: float, w: float, h: float, rx: float, fill: String, extra := "") -> String:
	return "<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" rx=\"%s\" fill=\"%s\"%s/>" % [_n(x), _n(y), _n(w), _n(h), _n(rx), fill, extra]

# ------------------------------------------------------------------ terrain

## Seamless 16-unit terrain textures: ground, brick, steel, water, forest, ice.
static func texture(kind: String, p: Dictionary) -> String:
	var body := ""
	var defs := ""
	match kind:
		"ground":
			body = _rect(0, 0, 16, 16, 0, p.ground)
			for x in [0, 8]:
				for y in [0, 8]:
					body += _rect(x + 0.35, y + 0.35, 7.3, 7.3, 1.2, p.ground_tile)
			body += "<circle cx=\"16\" cy=\"16\" r=\"0.45\" fill=\"%s\"/>" % p.ground_dot
		"brick":
			defs = _linear("b", [[0, p.brick_hi, 1], [0.35, p.brick, 1], [1, p.brick_lo, 1]])
			body = _rect(0, 0, 16, 16, 0, p.mortar)
			var gap := 0.28
			for row in 8:
				var y := row * 2
				var offset := 0 if row % 2 == 0 else -2
				for x in range(offset, 16, 4):
					body += _rect(x + gap, y + gap, 4 - 2 * gap, 2 - 2 * gap, 0.45, "url(#b)")
				if offset != 0:
					body += _rect(14 + gap, y + gap, 4 - 2 * gap, 2 - 2 * gap, 0.45, "url(#b)")
		"steel":
			defs = _linear("s", [[0, p.steel_hi, 1], [0.25, p.steel, 1], [1, p.steel_lo, 1]], 0, 0, 1, 1)
			defs += _linear("sh", [[0, "#ffffff", 0], [0.45, "#ffffff", 0], [0.5, "#ffffff", 0.28], [0.58, "#ffffff", 0], [1, "#ffffff", 0]], 0, 0, 1, 1)
			body = _rect(0, 0, 16, 16, 0, p.steel_lo)
			for x in [0, 8]:
				for y in [0, 8]:
					body += _rect(x + 0.3, y + 0.3, 7.4, 7.4, 0.9, "url(#s)")
					body += _rect(x + 1.4, y + 1.4, 5.2, 5.2, 0.6, p.steel)
					body += _rect(x + 1.4, y + 1.4, 5.2, 5.2, 0.6, "url(#sh)")
					for rivet in [Vector2(1, 1), Vector2(7, 1), Vector2(1, 7), Vector2(7, 7)]:
						body += "<circle cx=\"%s\" cy=\"%s\" r=\"0.38\" fill=\"%s\" opacity=\"0.85\"/>" % [_n(x + rivet.x), _n(y + rivet.y), p.steel_rivet]
		"water":
			defs = _linear("w", [[0, p.water_hi, 1], [1, p.water, 1]])
			body = _rect(0, 0, 16, 16, 0, "url(#w)")
			var rows := [2.5, 6.5, 10.5, 14.5]
			for row in rows.size():
				var shift: int = (row % 2) * 4
				for start in [-8, 0, 8]:
					var x: float = start + shift
					body += "<path d=\"M%s %s q 1.4 -1.1 2.8 0\" fill=\"none\" stroke=\"%s\" stroke-width=\"0.55\" stroke-linecap=\"round\" opacity=\"0.75\"/>" % [_n(x + 0.6), _n(rows[row]), p.water_wave]
		"forest":
			defs = _radial("f", [[0, p.forest_hi, 1], [0.6, p.forest, 1], [1, p.forest_lo, 1]], 0.38, 0.35, 0.65)
			body = _rect(0, 0, 16, 16, 0, p.forest_lo)
			var blobs := [[2.2, 2.4, 2.6], [6.2, 1.8, 2.4], [10.3, 2.6, 2.7], [14.2, 2.0, 2.4],
				[3.6, 6.4, 2.7], [8.2, 6.0, 2.6], [12.4, 6.6, 2.7],
				[1.6, 10.3, 2.5], [5.8, 10.6, 2.8], [10.2, 10.0, 2.6], [14.4, 10.6, 2.5],
				[3.4, 14.4, 2.6], [7.8, 14.2, 2.5], [12.2, 14.6, 2.7]]
			for dx in [-16, 0, 16]:
				for dy in [-16, 0, 16]:
					for blob in blobs:
						body += "<circle cx=\"%s\" cy=\"%s\" r=\"%s\" fill=\"url(#f)\"/>" % [_n(blob[0] + dx), _n(blob[1] + dy), _n(blob[2])]
		"ice":
			defs = _linear("i", [[0, p.ice_hi, 1], [1, p.ice, 1]], 0, 0, 1, 1)
			body = _rect(0, 0, 16, 16, 0, "url(#i)")
			for x in [0, 8]:
				for y in [0, 8]:
					body += _rect(x + 0.25, y + 0.25, 7.5, 7.5, 0.6, "none", " stroke=\"%s\" stroke-width=\"0.35\" opacity=\"0.6\"" % p.ice_lo)
					body += "<path d=\"M%s %s L%s %s\" stroke=\"#ffffff\" stroke-width=\"0.6\" stroke-linecap=\"round\" opacity=\"0.8\"/>" % [_n(x + 1.5), _n(y + 5.5), _n(x + 5.5), _n(y + 1.5)]
					body += "<path d=\"M%s %s L%s %s\" stroke=\"#ffffff\" stroke-width=\"0.35\" stroke-linecap=\"round\" opacity=\"0.6\"/>" % [_n(x + 3.5), _n(y + 6.5), _n(x + 6.5), _n(y + 3.5)]
	return _svg(16, 16, body, defs)

# ------------------------------------------------------------------ sprites

## A 16-unit tank facing north: SHAPE from SHAPES, LOOK from COLORWAYS and
## tread animation STEP 0 or 1.
static func tank(shape_name: String, look: String, step: int) -> String:
	var way: Array = COLORWAYS[look]
	var hi: String = way[1]
	var lo: String = way[2]
	var shape: Dictionary = SHAPES[shape_name]
	var defs := _linear("h", [[0, hi, 1], [0.4, way[0], 1], [1, lo, 1]], 0, 0, 1, 1)
	defs += _radial("t", [[0, hi, 1], [0.55, way[3], 1], [1, lo, 1]], 0.4, 0.38, 0.62)
	defs += _linear("br", [[0, "#3a4150", 1], [0.5, "#5b6578", 1], [1, "#323846", 1]], 0, 0, 1, 0)
	var body := ""
	for x in [0.9, 11.6]:
		body += _rect(x, 1.6, 3.5, 13, 1.2, "#353c4a")
		for i in 9:
			body += _rect(x + 0.45, 2.2 + fmod(i * 1.5 + step * 0.75, 12.6), 2.6, 0.6, 0.25, "#6b7488")
		body += _rect(x, 1.6, 3.5, 13, 1.2, "none", " stroke=\"#11141a\" stroke-width=\"0.35\"")
	var hull: Array = shape.hull
	var hx: float = hull[0]
	var hy: float = hull[1]
	var hw: float = hull[2]
	var hh: float = hull[3]
	if shape.get("nose", false):
		body += "<path d=\"M%s %s Q%s %s %s %s L%s %s Q%s %s %s %s L%s %s Q%s %s %s %s L%s %s Q%s %s %s %s Z\" fill=\"url(#h)\"/>" % [
			_n(hx), _n(hy + 2), _n(hx), _n(hy), _n(hx + 2), _n(hy - 0.6), _n(hx + hw - 2), _n(hy - 0.6),
			_n(hx + hw), _n(hy), _n(hx + hw), _n(hy + 2), _n(hx + hw), _n(hy + hh - 1.5),
			_n(hx + hw), _n(hy + hh), _n(hx + hw - 1.5), _n(hy + hh), _n(hx + 1.5), _n(hy + hh),
			_n(hx), _n(hy + hh), _n(hx), _n(hy + hh - 1.5)]
	else:
		body += _rect(hx, hy, hw, hh, 1.9, "url(#h)")
	if shape.get("plates", false):
		body += _rect(hx + 0.6, hy + hh - 2.4, hw - 1.2, 1.6, 0.6, lo, " opacity=\"0.65\"")
		body += _rect(hx + 0.6, hy + 0.7, hw - 1.2, 1.2, 0.5, hi, " opacity=\"0.45\"")
	var barrel: Array = shape.barrel
	var top: float = barrel[1]
	var twin: bool = shape.get("twin", false)
	var width: float = 1.3 if twin else barrel[0]
	for cx in ([6.3, 8.7] if twin else [8.0]):
		body += _rect(cx - width / 2, top, width, 8.5 - top, 0.55, "url(#br)")
		if shape.get("brake", false):
			body += _rect(cx - width / 2 - 0.35, top, width + 0.7, 1.3, 0.4, "#2b313d")
		else:
			body += _rect(cx - width / 2, top, width, 0.8, 0.35, "#2b313d")
	var r: float = shape.turret
	body += "<circle cx=\"8\" cy=\"9\" r=\"%s\" fill=\"url(#t)\"/>" % _n(r)
	body += "<circle cx=\"8\" cy=\"9\" r=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"0.35\" opacity=\"0.8\"/>" % [_n(r), lo]
	body += "<circle cx=\"8.3\" cy=\"9.7\" r=\"%s\" fill=\"%s\" opacity=\"0.55\"/>" % [_n(r * 0.33), lo]
	return _svg(16, 16, body, defs)

## Named sprites: base, ruin, shell, shadow, blast16-N, blast32-N,
## sparkle-N, shield-N, bonus-KIND, mark and cursor-N.
static func sprite(name: String, p: Dictionary) -> String:
	var parts := name.split("-")
	match parts[0]:
		"base", "ruin":
			var defs := _linear("pl", [[0, p.plinth_hi, 1], [1, p.plinth, 1]])
			defs += _linear("em", [[0, p.emblem_hi, 1], [0.5, p.emblem, 1], [1, p.emblem_lo, 1]])
			var body := _rect(0.8, 0.8, 14.4, 14.4, 2.6, "url(#pl)")
			body += _rect(0.8, 0.8, 14.4, 14.4, 2.6, "none", " stroke=\"#ffffff\" stroke-opacity=\"0.12\" stroke-width=\"0.4\"")
			if parts[0] == "base":
				body += "<path d=\"M8 3.2 L9.3 5.2 L12.9 4.4 L11.6 7.4 L13.6 8.6 L10.3 9.4 L9.2 12.6 L8 11.4 L6.8 12.6 L5.7 9.4 L2.4 8.6 L4.4 7.4 L3.1 4.4 L6.7 5.2 Z\" fill=\"url(#em)\"/>"
				body += "<circle cx=\"8\" cy=\"6.9\" r=\"1.15\" fill=\"#ffffff\" opacity=\"0.55\"/>"
			else:
				body += "<path d=\"M3 12 L5.5 8 L7.5 10.5 L9.5 6.5 L13 12 Z\" fill=\"%s\"/>" % p.ruin_hi
				body += "<path d=\"M4 13 L7 10.8 L10.5 13 Z\" fill=\"%s\"/>" % p.ruin
				body += "<path d=\"M5 4 L7.5 6.5 M11 3.5 L9 6 M8 2.5 L8 5\" stroke=\"#000000\" stroke-opacity=\"0.45\" stroke-width=\"0.5\"/>"
			return _svg(16, 16, body, defs)
		"shell":
			var defs := _radial("g", [[0, p.shell_glow, 0.9], [0.5, p.shell_glow, 0.35], [1, p.shell_glow, 0]])
			var body := "<ellipse cx=\"3\" cy=\"3\" rx=\"3\" ry=\"3\" fill=\"url(#g)\"/>"
			body += _rect(2.2, 1.4, 1.6, 3.2, 0.8, p.shell_core)
			return _svg(6, 6, body, defs)
		"shadow":
			var defs := _radial("s", [[0, "#000000", 0.5], [0.65, "#000000", 0.32], [1, "#000000", 0]])
			return _svg(18, 18, _rect(0, 0, 18, 18, 5, "url(#s)"), defs)
		"blast16", "blast32":
			var stage := int(parts[1])
			var size := 16.0 if parts[0] == "blast16" else 32.0
			var r: float = [3.2, 5.8, 7.6, 6.4][stage] * size / 16.0
			var a: float = [1.0, 0.95, 0.8, 0.5][stage]
			var defs := _radial("x", [[0, "#ffffff", a], [0.25, "#fff2b0", a], [0.5, "#ffb347", a * 0.9], [0.78, "#f05a3a", a * 0.6], [1, "#7a2a20", 0]])
			return _svg(size, size, "<circle cx=\"%s\" cy=\"%s\" r=\"%s\" fill=\"url(#x)\"/>" % [_n(size / 2), _n(size / 2), _n(r)], defs)
		"sparkle":
			var r: float = [2.0, 4.0, 6.0, 4.0][int(parts[1])]
			var defs := _radial("k", [[0, "#ffffff", 1], [0.4, "#9ee7ff", 0.8], [1, "#4cc3ff", 0]])
			var body := "<circle cx=\"8\" cy=\"8\" r=\"%s\" fill=\"url(#k)\"/>" % _n(r * 0.8)
			body += "<path d=\"M8 %s L8.7 7.3 L%s 8 L8.7 8.7 L8 %s L7.3 8.7 L%s 8 L7.3 7.3 Z\" fill=\"#ffffff\" opacity=\"0.9\"/>" % [_n(8 - r), _n(8 + r), _n(8 + r), _n(8 - r)]
			return _svg(16, 16, body, defs)
		"shield":
			var edge := 0.7 if parts[1] == "1" else 0.45
			var defs := _radial("sh", [[0, "#7fe0ff", 0], [0.78, "#7fe0ff", 0.08], [0.92, "#bff1ff", edge], [1, "#7fe0ff", 0]])
			return _svg(18, 18, "<circle cx=\"9\" cy=\"9\" r=\"9\" fill=\"url(#sh)\"/>", defs)
		"bonus":
			var defs := _linear("bg", [[0, "#ff8aa0", 1], [1, "#e0335a", 1]])
			defs += _radial("gl", [[0, "#ffffff", 0.45], [1, "#ffffff", 0]], 0.35, 0.3, 0.6)
			var body := _rect(1, 1.6, 14, 13, 3, "#000000", " opacity=\"0.25\"")
			body += _rect(1, 1, 14, 13, 3, "url(#bg)") + _rect(1, 1, 14, 13, 3, "url(#gl)")
			return _svg(16, 16, body + BONUS_ICONS[parts[1]], defs)
		"mark":
			var body := _rect(0.8, 0.8, 6.4, 6.4, 1.4, "none", " stroke=\"%s\" stroke-width=\"1.4\"" % p.mark)
			body += "<path d=\"M2.8 2.8 L5.2 5.2 M5.2 2.8 L2.8 5.2\" stroke=\"%s\" stroke-width=\"1.1\" stroke-linecap=\"round\"/>" % p.mark
			return _svg(8, 8, body)
		"cursor":
			var size := 8.0 * int(parts[1])
			var body := _rect(0.6, 0.6, size - 1.2, size - 1.2, 1.6, "none", " stroke=\"%s\" stroke-width=\"1.6\" stroke-opacity=\"0.7\"" % p.cursor_edge)
			body += _rect(0.6, 0.6, size - 1.2, size - 1.2, 1.6, "none", " stroke=\"%s\" stroke-width=\"0.9\"" % p.cursor)
			return _svg(size, size, body)
	push_error("Iron Tide: unknown sprite " + name)
	return _svg(1, 1, "")

# ------------------------------------------------------------------ text

## Width in units of MESSAGE drawn with font pixels of SIZE units.
static func text_width(message: String, size: float) -> float:
	return message.length() * 6.0 * size - size

static func _glyphs(message: String, x0: float, y0: float, size: float, fill: String, rounded: bool) -> String:
	var body := ""
	var x := x0
	var cell := size * (0.86 if rounded else 1.0)
	var inset := (size - cell) / 2.0
	for glyph in message:
		if FONT.has(glyph):
			var rows: Array = FONT[glyph]
			for row in 7:
				var bits: String = rows[row]
				for column in 5:
					if bits[column] == "1":
						body += _rect(x + column * size + inset, y0 + row * size + inset, cell, cell, cell * 0.3 if rounded else 0.0, fill)
		x += 6.0 * size
	return body

## MESSAGE in font pixels of SIZE units with a soft drop shadow, in colour
## token TONE.
static func label(message: String, size: float, tone: String, p: Dictionary) -> String:
	var w := text_width(message, size) + size
	var h := 8.0 * size
	var body := "<g opacity=\"0.6\">%s</g>" % _glyphs(message, size * 0.5, size * 0.5, size, p.text_shadow, false)
	body += _glyphs(message, 0, 0, size, p[tone], false)
	return _svg(w, h, body)

## A rounded banner panel holding MESSAGE in colour token TONE.
static func banner(message: String, size: float, tone: String, p: Dictionary) -> String:
	var pad := size * 4.0
	var w := text_width(message, size) + pad * 2.0
	var h := 7.0 * size + pad * 1.6
	var body := _rect(1.2, 2.2, w - 2.4, h - 2.4, size * 2.2, "#000000", " opacity=\"0.28\"")
	body += _rect(1, 1, w - 2.4, h - 2.4, size * 2.2, p.panel, " opacity=\"%s\"" % _n(p.panel_opacity))
	body += _rect(1, 1, w - 2.4, h - 2.4, size * 2.2, "none", " stroke=\"%s\" stroke-opacity=\"0.14\" stroke-width=\"0.5\"" % p.panel_edge)
	var x := pad - 1.2
	var y := (h - 7.0 * size) / 2.0 - 0.7
	body += "<g opacity=\"0.5\">%s</g>" % _glyphs(message, x + size * 0.4, y + size * 0.4, size, p.text_shadow, true)
	body += _glyphs(message, x, y, size, p[tone], true)
	return _svg(w, h, body)
