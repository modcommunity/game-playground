class_name PlaygroundSpectate
extends Node

## Watching somebody else build, or fight, or drive into a wall.
##
## [b]A sandbox is the one place where watching is not about being dead.[/b] The
## interesting thing on a physics-sandbox server is usually what somebody else is making,
## and the answer to "what is that noise in the corner" is a camera. So the policy here
## is the loosest of the three games that have one: anybody, alive or dead, may watch
## anybody, and roaming is on — a free camera is how you look at a contraption from the
## outside, which is the whole reason to look at one.
##
## It tightens the moment the arena is on. A living player watching a living one while
## they are shooting at each other is a wallhack, and `PlaygroundArena` turning on is
## exactly the moment that stops being a sandbox.

const CHANNEL := "playground.spectate"

var game: Playground = null

## The arena, when the module has built one. Null on a plain sandbox.
##
## Held rather than reached for through the game: the arena lives on the module, beside
## this, and a layer that went looking for it through `Playground` would be a layer that
## found nothing — which reads as "nobody is ever dead" rather than as a missing wire.
var arena: PlaygroundArena = null

var manager: DotSpectatorManager = null


func setup(p_game: Playground) -> DotResult:
	game = p_game

	manager = DotSpectatorManager.new()
	manager.name = "SpectatorManager"
	manager.authoritative = game.authoritative
	manager.rules = _rules(false)
	manager.participants_fn = _participants
	# The side they are actually on, not a constant.
	#
	# dot-spectate keys teams by [code]int[/code] and treats 0 as "no team". A hardcoded
	# 1 made everybody — including somebody on the spectator side — a team-mate of
	# everybody, which is what `force_camera` reads as permission to watch. The stack is
	# built before anything can spectate, and 0 is the honest answer while it is not.
	manager.team_fn = func(key: String) -> int:
		return game.player_stack.team_index_of(key) if game.player_stack != null else 0
	manager.alive_fn = _alive
	manager.pose_fn = _pose_of
	add_child(manager)

	var res := manager.setup()
	if not res.ok:
		return res.wrap("playground spectate")

	if not game.player_removed.is_connected(_on_player_removed):
		game.player_removed.connect(_on_player_removed)

	return DotResult.success(null)


func _rules(fighting: bool) -> DotSpectatorRules:
	var rules := DotSpectatorRules.new()
	rules.force_camera = 1 if fighting else 0
	rules.allow_while_alive = not fighting
	rules.allow_roaming = not fighting
	rules.cycle_includes_dead = not fighting
	rules.death_cam_ticks = int(1.0 * float(game.tick_rate)) if fighting else 0
	rules.freeze_cam_ticks = int(1.0 * float(game.tick_rate)) if fighting else 0
	rules.chase_distance = 4.5
	rules.chase_height = 1.4
	rules.history_ticks = 4 * game.tick_rate
	return rules


## The arena went on or off. The camera policy is not the same question afterwards.
##
## Re-derived rather than patched field by field: a policy assembled by three separate
## assignments in two places is a policy that disagrees with itself the first time
## somebody adds a fourth field.
func set_fighting(fighting: bool) -> void:
	if manager == null:
		return
	manager.rules = _rules(fighting)
	var res := manager.setup()
	if not res.ok:
		DotLog.warn(CHANNEL, "the camera policy was refused", {
			"why": res.error.message
		})


func _participants() -> PackedStringArray:
	var out := PackedStringArray()
	var ids: Array = game.players.keys()
	ids.sort()
	for id: Variant in ids:
		out.append(String(id))
	return out


func _alive(key: String) -> bool:
	if arena == null or not arena.enabled:
		return true
	var health := arena.health_of(StringName(key))
	return health == null or health.alive


func _pose_of(key: String) -> Transform3D:
	var player: PlaygroundPlayer = game.players.get(StringName(key), null)
	if player == null or player.controller == null:
		return Transform3D.IDENTITY
	var state := player.controller.state
	var basis := Basis.from_euler(
		Vector3(deg_to_rad(state.pitch), deg_to_rad(state.yaw), 0.0)
	)
	return Transform3D(basis, state.position + Vector3(0.0, 1.6, 0.0))


func tick(_delta: float) -> void:
	if manager != null:
		manager.advance(game.current_tick())


func watch(viewer: StringName, target: StringName) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Spectating is not set up.")
	return manager.watch(String(viewer), String(target))


func next_target(viewer: StringName) -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Spectating is not set up.")
	return manager.next_target(String(viewer))


func stop(viewer: StringName) -> void:
	if manager != null:
		manager.stop(String(viewer))


func is_spectating(viewer: StringName) -> bool:
	return manager != null and manager.is_spectating(String(viewer))


func camera_for(viewer: StringName) -> Transform3D:
	return manager.camera_of(String(viewer)) if manager != null \
		else Transform3D.IDENTITY


func target_of(viewer: StringName) -> StringName:
	if manager == null:
		return &""
	return StringName(manager.view(String(viewer)).target)


func on_death(victim: StringName, at: Vector3, by: StringName) -> void:
	if manager != null:
		manager.on_death(String(victim), at, String(by), game.current_tick())


func on_spawn(id: StringName) -> void:
	if manager != null:
		manager.on_spawn(String(id))


func _on_player_removed(id: StringName) -> void:
	if manager != null:
		manager.on_leave(String(id))


func describe() -> Dictionary:
	return manager.describe() if manager != null else {}


func describe_lines() -> PackedStringArray:
	if manager == null:
		return PackedStringArray(["spectate: not set up"])
	return manager.describe_lines()
