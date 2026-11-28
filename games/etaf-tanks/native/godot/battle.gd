extends RefCounted
## Battle City-style rules: terrain, tanks, shells, bonuses and stage flow.
## SPDX-License-Identifier: GPL-3.0-or-later
##
## Coordinates are NES-scale pixels: 4 px terrain cells, 8 px map blocks and
## 16 px tanks, base and bonuses. The owner advances `step' on a fixed clock.

const SUB := 4
const BLOCK := 8
const SIZE := 16
const EMPTY := 0
const BRICK := 1
const STEEL := 2
const WATER := 3
const FOREST := 4
const ICE := 5
const VECTORS := [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)]
const FACINGS := ["n", "e", "s", "w"]
const KINDS := ["basic", "fast", "power", "armor"]
const KIND_NAMES := ["普通车", "快速车", "重炮车", "装甲车"]
const KIND_SPEED := [30.0, 60.0, 36.0, 30.0]
const KIND_SHELL := [120.0, 120.0, 240.0, 120.0]
const KIND_ARMOUR := [1, 1, 1, 4]
const KIND_POINTS := [100, 200, 300, 400]
const BONUSES := ["helmet", "clock", "shovel", "star", "grenade", "tank"]
const BONUS_NAMES := ["头盔：护盾 10 秒", "时钟：敌军冻结 10 秒", "铁锹：基地钢墙 20 秒",
	"星星：主炮升级", "手雷：全歼场上敌车", "战车：生命 +1"]
const PLAYER_SPEED := 46.0
const SHELL_SLOW := 120.0
const SHELL_FAST := 240.0
const EXTRA_LIFE := 20000
const DIFFICULTIES := {
	"easy": {"name": "简单", "lives": 5, "cap": 4, "interval": 3.6, "fire": 0.45, "aggression": 0.15, "upgrade": 0.0},
	"normal": {"name": "普通", "lives": 3, "cap": 5, "interval": 2.8, "fire": 0.8, "aggression": 0.35, "upgrade": 0.08},
	"hard": {"name": "困难", "lives": 3, "cap": 7, "interval": 2.0, "fire": 1.3, "aggression": 0.6, "upgrade": 0.25},
}

class Tank:
	var id := 0
	var enemy := false
	var kind := 0
	var pos := Vector2.ZERO
	var facing := 0
	var armour := 1
	var bonus := false
	var shells := 0
	var cooldown := 0.0
	var speed := 0.0
	var moving := false
	var travel := 0.0
	var flash := 0.0
	var shield := 0.0
	var drive := 0.0
	var latched := false
	var slide := 0.0
	var turn_timer := 0.0
	var blocked := 0.0

class Shell:
	var pos := Vector2.ZERO
	var dir := 0
	var speed := 0.0
	var owner: Tank
	var enemy := false
	var power := false
	var alive := true

var rng := RandomNumberGenerator.new()
var map := {}
var blocks_w := 0
var blocks_h := 0
var cw := 0
var ch := 0
var pw := 0.0
var ph := 0.0
var cells := PackedByteArray()
var dirty_cells := PackedInt32Array()
var terrain_reset := true
var base_pos := Vector2.ZERO
var base_alive := true
var fort_cells := PackedInt32Array()
var fortify := 0.0
var freeze := 0.0
var player: Tank = null
var player_spawn := Vector2.ZERO
var spawn_points: Array = []
var spawn_cursor := 0
var enemies: Array = []
var shells: Array = []
var spawns: Array = []
var bonus = null
var effects: Array = []
var roster: Array = []
var roster_bonus: Array = []
var next_enemy := 0
var spawn_timer := 0.0
var lives := 3
var score := 0
var star := 0
var next_life := EXTRA_LIFE
var kills := [0, 0, 0, 0]
var respawn := -1.0
var clock := 0.0
var anim := 0.0
var outcome := ""
var outcome_timer := 0.0
var difficulty := "normal"
var stage := 1
var rules := {}
var game_speed := 1.0
var player_speed := 1.0
var hold_first := 0.28
var hold_repeat := 0.12
var latch := false
var events: Array = []
var serial := [0]
var next_id := 1
var start_carry := {}
var shots := 0

func setup(parsed: Dictionary, number: int, level: String, carry: Dictionary, seed: int) -> void:
	map = parsed
	stage = number
	difficulty = level
	rules = DIFFICULTIES[level].duplicate()
	var loop := (number - 1) / 20
	var depth := float(mini(number - 1, 40))
	rules.interval = maxf(1.0, rules.interval * (1.0 - 0.012 * depth))
	rules.fire = rules.fire * (1.0 + 0.025 * depth)
	rules.cap = rules.cap + (1 if number >= 10 else 0) + loop
	rules.upgrade = minf(0.6, rules.upgrade + 0.1 * loop)
	rng.seed = seed
	blocks_w = parsed.width
	blocks_h = parsed.height
	cw = blocks_w * 2
	ch = blocks_h * 2
	pw = float(blocks_w * BLOCK)
	ph = float(blocks_h * BLOCK)
	cells.resize(cw * ch)
	for by in blocks_h:
		for bx in blocks_w:
			var code: int = parsed.terrain[by * blocks_w + bx]
			for oy in 2:
				for ox in 2:
					cells[(by * 2 + oy) * cw + bx * 2 + ox] = code
	terrain_reset = true
	dirty_cells.clear()
	base_pos = Vector2(parsed.base) * BLOCK
	base_alive = true
	fort_cells.clear()
	for by in range(parsed.base.y - 1, parsed.base.y + 3):
		for bx in range(parsed.base.x - 1, parsed.base.x + 3):
			var inside: bool = bx >= parsed.base.x and bx < parsed.base.x + 2 and by >= parsed.base.y and by < parsed.base.y + 2
			if inside or bx < 0 or by < 0 or bx >= blocks_w or by >= blocks_h:
				continue
			for oy in 2:
				for ox in 2:
					fort_cells.append((by * 2 + oy) * cw + bx * 2 + ox)
	fortify = 0.0
	freeze = 0.0
	player_spawn = Vector2(parsed.player) * BLOCK
	spawn_points = []
	for point in parsed.spawns:
		spawn_points.append(Vector2(point) * BLOCK)
	spawn_cursor = 0
	enemies = []
	shells = []
	spawns = []
	bonus = null
	effects = []
	roster = []
	for kind in 4:
		for count in parsed.counts[kind]:
			roster.append(kind)
	_shuffle_roster()
	roster_bonus = []
	for index in roster.size():
		roster_bonus.append(index % 7 == 3)
	next_enemy = 0
	spawn_timer = 0.3
	start_carry = carry.duplicate()
	lives = int(carry.get("lives", rules.lives))
	score = int(carry.get("score", 0))
	star = int(carry.get("star", 0))
	next_life = int(carry.get("next_life", (score / EXTRA_LIFE + 1) * EXTRA_LIFE))
	kills = [0, 0, 0, 0]
	respawn = -1.0
	clock = 0.0
	anim = 0.0
	outcome = ""
	outcome_timer = 0.0
	player = null
	_spawn_player()

func _shuffle_roster() -> void:
	# Upgrade some light tanks on harder settings, then mix the column so that
	# heavier armour arrives progressively instead of in one block.
	for index in roster.size():
		if roster[index] == 0 and rng.randf() < rules.upgrade:
			roster[index] = rng.randi_range(1, 3)
	var mixed: Array = []
	var pool := roster.duplicate()
	pool.sort()
	while not pool.is_empty():
		var reach := mini(pool.size(), 4)
		mixed.append(pool.pop_at(rng.randi_range(0, reach - 1)))
	roster = mixed

func event(title: String, detail: String, kind := "info") -> void:
	serial[0] += 1
	events.append({"id": serial[0], "title": title, "detail": detail, "kind": kind})
	if events.size() > 4:
		events.pop_front()

# ---------------------------------------------------------------- geometry

func _overlap(a: Vector2, b: Vector2, size_b := float(SIZE)) -> bool:
	return a.x < b.x + size_b - 0.01 and b.x < a.x + SIZE - 0.01 and a.y < b.y + size_b - 0.01 and b.y < a.y + SIZE - 0.01

func _tanks() -> Array:
	var all: Array = enemies.duplicate()
	if player != null:
		all.append(player)
	return all

func fits(tank: Tank, at: Vector2) -> bool:
	if at.x < -0.001 or at.y < -0.001 or at.x + SIZE > pw + 0.001 or at.y + SIZE > ph + 0.001:
		return false
	var x0 := int(floorf(at.x / SUB))
	var x1 := int(floorf((at.x + SIZE - 0.01) / SUB))
	var y0 := int(floorf(at.y / SUB))
	var y1 := int(floorf((at.y + SIZE - 0.01) / SUB))
	for cy in range(maxi(y0, 0), mini(y1, ch - 1) + 1):
		var row := cy * cw
		for cx in range(maxi(x0, 0), mini(x1, cw - 1) + 1):
			var code := cells[row + cx]
			if code == BRICK or code == STEEL or code == WATER:
				return false
	if _overlap(at, base_pos):
		return false
	for other in enemies:
		if other != tank and _overlap(at, other.pos) and not _overlap(tank.pos, other.pos):
			return false
	if player != null and player != tank and _overlap(at, player.pos) and not _overlap(tank.pos, player.pos):
		return false
	return true

## Whether AT is free of terrain, the base and every tank.
func vacant(at: Vector2) -> bool:
	var probe := Tank.new()
	probe.pos = Vector2(-1000, -1000)
	return fits(probe, at)

func _drive(tank: Tank, distance: float) -> float:
	if distance <= 0.0:
		return 0.0
	var vector: Vector2 = VECTORS[tank.facing]
	var tried := distance
	while tried > 0.0:
		if fits(tank, tank.pos + vector * tried):
			tank.pos += vector * tried
			tank.travel += tried
			return tried
		tried = snappedf(tried - 0.25, 0.25) if tried > 0.25 else 0.0
	# Close a sub-pixel gap so tanks sit flush against cover.
	var flush := tank.pos
	if vector.x > 0:
		flush.x = floorf(tank.pos.x + 0.999)
	elif vector.x < 0:
		flush.x = floorf(tank.pos.x)
	elif vector.y > 0:
		flush.y = floorf(tank.pos.y + 0.999)
	else:
		flush.y = floorf(tank.pos.y)
	if flush != tank.pos and fits(tank, flush):
		tank.pos = flush
	return 0.0

func turn(tank: Tank, direction: int) -> void:
	if direction == tank.facing:
		return
	if direction % 2 != tank.facing % 2:
		# Turning onto the other axis snaps to the half-tile grid, so tanks line
		# up with corridors instead of catching on brick corners.
		var snapped := tank.pos
		if direction % 2 == 0:
			snapped.x = roundf(tank.pos.x / BLOCK) * BLOCK
		else:
			snapped.y = roundf(tank.pos.y / BLOCK) * BLOCK
		if snapped != tank.pos and fits(tank, snapped):
			tank.pos = snapped
	tank.facing = direction

func _cell_at(point: Vector2) -> int:
	var cx := int(floorf(point.x / SUB))
	var cy := int(floorf(point.y / SUB))
	if cx < 0 or cy < 0 or cx >= cw or cy >= ch:
		return -1
	return cells[cy * cw + cx]

func _on_ice(tank: Tank) -> bool:
	return _cell_at(tank.pos + Vector2(8, 8)) == ICE

# ---------------------------------------------------------------- units

func _make_tank(enemy: bool, kind: int, at: Vector2) -> Tank:
	var tank := Tank.new()
	tank.id = next_id
	next_id += 1
	tank.enemy = enemy
	tank.kind = kind
	tank.pos = at
	tank.facing = 2 if enemy else 0
	tank.armour = KIND_ARMOUR[kind] if enemy else 1
	tank.speed = KIND_SPEED[kind] if enemy else PLAYER_SPEED
	tank.turn_timer = rng.randf_range(0.6, 1.6)
	return tank

func _spawn_player() -> void:
	player = _make_tank(false, 0, player_spawn)
	player.shield = 3.0
	respawn = -1.0

func _area_free(at: Vector2) -> bool:
	for tank in _tanks():
		if _overlap(at, tank.pos):
			return false
	return true

func _update_spawns(delta: float) -> void:
	if next_enemy < roster.size() and outcome.is_empty():
		spawn_timer -= delta
		if spawn_timer <= 0.0 and enemies.size() + spawns.size() < rules.cap:
			var point: Vector2 = spawn_points[spawn_cursor % spawn_points.size()]
			spawn_cursor += 1
			if roster_bonus[next_enemy]:
				bonus = null
			spawns.append({"pos": point, "timer": 0.9, "kind": roster[next_enemy], "bonus": roster_bonus[next_enemy]})
			next_enemy += 1
			spawn_timer = rules.interval
	var waiting: Array = []
	for item in spawns:
		item.timer -= delta
		if item.timer > 0.0 or not _area_free(item.pos):
			waiting.append(item)
			continue
		var tank := _make_tank(true, item.kind, item.pos)
		tank.bonus = item.bonus
		enemies.append(tank)
	spawns = waiting
	if player == null and respawn >= 0.0:
		respawn -= delta
		if respawn < 0.0 and lives > 0 and _area_free(player_spawn):
			_spawn_player()
		elif respawn < 0.0:
			respawn = 0.0 if lives > 0 else -1.0

# ---------------------------------------------------------------- player input

func drive(direction: int) -> void:
	if player == null:
		return
	var continuing := player.facing == direction and (player.drive > 0.0 or player.latched)
	turn(player, direction)
	if latch:
		player.latched = true
	else:
		player.drive = maxf(player.drive, hold_repeat) if continuing else hold_first

func aim(direction: int) -> void:
	if player == null:
		return
	stop()
	turn(player, direction)

func stop() -> void:
	if player != null:
		player.drive = 0.0
		player.latched = false

func fire(tank: Tank) -> bool:
	if tank == null or tank.cooldown > 0.0:
		return false
	var limit := 2 if not tank.enemy and star >= 2 else 1
	if tank.shells >= limit:
		return false
	var shell := Shell.new()
	shell.dir = tank.facing
	shell.pos = tank.pos + Vector2(8, 8) + VECTORS[tank.facing] * 6.0
	shell.owner = tank
	shell.enemy = tank.enemy
	shell.speed = KIND_SHELL[tank.kind] if tank.enemy else (SHELL_FAST if star >= 1 else SHELL_SLOW)
	shell.power = not tank.enemy and star >= 3
	tank.shells += 1
	tank.cooldown = 0.08
	if not tank.enemy:
		shots += 1
	shells.append(shell)
	return true

func can_fire() -> bool:
	return player != null and player.cooldown <= 0.0 and player.shells < (2 if star >= 2 else 1)

# ---------------------------------------------------------------- simulation

func step(delta: float) -> void:
	clock += delta
	anim += delta
	if freeze > 0.0:
		freeze = maxf(0.0, freeze - delta)
	if fortify > 0.0:
		fortify -= delta
		if fortify <= 0.0:
			fortify = 0.0
			_fortify(BRICK)
	_update_spawns(delta)
	_update_player(delta)
	for tank in enemies.duplicate():
		_update_enemy(tank, delta)
	_update_shells(delta)
	_update_bonus(delta)
	var live: Array = []
	for effect in effects:
		effect.timer -= delta
		if effect.timer > 0.0:
			live.append(effect)
	effects = live
	if outcome.is_empty() and base_alive and next_enemy >= roster.size() and enemies.is_empty() and spawns.is_empty():
		outcome = "cleared"
		outcome_timer = 2.5
		event("全歼敌军", "第 %d 关敌车已全部击毁。" % stage, "success")
	elif not outcome.is_empty():
		outcome_timer -= delta

func finished() -> bool:
	return not outcome.is_empty() and outcome_timer <= 0.0

func _update_player(delta: float) -> void:
	if player == null:
		return
	player.cooldown -= delta
	player.flash -= delta
	if player.shield > 0.0:
		player.shield = maxf(0.0, player.shield - delta)
	if outcome == "lost":
		player.moving = false
		return
	var wanted := player.latched
	if player.drive > 0.0:
		player.drive -= delta
		wanted = true
	var distance := PLAYER_SPEED * player_speed * delta
	if wanted:
		player.slide = 0.3 if _on_ice(player) else 0.0
		_drive(player, distance)
	elif player.slide > 0.0:
		player.slide -= delta
		_drive(player, distance)
	player.moving = wanted or player.slide > 0.0
	if bonus != null and _overlap(player.pos, bonus.pos):
		_collect(bonus.kind)
		bonus = null

func _toward(from: Vector2, target: Vector2) -> Array:
	var choices: Array = []
	var gap := target - from
	if absf(gap.y) > 4.0:
		choices.append(2 if gap.y > 0 else 0)
	if absf(gap.x) > 4.0:
		choices.append(1 if gap.x > 0 else 3)
	return choices

func _choose(tank: Tank) -> void:
	var weights := [1.0, 1.0, 1.0, 1.0]
	weights[2] += 0.6
	for direction in _toward(tank.pos, base_pos):
		weights[direction] += rules.aggression * 4.0
	if player != null:
		for direction in _toward(tank.pos, player.pos):
			weights[direction] += 0.8
	for direction in 4:
		if not fits(tank, tank.pos + VECTORS[direction] * 2.0):
			weights[direction] *= 0.08
	if tank.blocked > 0.0:
		weights[tank.facing] *= 0.05
	var total := 0.0
	for weight in weights:
		total += weight
	var pick := rng.randf() * total
	var chosen := 0
	for direction in 4:
		pick -= weights[direction]
		if pick <= 0.0:
			chosen = direction
			break
	turn(tank, chosen)
	tank.turn_timer = rng.randf_range(0.7, 2.6)
	tank.blocked = 0.0

func _aligned(tank: Tank, target: Vector2) -> bool:
	var centre := tank.pos + Vector2(8, 8)
	var other := target + Vector2(8, 8)
	match tank.facing:
		0:
			return absf(centre.x - other.x) < 7.0 and other.y < centre.y
		1:
			return absf(centre.y - other.y) < 7.0 and other.x > centre.x
		2:
			return absf(centre.x - other.x) < 7.0 and other.y > centre.y
		_:
			return absf(centre.y - other.y) < 7.0 and other.x < centre.x

func _update_enemy(tank: Tank, delta: float) -> void:
	tank.cooldown -= delta
	tank.flash -= delta
	if freeze > 0.0:
		tank.moving = false
		return
	var expected := tank.speed * delta
	var moved := _drive(tank, expected)
	tank.moving = moved > 0.0
	tank.blocked = tank.blocked + delta if moved < expected * 0.5 else 0.0
	tank.turn_timer -= delta
	if tank.turn_timer <= 0.0 or tank.blocked > 0.15:
		if tank.blocked > 0.15 and rng.randf() < 0.45:
			fire(tank)
		_choose(tank)
	if tank.shells == 0 and tank.cooldown <= 0.0:
		var chance: float = rules.fire * delta
		if (player != null and _aligned(tank, player.pos)) or (base_alive and _aligned(tank, base_pos)):
			chance *= 6.0
		if rng.randf() < chance and fire(tank):
			tank.cooldown = rng.randf_range(0.5, 1.4)

func _update_shells(delta: float) -> void:
	for shell in shells:
		var travel: float = shell.speed * delta
		while travel > 0.0 and shell.alive:
			var length := minf(travel, 2.0)
			travel -= length
			shell.pos += VECTORS[shell.dir] * length
			_contact(shell)
	var flying: Array = []
	for shell in shells:
		if shell.alive:
			flying.append(shell)
	shells = flying

func _retire(shell: Shell, blast: int) -> void:
	shell.alive = false
	if shell.owner != null:
		shell.owner.shells = maxi(0, shell.owner.shells - 1)
	if blast > 0:
		effects.append({"kind": "spark", "pos": shell.pos, "timer": 0.18, "total": 0.18})

func _hits(shell: Shell, at: Vector2) -> bool:
	return absf(shell.pos.x - (at.x + 8.0)) < 10.0 and absf(shell.pos.y - (at.y + 8.0)) < 10.0

func _contact(shell: Shell) -> void:
	if shell.pos.x < 0.0 or shell.pos.y < 0.0 or shell.pos.x >= pw or shell.pos.y >= ph:
		shell.pos = shell.pos.clamp(Vector2.ZERO, Vector2(pw - 1, ph - 1))
		_retire(shell, 1)
		return
	for other in shells:
		if other != shell and other.alive and other.enemy != shell.enemy and other.pos.distance_squared_to(shell.pos) < 16.0:
			_retire(other, 0)
			_retire(shell, 0)
			return
	if shell.enemy:
		if player != null and _hits(shell, player.pos):
			_retire(shell, 0)
			if player.shield <= 0.0 and outcome != "lost":
				_destroy_player()
			return
		for tank in enemies:
			if tank != shell.owner and _hits(shell, tank.pos):
				_retire(shell, 0)
				return
	else:
		for tank in enemies:
			if _hits(shell, tank.pos):
				_retire(shell, 1)
				_damage(tank)
				return
	if shell.pos.x >= base_pos.x and shell.pos.x < base_pos.x + SIZE and shell.pos.y >= base_pos.y and shell.pos.y < base_pos.y + SIZE:
		_retire(shell, 1)
		if base_alive:
			_destroy_base()
		return
	_impact(shell)

func _impact(shell: Shell) -> void:
	var vector: Vector2 = VECTORS[shell.dir]
	var lead: Vector2 = shell.pos + vector * 1.99
	var vertical := shell.dir % 2 == 0
	var layer := int(floorf((lead.y if vertical else lead.x) / SUB))
	var axis := shell.pos.x if vertical else shell.pos.y
	var hit := false
	for lateral in range(int(floorf((axis - 2.0) / SUB)), int(floorf((axis + 1.99) / SUB)) + 1):
		var code := _layer_cell(vertical, layer, lateral)
		hit = hit or code == BRICK or code == STEEL
	if not hit:
		return
	var step := 1 if shell.dir == 1 or shell.dir == 2 else -1
	var depth := 2 if shell.power else 1
	var low := int(floorf((axis - 8.0) / SUB))
	var high := int(floorf((axis + 7.99) / SUB))
	for offset in depth:
		for lateral in range(low, high + 1):
			var cell := _layer_index(vertical, layer + offset * step, lateral)
			if cell < 0:
				continue
			if cells[cell] == BRICK or (cells[cell] == STEEL and shell.power):
				cells[cell] = EMPTY
				dirty_cells.append(cell)
	_retire(shell, 1)

func _layer_index(vertical: bool, layer: int, lateral: int) -> int:
	var cx := lateral if vertical else layer
	var cy := layer if vertical else lateral
	if cx < 0 or cy < 0 or cx >= cw or cy >= ch:
		return -1
	return cy * cw + cx

func _layer_cell(vertical: bool, layer: int, lateral: int) -> int:
	var index := _layer_index(vertical, layer, lateral)
	return -1 if index < 0 else cells[index]

func _damage(tank: Tank) -> void:
	if tank.bonus:
		tank.bonus = false
		_drop_bonus()
	tank.armour -= 1
	if tank.armour > 0:
		tank.flash = 0.2
		return
	enemies.erase(tank)
	kills[tank.kind] += 1
	_award(KIND_POINTS[tank.kind], tank.pos)
	effects.append({"kind": "blast", "pos": tank.pos + Vector2(8, 8), "timer": 0.45, "total": 0.45})

func _award(points: int, at: Vector2) -> void:
	score += points
	effects.append({"kind": "points", "pos": at + Vector2(8, 8), "timer": 0.9, "total": 0.9, "text": str(points)})
	while score >= next_life:
		next_life += EXTRA_LIFE
		lives += 1
		event("奖励生命", "得分达到 %d，生命 +1。" % (next_life - EXTRA_LIFE), "success")

func _destroy_player() -> void:
	effects.append({"kind": "blast", "pos": player.pos + Vector2(8, 8), "timer": 0.45, "total": 0.45})
	player = null
	lives -= 1
	star = 0
	if lives > 0:
		respawn = 1.2
		event("我方战车被击毁", "剩余生命 %d，主炮等级重置。" % lives, "danger")
	else:
		respawn = -1.0
		_lose("生命耗尽")

func _destroy_base() -> void:
	base_alive = false
	effects.append({"kind": "blast", "pos": base_pos + Vector2(8, 8), "timer": 0.6, "total": 0.6})
	_lose("基地被摧毁")

func _lose(reason: String) -> void:
	if outcome == "lost":
		return
	outcome = "lost"
	outcome_timer = 2.5
	event("战斗失败", reason + "。", "danger")

func _drop_bonus() -> void:
	var at := Vector2.ZERO
	for attempt in 40:
		at = Vector2(rng.randi_range(0, blocks_w - 2), rng.randi_range(0, blocks_h - 2)) * BLOCK
		if _overlap(at, base_pos):
			continue
		var open := true
		for oy in 4:
			for ox in 4:
				var code := cells[(int(at.y) / SUB + oy) * cw + int(at.x) / SUB + ox]
				open = open and code != STEEL and code != WATER
		if open:
			break
	bonus = {"kind": rng.randi_range(0, BONUSES.size() - 1), "pos": at, "timer": 25.0}
	event("奖励出现", BONUS_NAMES[bonus.kind] + "。", "info")

func _update_bonus(delta: float) -> void:
	if bonus == null:
		return
	bonus.timer -= delta
	if bonus.timer <= 0.0:
		bonus = null

func _collect(kind: int) -> void:
	_award(500, bonus.pos)
	match BONUSES[kind]:
		"helmet":
			player.shield = 10.0
		"clock":
			freeze = 10.0
		"shovel":
			fortify = 20.0
			_fortify(STEEL)
		"star":
			star = mini(3, star + 1)
		"grenade":
			for tank in enemies.duplicate():
				enemies.erase(tank)
				kills[tank.kind] += 1
				effects.append({"kind": "blast", "pos": tank.pos + Vector2(8, 8), "timer": 0.45, "total": 0.45})
		"tank":
			lives += 1
	event("拾取奖励", BONUS_NAMES[kind] + "。", "success")

func _fortify(code: int) -> void:
	for cell in fort_cells:
		var at := Vector2((cell % cw) * SUB, (cell / cw) * SUB)
		var covered := false
		for tank in _tanks():
			covered = covered or (at.x < tank.pos.x + SIZE and tank.pos.x < at.x + SUB and at.y < tank.pos.y + SIZE and tank.pos.y < at.y + SUB)
		if not covered and cells[cell] != code:
			cells[cell] = code
			dirty_cells.append(cell)

# ---------------------------------------------------------------- reports

func remaining() -> int:
	return roster.size() - next_enemy

func field() -> int:
	return enemies.size() + spawns.size()

func block_rows() -> Array:
	var rows: Array = []
	for by in blocks_h:
		var row := ""
		for bx in blocks_w:
			var mask := 0
			for oy in 2:
				for ox in 2:
					mask |= 1 << cells[(by * 2 + oy) * cw + bx * 2 + ox]
			var symbol := "."
			if mask & (1 << STEEL):
				symbol = "@"
			elif mask & (1 << BRICK):
				symbol = "#"
			elif mask & (1 << WATER):
				symbol = "~"
			elif mask & (1 << FOREST):
				symbol = "*"
			elif mask & (1 << ICE):
				symbol = "="
			if bx >= int(base_pos.x) / BLOCK and bx < int(base_pos.x) / BLOCK + 2 and by >= int(base_pos.y) / BLOCK and by < int(base_pos.y) / BLOCK + 2:
				symbol = "H" if base_alive else "X"
			row += symbol
		rows.append(row)
	return rows

func _unit(tank: Tank) -> Dictionary:
	return {"id": tank.id, "kind": "enemy" if tank.enemy else "player",
		"type": KINDS[tank.kind] if tank.enemy else "player", "facing": FACINGS[tank.facing],
		"x": snappedf(tank.pos.x / BLOCK, 0.125), "y": snappedf(tank.pos.y / BLOCK, 0.125),
		"armour": tank.armour, "bonus": tank.bonus, "shield": tank.shield > 0.0}

func world() -> Dictionary:
	var units: Array = []
	if player != null:
		units.append(_unit(player))
	for tank in enemies:
		units.append(_unit(tank))
	var flying: Array = []
	for shell in shells:
		flying.append({"x": snappedf(shell.pos.x / BLOCK, 0.125), "y": snappedf(shell.pos.y / BLOCK, 0.125),
			"owner": "enemy" if shell.enemy else "player"})
	var prize = null
	if bonus != null:
		prize = {"kind": BONUSES[bonus.kind], "x": bonus.pos.x / BLOCK, "y": bonus.pos.y / BLOCK}
	return {"terrain": block_rows(), "units": units, "shells": flying, "bonus": prize}

# ---------------------------------------------------------------- snapshots

func snapshot(text: String) -> Dictionary:
	var hostile: Array = []
	for tank in enemies:
		hostile.append({"kind": tank.kind, "x": tank.pos.x, "y": tank.pos.y, "facing": tank.facing,
			"armour": tank.armour, "bonus": tank.bonus})
	var codes := ""
	for code in cells:
		codes += str(code)
	return {"format": "iron-tide/2", "map": text, "stage": stage, "difficulty": difficulty,
		"lives": lives, "score": score, "star": star, "next_life": next_life, "kills": kills.duplicate(),
		"roster": roster.duplicate(), "bonus_flags": roster_bonus.duplicate(), "next_enemy": next_enemy,
		"clock": clock, "base": base_alive, "fortify": fortify, "freeze": freeze, "cells": codes,
		"player": null if player == null else {"x": player.pos.x, "y": player.pos.y, "facing": player.facing, "shield": player.shield},
		"enemies": hostile,
		"bonus": null if bonus == null else {"kind": bonus.kind, "x": bonus.pos.x, "y": bonus.pos.y, "timer": bonus.timer},
		"start": start_carry.duplicate()}

static func _integer(value, low: int, high: int) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and float(value) == floorf(float(value)) and int(value) >= low and int(value) <= high

static func _number(value, low: float, high: float) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and float(value) >= low and float(value) <= high

## Restore DATA over a battle already set up from DATA's map. Return an error
## message; on error the caller discards this battle object.
func restore(data: Dictionary) -> String:
	for key in ["lives", "score", "star", "next_life", "next_enemy"]:
		if not _integer(data.get(key), 0, 100000000):
			return "存档字段无效：" + key
	if data.lives < 1 or data.star > 3 or data.next_life <= data.score:
		return "存档的生命、星级或奖励分无效"
	if not data.get("roster") is Array or not data.get("bonus_flags") is Array or data.roster.size() != data.bonus_flags.size() or data.roster.size() > 60 or data.roster.is_empty():
		return "存档的敌军编队无效"
	for kind in data.roster:
		if not _integer(kind, 0, 3):
			return "存档的敌车类型无效"
	for flag in data.bonus_flags:
		if not flag is bool:
			return "存档的奖励标记无效"
	if data.next_enemy > data.roster.size():
		return "存档的出场进度无效"
	if not data.get("kills") is Array or data.kills.size() != 4:
		return "存档的击毁统计无效"
	for count in data.kills:
		if not _integer(count, 0, 60):
			return "存档的击毁统计无效"
	if not _number(data.get("clock"), 0.0, 1e7) or not _number(data.get("fortify"), 0.0, 20.0) or not _number(data.get("freeze"), 0.0, 10.0) or not data.get("base") is bool or not data.base:
		return "存档的计时或基地状态无效"
	if not data.get("cells") is String or data.cells.length() != cw * ch:
		return "存档的地形长度与地图不符"
	for index in data.cells.length():
		var code: int = data.cells.unicode_at(index) - 48
		if code < 0 or code > 5:
			return "存档的地形含无效格"
		if code != cells[index] and not (code == EMPTY and cells[index] in [BRICK, STEEL]) and not (index in fort_cells and code in [BRICK, STEEL]):
			return "存档的地形与地图不一致"
	if not data.get("enemies") is Array or data.enemies.size() > 12:
		return "存档的敌车无效"
	var restored := PackedByteArray()
	restored.resize(cw * ch)
	for index in data.cells.length():
		restored[index] = data.cells.unicode_at(index) - 48
	cells = restored
	roster = data.roster.map(func(kind): return int(kind))
	roster_bonus = data.bonus_flags.duplicate()
	next_enemy = int(data.next_enemy)
	lives = int(data.lives)
	score = int(data.score)
	star = int(data.star)
	next_life = int(data.next_life)
	kills = data.kills.map(func(count): return int(count))
	clock = float(data.clock)
	fortify = float(data.fortify)
	freeze = float(data.freeze)
	if data.get("start") is Dictionary:
		start_carry = {}
		for key in ["lives", "score", "star", "next_life"]:
			if _integer(data.start.get(key), 0, 100000000):
				start_carry[key] = int(data.start[key])
	player = null
	enemies = []
	if data.get("player") != null:
		var saved = data.player
		if not saved is Dictionary or not _number(saved.get("x"), 0.0, pw - SIZE) or not _number(saved.get("y"), 0.0, ph - SIZE) or not _integer(saved.get("facing"), 0, 3) or not _number(saved.get("shield"), 0.0, 10.0):
			return "存档的我方战车无效"
		var tank := _make_tank(false, 0, Vector2(saved.x, saved.y))
		tank.facing = int(saved.facing)
		tank.shield = float(saved.shield)
		if not vacant(tank.pos):
			return "存档的我方战车位于障碍内"
		player = tank
	else:
		respawn = 0.5
	for saved in data.enemies:
		if not saved is Dictionary or not _integer(saved.get("kind"), 0, 3) or not _number(saved.get("x"), 0.0, pw - SIZE) or not _number(saved.get("y"), 0.0, ph - SIZE) or not _integer(saved.get("facing"), 0, 3) or not _integer(saved.get("armour"), 1, KIND_ARMOUR[int(saved.kind)]) or not saved.get("bonus") is bool:
			return "存档的敌车无效"
		var tank := _make_tank(true, int(saved.kind), Vector2(saved.x, saved.y))
		tank.facing = int(saved.facing)
		tank.armour = int(saved.armour)
		tank.bonus = saved.bonus
		if not vacant(tank.pos):
			return "存档的敌车位置重叠或位于障碍内"
		enemies.append(tank)
	bonus = null
	if data.get("bonus") != null:
		var saved = data.bonus
		if not saved is Dictionary or not _integer(saved.get("kind"), 0, BONUSES.size() - 1) or not _number(saved.get("x"), 0.0, pw - SIZE) or not _number(saved.get("y"), 0.0, ph - SIZE) or not _number(saved.get("timer"), 0.0, 25.0):
			return "存档的奖励无效"
		bonus = {"kind": int(saved.kind), "pos": Vector2(saved.x, saved.y), "timer": float(saved.timer)}
	shells = []
	spawns = []
	effects = []
	spawn_timer = 1.0
	terrain_reset = true
	dirty_cells.clear()
	if fortify > 0.0:
		_fortify(STEEL)
	return ""
