extends Node

const Playground := preload("../game/playground.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundPlayer := preload("../game/playground_player.gd")
const PlaygroundPlayerStack := preload("../game/playground_player_stack.gd")

## The player stack, run against a real sandbox rather than against a stub.
##
## [codeblock]
## godot --headless --path . res://examples/headless_stack.tscn
## [/codeblock]
##
## [b]A three-hundred-line player layer with no suite that named it.[/b] game-arena got
## one; this game did not, so the roster, the sides, the classes, the collision layout,
## the spawn director, the view switch and the character were exercised only as far as
## `setup()` running inside somebody else's test.
##
## Four of the sections are about things that were built and never used:
##
## - the collision layout, which named its layers in the inspector and put no body on one;
## - the spawn director, which was fed every start on the map and asked nothing;
## - the view switch, which is the only place `DotTpsController` runs in this family;
## - the character, which is the only implementation of `DotPlayerCharVisual` anywhere.

const CHECKS := 40

var _passed := 0
var _failed := 0
var _section_count := 0

const SECTIONS := 5

var _game: Playground = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	print("playground player stack")
	print("")

	if not await _build():
		get_tree().quit(1)
		return

	_test_physics_layout()
	_test_roster_sides_and_classes()
	_test_spawn_director()
	await _test_view_switch()
	_test_character()

	print("")
	print("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		print("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _build() -> bool:
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.initial_map = &"pg_lobby"
	config.map_seconds = 0.0

	_game = Playground.new()
	_game.name = "Playground"
	_game.config = config
	add_child(_game)

	for _i in range(120):
		await get_tree().process_frame

		if _game.maps != null and _game.maps.current != null:
			break

	if _game.player_stack == null:
		print("  FAIL  the sandbox set up without a player stack")
		return false

	return true


func _stack() -> PlaygroundPlayerStack:
	return _game.player_stack


# --- 1 ----------------------------------------------------------------------

func _test_physics_layout() -> void:
	_section("the collision layout is worn, not just named")

	var physics := _stack().physics
	_check(physics != null, "the stack built a physics world")

	if physics == null:
		return

	_check(physics.layout != null, "with a sandbox layout on it")
	_check(
		physics.layout.has_layer(&"held_prop") and physics.layout.has_layer(&"frozen_prop"),
		"which is the preset with a held and a frozen prop layer in it — the two rows "
		+ "that only a sandbox has a use for"
	)

	var mask := _stack().player_collision_mask()
	_check(mask != 1, "the player mask is the layout's rather than the default of 1")
	_check(
		mask & physics.layout.layer_mask(&"prop") != 0,
		"and includes props, which is what stops a player walking through a crate"
	)
	_check(
		mask & physics.layout.layer_mask(&"npc") != 0,
		"and NPCs, which were indistinguishable from the floor before this"
	)

	var level := _game.current_map_node()
	var on_world := 0

	if level != null:
		for child in level.get_children():
			var body := child as CollisionObject3D

			if body != null and body.collision_layer == physics.layout.layer_mask(&"world"):
				on_world += 1

	_check(on_world > 0, "and the level's geometry is on the world layer")


# --- 2 ----------------------------------------------------------------------

func _test_roster_sides_and_classes() -> void:
	_section("a player reaches the roster, a side and a class")

	var player := _game.add_player(&"ada", "Ada")
	_check(player != null, "a player joins")

	_check(_stack().roster.has_player("ada"), "and lands in the session roster")
	_check(_stack().teams.has_player("ada"), "and on a side")
	_check(_stack().team_index_of("ada") > 0, "with a real team number for dot-spectate")
	_check(
		_stack().team_index_of("nobody") == 0,
		"and 0 for a stranger, which is what dot-spectate reads as 'no team'"
	)

	var def := _stack().classes.def_of("ada")
	_check(def != null, "and a class")

	if def == null:
		return

	# The bridge that had no caller in any game.
	var health := StubHealth.new()
	var tunables := DotFpsTunables.new()
	var base := DotFpsTunables.new()
	_check(DotPlayerClassApply.to_health(def, health) > 0, "whose numbers can be applied")
	_check(
		is_equal_approx(health.max_health, def.max_health), "to a health component"
	)
	_check(
		DotPlayerClassApply.to_movement(def, tunables, base) > 0, "and to movement"
	)
	_check(
		is_equal_approx(tunables.max_speed, base.max_speed * def.move_speed_scale),
		"as a scale off an untouched base, so applying it twice does not compound"
	)
	health.free()


# --- 3 ----------------------------------------------------------------------

func _test_spawn_director() -> void:
	_section("the director chooses, and is asked")

	var spawns := _stack().spawns
	_check(spawns.sites().size() > 0, "the director has the map's starts in it")

	var res := _stack().choose_start(&"ada", DotTimerTrack.MAIN)
	_check(res.ok, "and answers")

	if not res.ok:
		return

	var choice := res.value as DotSpawnChoice
	_check(
		int(choice.site.meta.get("track", -1)) == DotTimerTrack.MAIN,
		"with the site belonging to the track asked for"
	)

	var map := _game.current_map_node()
	_check(
		choice.transform.origin.distance_to(map.spawn_for(DotTimerTrack.MAIN)) < 0.01,
		"at the place the map itself would have said"
	)
	_check(
		absf(
			rad_to_deg(choice.transform.basis.get_euler().y)
			- map.spawn_yaw_for(DotTimerTrack.MAIN)
		) < 0.5,
		"facing the way the map says — the site holds radians and DotFpsState.yaw is "
		+ "degrees, and the conversion was missing at both ends"
	)

	# And that spawning a player actually goes through it.
	var player: PlaygroundPlayer = _game.players.get(&"ada")
	_game.spawn_player(&"ada")
	_check(
		player.controller.state.position.distance_to(choice.transform.origin) < 0.01,
		"and spawn_player puts the player there, which is the call that was missing"
	)


# --- 4 ----------------------------------------------------------------------

func _test_view_switch() -> void:
	_section("first person, third person, and the handover")

	var player: PlaygroundPlayer = _game.players.get(&"ada")
	player.samples_input = true
	_check(player.build_view_switch(), "a local player gets a view switch")
	_check(player.tps != null, "with a third-person controller under it")

	# [b]One frame, and the reason is the switch's own.[/b]
	# `DotPlayerControllerSwitch._ready` defers `_activate_default` deliberately: a
	# sibling controller's `_ready` has not necessarily run when the switch's does, so
	# its `controller_id` may still be the scene's default and the switch would register
	# it under the wrong name. Reading `view_mode()` on the same frame as the build
	# therefore reads the empty id, which is neither controller.
	await get_tree().process_frame

	_check(player.view_mode() == &"fp", "and opens in first person, which is what a tool wants")

	# The handover, which is the reason the switch exists at all.
	var at := player.global_position
	_check(player.set_view_mode(true) == &"tp", "switching to third person takes")
	_check(
		player.global_position.distance_to(at) < 0.01,
		"without teleporting the player, which is what carrying position across means"
	)
	_check(player.set_view_mode(false) == &"fp", "and back again")

	_check(
		player.tps.rig != null and player.tps.rig.arm != null,
		"the rig has a spring arm"
	)


# --- 5 ----------------------------------------------------------------------

func _test_character() -> void:
	_section("the body other people see")

	var player: PlaygroundPlayer = _game.players.get(&"ada")
	_check(player.character != null, "a player has a character visual")

	if player.character == null:
		return

	_check(
		player.character is DotPlayerCharVisual,
		"which is dot-player-char's own abstract node — the one that had no "
		+ "implementation in any project in this family"
	)
	_check(player.character.rig != null, "with a rig")
	_check(
		player.character.attachment(&"head") != null,
		"whose mounts resolve, so a hat or a weapon has somewhere to go"
	)

	_check(player.anim != null, "and a locomotion driver")

	if player.anim == null:
		return

	# [b]Driven with an explicit motion rather than through the controller.[/b] The
	# locomotion machine keys off `on_floor` before it looks at speed at all — that is
	# what stops a staircase reading as a hop — so a freshly spawned player who has not
	# landed yet reports the same air state at every speed, and a check that went through
	# the controller would be measuring whether the player had fallen rather than whether
	# the state machine works.
	var _resting := player.anim.drive({
		"speed": 0.0, "vertical": 0.0, "on_floor": true, "alive": true,
	}, 0.1)
	var idle := player.anim.state()

	var moving := player.anim.drive({
		"speed": 8.0, "vertical": 0.0, "on_floor": true, "alive": true,
	}, 0.1)
	_check(moving != null, "the driver answers with a clip for a moving player")
	_check(
		player.anim.state() != idle,
		"and the locomotion state changes when the player moves"
	)

	# And the game's own call path, which is what feeds it in a real tick.
	player.drive_character(0.1)
	_check(
		player.anim.state() != &"",
		"driving it from the game's tick leaves a state rather than erroring"
	)

	_check(
		not player.character.is_body_visible(),
		"and the body is hidden in first person, because a player must not see the "
		+ "inside of their own head"
	)
	var _tp := player.set_view_mode(true)
	_check(
		player.character.is_body_visible(),
		"and shown again in third person, which is the whole of what set_shown is for"
	)

	_game.queue_free()


# --- Harness ---------------------------------------------------------------

## Stands in for a `DotHealth` without naming dot-combat, which this section does not need.
class StubHealth extends Object:
	var max_health: float = 1.0
	var max_armour: float = 0.0


func _section(title: String) -> void:
	_section_count += 1
	print("")
	print("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("   ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
