extends Node

## Runs the whole playground: a bot surfs a map from start to finish, its run is
## timed and filed, props are spawned and moved, and the map is changed underneath.
##
## [codeblock]
## godot --headless --path . res://examples/headless_playground.tscn
## [/codeblock]
##
## [b]This is the only thing in the family that runs the joins between these five
## addons.[/b] Each has its own suite and each passes with the others absent, and the
## family's own history says that proves very little: every bug that has cost a day
## here was in a seam — a bridge reconciling on top of another bridge, a client
## message keyed on the wrong id, a value computed and consumed by nothing. So this
## test is about the joins, not about the parts:
##
## - the timer is ticked from the movement loop, with the position the move produced;
## - a style change moves both halves together;
## - a zone's effect reaches the player through the game and not through the timer;
## - a record is filed, scored, and reaches the leaderboard;
## - a map change tears down runs, props and geometry in an order that survives;
## - a prop can be spawned, held, and freed without leaking a node.
##
## The bot's input is a scripted [DotFpsCommand] rather than a device, which is the
## whole reason [DotFpsSampler] is a separate object.

const TICK := 1.0 / 128.0

## Preloaded rather than named: the built-in maps have no `class_name`, deliberately
## — they are content, and a map that reserved a global identifier in every consuming
## project is the thing dot-map exists to avoid.
const PgLobby := preload("res://maps/pg_lobby.gd")

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var playground: Playground = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("playground — headless integration")
	print("")

	playground = Playground.new()

	var config := PlaygroundConfig.new()
	# Records in memory: a headless run must not write into the user's data
	# directory, and a suite that did could not be run twice with the same result.
	config.records_directory = ""
	# No map on boot: the tests below load their own and would race a boot load.
	config.initial_map = &"pg_lobby"
	config.map_seconds = 0.0
	playground.config = config

	add_child(playground)

	# Two frames: the playground's own `_ready` awaits its first map change, so one
	# is not enough for it to have finished booting.
	await get_tree().process_frame
	await get_tree().process_frame

	await _test_boots()
	await _test_tick_rate_comes_from_the_engine()
	await _test_zone_file_matches_the_map()
	await _test_surf_run()
	await _test_styles()
	await _test_leaderboards()
	await _test_checkpoints()
	await _test_props()
	await _test_map_change()
	await _test_map_time_limit()
	await _test_props_are_built_from_their_definitions()
	await _test_entities_run_their_scripts()
	await _test_weapons()
	await _test_spawn_menu()
	await _test_the_sandbox_and_its_course()
	await _test_the_client_boots()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)


func _check_near(
	value: float, expected: float, epsilon: float, what: String
) -> void:
	_check(
		absf(value - expected) <= epsilon, what,
		"%.4f vs %.4f" % [value, expected]
	)


## Runs the simulation for [param ticks], driving [param id] with [param command].
##
## Commands are applied per tick and the physics is stepped per tick, which is what
## makes this reproducible: a test that awaited frames would run a different number of
## simulation ticks on a loaded machine.
func _drive(
	id: StringName, command: DotFpsCommand, ticks: int
) -> void:
	var player: PlaygroundPlayer = playground.players[id]

	for _i in range(ticks):
		player.controller.apply_command(command.duplicate_command())
		await get_tree().physics_frame


# --- Boot ------------------------------------------------------------------

func _test_boots() -> void:
	print("booting")

	_check(playground.maps != null, "the map session exists")
	_check(playground.timers != null, "the timer manager exists")
	_check(playground.props != null, "the prop spawner exists")
	_check(playground.boards != null, "the leaderboards exist")

	_check(
		playground.maps.catalogue.size() == 3,
		"three maps are in the catalogue",
		"%d" % playground.maps.catalogue.size()
	)
	_check(
		playground.maps.catalogue.problems().is_empty(),
		"and none of them has a problem",
		", ".join(playground.maps.catalogue.problems())
	)
	_check(
		playground.props.catalogue.problems().is_empty(),
		"and neither does the prop catalogue"
	)

	var loaded: DotResult = await playground.change_map(&"pg_surf_intro")
	_check(loaded.ok, "the surf map loads",
		loaded.error.message if not loaded.ok else "")
	_check(playground.current_map_node() != null, "and is a PlaygroundMap")

	var player := playground.add_player(&"bot", "Bot")
	_check(player != null, "a player joins")
	_check(player.timer != null, "and gets a timer")
	_check(
		player.timer.zones != null and player.timer.zones.map_id == &"pg_surf_intro",
		"bound to the map's zones"
	)

	# The zones themselves. A start with no end is the commonest thing wrong with a
	# hand-drawn zone file, and it is playable and unfinishable.
	var zones := player.timer.zones
	_check(zones.problems().is_empty(), "the map's zones are well formed",
		", ".join(zones.problems()))
	_check(
		zones.playable_tracks() == PackedInt32Array([DotTimerTrack.MAIN]),
		"and its main track can be run"
	)

	# The thin-zone check, at the speed a surfer actually reaches on this map.
	var thin := zones.thin_zones(40.0, playground.tick_rate)
	_check(
		thin.is_empty(),
		"and no zone is thin enough for a fast player to pass through",
		"%d thin" % thin.size()
	)

	await get_tree().physics_frame

	_check(
		player.global_position.distance_to(
			playground.current_map_node().spawn_for(DotTimerTrack.MAIN)
		) < 1.0,
		"and the player is at the map's spawn"
	)


func _test_tick_rate_comes_from_the_engine() -> void:
	print("the tick rate comes from the engine, which is what a server sets")

	# The chain: an operator writes `sv_tickrate` in server.cfg; dot-server writes
	# `Engine.physics_ticks_per_second`; the playground reads it; the timer manager
	# adopts it; and it lands on every record filed.
	#
	# Getting it wrong does not fail loudly — a timer counting 128 a second on a
	# server stepping 64 reports every run at twice its length, and nothing about
	# the run looks unusual — which is why this is a test rather than a comment.
	_check(
		playground.tick_rate == Engine.physics_ticks_per_second,
		"the playground counts in the engine's rate",
		"%d vs %d" % [playground.tick_rate, Engine.physics_ticks_per_second]
	)
	_check(
		playground.timers.tick_rate == playground.tick_rate,
		"and so does the timer manager",
		"%d vs %d" % [playground.timers.tick_rate, playground.tick_rate]
	)
	_check(
		playground.timers.tick_rate_matches_engine(),
		"so the two agree, which is the misconfiguration that is otherwise silent"
	)

	# And the record carries it, which is what settles a dispute afterwards.
	var run := DotTimerRun.make(0, &"normal", playground.timers.timer_for(&"bot").tick_interval()
		if playground.players.has(&"bot") else 1.0 / float(playground.tick_rate))
	run.begin(0.0)
	run.ticks = playground.tick_rate
	run.finish(0.0)

	var record := DotTimerRecord.from_run(run, &"m", &"p", "P")

	_check(
		record.tick_rate == playground.tick_rate,
		"a record is stamped with the rate it was measured at",
		"%d" % record.tick_rate
	)
	_check_near(record.time, 1.0, 0.01, "and its time is that rate's worth of ticks")


func _test_zone_file_matches_the_map() -> void:
	print("the shipped zone file matches the geometry")

	# A map's zones and its geometry are built from the same constants here, and a
	# written-out copy of them lives in maps/ to demonstrate the file route that a
	# DELIVERED map has to use. This is the check that the two have not drifted —
	# because a zone file drawn against geometry that has since moved is a
	# leaderboard nobody can compare, and nothing else would ever notice.
	var path := "res://maps/pg_surf_intro.zones.json"

	if not FileAccess.file_exists(path):
		_check(false, "the shipped zone file exists", path)
		return

	var loaded := DotTimerZoneSet.load_json(path)
	_check(loaded.ok, "the shipped zone file parses",
		loaded.error.message if not loaded.ok else "")

	if not loaded.ok:
		return

	var built := preload("res://maps/pg_surf_intro.gd").build_zones()

	_check(
		(loaded.value as DotTimerZoneSet).fingerprint() == built.fingerprint(),
		"and matches what the map builds",
		"%s vs %s" % [
			(loaded.value as DotTimerZoneSet).fingerprint(), built.fingerprint()
		]
	)


# --- A run -----------------------------------------------------------------

func _test_surf_run() -> void:
	print("a surf run, start to finish")

	var player: PlaygroundPlayer = playground.players[&"bot"]

	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var started := [0]
	var finished: Array[DotTimerRun] = []

	player.timer.run_started.connect(func(_run: DotTimerRun) -> void: started[0] += 1)
	player.timer.run_finished.connect(
		func(run: DotTimerRun) -> void: finished.append(run)
	)

	# Walk off the start platform and down the valley. The bot holds forward and
	# strafes, which on a surf ramp is what gains speed — see
	# DotFpsMotor.accelerate.
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	forward.yaw = 0.0

	await _drive(&"bot", forward, 200)

	_check(started[0] >= 1, "leaving the start zone begins a run", "%d" % started[0])
	_check(player.timer.run.is_running(), "and it is running")

	# Down the ramps. Not grounded, because the ramps are steeper than the player
	# can stand on — which is the whole of surf.
	var airborne := 0
	var top_speed := 0.0

	for i in range(1400):
		var command := DotFpsCommand.new()
		# Strafe alternately, turning with it, which is what a surfer does.
		var phase := (i / 90) % 2
		command.move = Vector2(1.0 if phase == 0 else -1.0, 0.0)
		command.yaw = wrapf(
			(-1.0 if phase == 0 else 1.0) * float(i % 90) * 0.35
			+ (0.0 if phase == 0 else -31.5),
			-180.0, 180.0
		)

		player.controller.apply_command(command)
		await get_tree().physics_frame

		if not player.controller.state.is_grounded():
			airborne += 1

		top_speed = maxf(top_speed, player.speed())

		if finished.size() > 0:
			break

	_check(
		airborne > 400,
		"most of the descent is spent not grounded, which is what surf is",
		"%d airborne ticks" % airborne
	)
	_check(top_speed > 12.0, "and the player reaches surf speed",
		"%.1f m/s" % top_speed)

	# Whether the bot happened to reach the finish is not the point — a scripted
	# strafe pattern is not a player. What has to be true is that the run was timed,
	# the statistics were folded in, and the machinery did not fall over.
	_check(
		player.controller.stats.jumps >= 0
			and player.controller.stats.ticks > 1000,
		"the movement statistics accumulated over the run",
		"%d ticks" % player.controller.stats.ticks
	)
	_check(player.controller.motor.stuck_ticks == 0,
		"and the collide-and-slide never ran out of iterations",
		"%d stuck" % player.controller.motor.stuck_ticks)
	_check(
		is_finite(player.controller.state.position.length()),
		"and the position stayed finite"
	)

	# Now finish it deliberately, by putting the player in the finish zone. The
	# route down is a movement question and is tested in dot-fps-controller; what is
	# under test HERE is that a crossing produces a timed, filed run.
	if finished.is_empty():
		var zones := player.timer.zones
		var finish := zones.first_of_kind(DotTimerZone.Kind.END, DotTimerTrack.MAIN)

		player.controller.state.position = finish.centre() + Vector3.UP * 0.5
		player.controller.state.velocity = Vector3(0.0, 0.0, -6.0)

		await _drive(&"bot", forward, 4)

	_check(finished.size() == 1, "the run finishes exactly once",
		"%d" % finished.size())

	if finished.size() == 1:
		_check(finished[0].time() > 0.0, "with a positive time",
			finished[0].formatted_time())
		_check(
			finished[0].status == DotTimerRun.Status.FINISHED,
			"and the run is in the finished state"
		)
		_check(
			finished[0].stats.has("jumps"),
			"and the movement statistics were folded into it",
			str(finished[0].stats.keys())
		)


func _test_styles() -> void:
	print("styles move both halves together")

	var player: PlaygroundPlayer = playground.players[&"bot"]

	_check(playground.set_player_style(&"bot", &"sideways"), "a style can be set")
	_check(
		player.movement_style != null and player.movement_style.id == &"sideways",
		"the movement half is on"
	)
	_check(
		player.timer.style != null and player.timer.style.id == &"sideways",
		"and so is the ranking half"
	)
	_check(
		player.controller.style != null
			and player.controller.style.id == &"sideways",
		"and the controller has it, which assigning the property alone would not do"
	)

	# The command filter is the visible half: sideways removes the forward key, and
	# it has to happen before the motor sees the command.
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)

	player.controller.apply_command(forward)

	_check_near(
		player.controller.current_command.move.y, 0.0, 0.0001,
		"and the forward key is filtered out of the command"
	)

	# A style change abandons a run, because half a run on each is a run on neither.
	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	playground.set_player_style(&"bot", &"low_gravity")

	_check(
		not player.timer.run.is_active(),
		"and changing style leaves no run in progress"
	)
	_check_near(
		player.controller.tunables.gravity, 10.0, 0.01,
		"low gravity halves the gravity the motor reads"
	)

	# Back to normal, and the base is restored rather than compounded — the reason
	# the controller keeps `_base_tunables`.
	playground.set_player_style(&"bot", &"normal")
	_check_near(
		player.controller.tunables.gravity, 20.0, 0.01,
		"and switching back restores it rather than halving it again"
	)


func _test_leaderboards() -> void:
	print("records reach the leaderboards")

	var scope := {
		"map": "pg_surf_intro",
		"track": "0",
		"style": "normal",
	}

	var page: DotResult = await playground.boards.page(&"fastest", scope)
	var rows: Array = page.value

	# The run above may or may not have been fast enough to clear the style's
	# minimum time, so this files one directly — what is under test is the path from
	# a record to a board, not the bot's driving.
	if rows.is_empty():
		await playground.boards.submit(
			&"fastest", scope, &"bot", "Bot", 42.5
		)
		page = await playground.boards.page(&"fastest", scope)
		rows = page.value

	_check(rows.size() >= 1, "there is a time on the board")

	if rows.size() >= 1:
		_check((rows[0] as DotLeaderboardEntry).rank == 1, "ranked first")

	# Faster than whatever is on top, rather than a fixed number: the bot's own time
	# depends on how the run above went, and a hard-coded 20 seconds made this test
	# pass or fail on the bot's driving instead of on the board's ordering.
	var beat := (rows[0] as DotLeaderboardEntry).value - 1.0

	await playground.boards.submit(&"fastest", scope, &"other", "Other", beat)

	page = await playground.boards.page(&"fastest", scope)
	rows = page.value

	_check(
		(rows[0] as DotLeaderboardEntry).player_id == &"other",
		"a faster time takes the top",
		String((rows[0] as DotLeaderboardEntry).player_id)
	)
	_check(
		(rows[1] as DotLeaderboardEntry).rank == 2,
		"and the ranks are rewritten"
	)

	# A different scope is a different board — the thing a canonical scope key
	# exists to guarantee.
	var other_scope := scope.duplicate()
	other_scope["style"] = "sideways"

	var other: DotResult = await playground.boards.page(&"fastest", other_scope)
	_check(
		(other.value as Array).is_empty(),
		"and another style's board is separate"
	)

	# The same scope built in a different order must be the SAME board.
	var reordered := {
		"style": "normal", "map": "pg_surf_intro", "track": "0",
	}
	var same: DotResult = await playground.boards.page(&"fastest", reordered)
	_check(
		(same.value as Array).size() == rows.size(),
		"while the same scope in a different order is the same board",
		"%d vs %d" % [(same.value as Array).size(), rows.size()]
	)


# --- Props -----------------------------------------------------------------

func _test_checkpoints() -> void:
	print("practice checkpoints, through the game")

	var player: PlaygroundPlayer = playground.players[&"bot"]
	var checkpoints := playground.timers.checkpoints_for(&"bot")

	_check(checkpoints != null, "a player has a checkpoint set")

	if checkpoints == null:
		return

	playground.spawn_player(&"bot")
	await get_tree().physics_frame

	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _drive(&"bot", forward, 120)

	var somewhere := player.controller.state.position

	checkpoints.save(
		somewhere,
		player.controller.state.velocity,
		player.controller.state.yaw,
		player.controller.state.pitch,
		player.controller.state.is_grounded()
	)

	_check(checkpoints.count() == 1, "a checkpoint is saved")

	await _drive(&"bot", forward, 120)

	_check(
		player.controller.state.position.distance_to(somewhere) > 1.0,
		"the player moves on"
	)

	var restored := checkpoints.load_current()
	_check(restored != null, "and the checkpoint can be restored")

	if restored != null:
		player.teleport(restored.position, restored.yaw)
		player.controller.state.velocity = restored.velocity

		await get_tree().physics_frame

		_check(
			player.controller.state.position.distance_to(somewhere) < 1.0,
			"putting them back where they saved it",
			"%.2f m away" % player.controller.state.position.distance_to(somewhere)
		)


func _test_props() -> void:
	print("props")

	var player: PlaygroundPlayer = playground.players[&"bot"]

	playground.props.limits.spawn_interval = 0.0

	var at := player.global_position + Vector3(0.0, 3.0, -4.0)
	var crate := playground.props.spawn(&"crate", &"bot", at)

	_check(crate != null, "a crate spawns")
	_check(playground.props.world_count() == 1, "and is counted")
	_check(
		crate != null and crate.node.get_parent() == playground.world,
		"under the world node the map is in"
	)

	# The physics gun. Grabbed directly rather than through a ray, because what is
	# under test here is the join — the gun, the spawner and the world — and not
	# Godot's raycast, which dot-props covers.
	player.phys_gun.held = crate
	crate.held_by = &"bot"
	player.phys_gun.hold_distance = 4.0

	var origin := player.eye_position()
	var aim := player.aim_direction()

	for _i in range(90):
		player.phys_gun.hold(origin, aim, Basis.IDENTITY, TICK)
		await get_tree().physics_frame

	var goal := origin + aim * player.phys_gun.hold_distance
	_check(
		crate.node.global_position.distance_to(goal) < 2.0,
		"a held crate follows the aim",
		"%.2f m away" % crate.node.global_position.distance_to(goal)
	)

	player.phys_gun.freeze_held()
	_check(crate.frozen, "and can be frozen in place")
	_check(player.phys_gun.held == null, "which lets go of it")

	# Undo, and then cleanup on leave.
	playground.props.spawn(&"barrel", &"bot", at)
	_check(playground.props.world_count() == 2, "a second prop spawns")
	_check(playground.props.undo(&"bot"), "and can be undone")
	_check(playground.props.world_count() == 1, "leaving the first")

	var node := crate.node

	playground.props.player_left(&"bot")

	_check(playground.props.world_count() == 0, "a departing player's props go")

	await get_tree().process_frame
	await get_tree().process_frame

	_check(not is_instance_valid(node), "and the node is actually freed")


# --- Changing maps ---------------------------------------------------------

func _test_map_change() -> void:
	print("changing map under a live player")

	var player: PlaygroundPlayer = playground.players[&"bot"]

	playground.spawn_player(&"bot")
	playground.props.limits.spawn_interval = 0.0
	playground.props.spawn(
		&"crate", &"bot", player.global_position + Vector3.UP * 3.0
	)

	# Start a run, so the change happens with everything in flight — a run in
	# progress, a prop in the world, and geometry about to be freed under both.
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _drive(&"bot", forward, 200)

	var was_running := player.timer.run.is_active()
	var props_before := playground.props.world_count()

	_check(props_before == 1, "a prop is in the world")

	var changed: DotResult = await playground.change_map(&"pg_bhop_intro")

	_check(changed.ok, "the map changes",
		changed.error.message if not changed.ok else "")
	_check(
		playground.maps.current.id == &"pg_bhop_intro",
		"and the session is on the new one"
	)
	_check(
		not player.timer.run.is_active(),
		"a run in progress is abandoned rather than carried across",
		"was running: %s" % was_running
	)
	_check(
		playground.props.world_count() == 0,
		"and the props are cleared with the geometry they stood on"
	)
	_check(
		player.timer.zones != null
			and player.timer.zones.map_id == &"pg_bhop_intro",
		"the timer is rebound to the new map's zones"
	)

	await get_tree().physics_frame

	_check(
		player.global_position.distance_to(
			playground.current_map_node().spawn_for(DotTimerTrack.MAIN)
		) < 2.0,
		"and the player is at the new map's spawn"
	)

	# And the bhop map is actually runnable: hold jump and forward, and the player
	# should hop rather than walk.
	var hopping := DotFpsCommand.new()
	hopping.move = Vector2(0.0, 1.0)
	hopping.set_button(DotFpsCommand.BUTTON_JUMP, true)

	player.controller.stats.reset()
	await _drive(&"bot", hopping, 400)

	_check(
		player.controller.stats.jumps >= 3,
		"holding jump on the bhop map produces hops",
		"%d jumps" % player.controller.stats.jumps
	)
	_check(
		player.controller.stats.perfect_jumps > 0,
		"and auto-hop makes them perfect",
		"%d/%d" % [
			player.controller.stats.perfect_jumps,
			player.controller.stats.measured_jumps
		]
	)


func _test_map_time_limit() -> void:
	print("a map that ends on its own")

	# A server that never changes map is not a server. The session says the map is
	# over; the playground decides what happens next — which here is the rotation.
	playground.maps.time_limit.duration = 60.0
	playground.maps.time_limit.warn_at = 10.0
	playground.maps.time_limit.start()

	var was := playground.maps.current.id

	var warned := [0]
	playground.maps.time_warning.connect(func(_left: float) -> void: warned[0] += 1)

	# Advanced through the game's own loop, so this exercises the wiring rather than
	# the time limit in isolation — which dot-map's own suite covers.
	for _i in range(70):
		playground.maps.advance(1.0)

	_check(warned[0] == 1, "the warning fires once", "%d" % warned[0])

	# The change is a coroutine started from a signal, so it lands a frame later.
	for _i in range(10):
		await get_tree().process_frame

	_check(
		playground.maps.current.id != was,
		"and the map changes when the clock runs out",
		"%s -> %s" % [String(was), String(playground.maps.current.id)]
	)
	_check(
		playground.maps.time_limit.running,
		"with the clock restarted on the new one"
	)

	# Rocking the vote.
	playground.maps.time_limit.duration = 3600.0
	playground.maps.time_limit.rtv_min_players = 1
	playground.maps.time_limit.rtv_fraction = 1.0
	playground.maps.time_limit.start()

	var before := playground.maps.current.id

	_check(
		playground.rock_the_vote(&"bot"),
		"one player of one carries a unanimous vote"
	)

	for _i in range(10):
		await get_tree().process_frame

	_check(
		playground.maps.current.id != before,
		"and the map changes",
		"%s -> %s" % [String(before), String(playground.maps.current.id)]
	)

	# A player who leaves takes their vote with them.
	playground.maps.time_limit.start()
	playground.maps.time_limit.rtv_fraction = 0.6
	playground.maps.time_limit.rtv_min_players = 2

	playground.maps.time_limit.rock_the_vote(&"ghost", 4)
	_check(playground.maps.time_limit.rtv_votes() == 1, "a vote is counted")

	playground.remove_player(&"ghost")
	_check(
		playground.maps.time_limit.rtv_votes() == 1,
		"removing somebody who was not playing changes nothing"
	)

	playground.add_player(&"ghost", "Ghost")
	playground.maps.time_limit.rock_the_vote(&"ghost", 4)
	playground.remove_player(&"ghost")

	_check(
		not playground.maps.time_limit.has_rocked(&"ghost"),
		"and a player who leaves takes their vote with them"
	)

	playground.maps.time_limit.duration = 0.0
	playground.maps.time_limit.start()


## Every prop this build ships is one scene, and the definition is what differs.
##
## [b]The mass column is the one that matters.[/b] `DotPropDef.mass` is read by
## exactly one thing in dot-props — a physics gun's `grab_mass_limit` — so before the
## spawner put it on the body, a catalogue that said 900 kg and a scene saved at 20 kg
## gave a prop that was refused for being too heavy and then punted like a beach ball.
## Nothing errored, and the two numbers were only ever compared by a player wondering
## why.
func _test_props_are_built_from_their_definitions() -> void:
	print("props built from their definitions")

	var at := Vector3(0.0, 40.0, 0.0)

	playground.props.limits.spawn_interval = 0.0

	var ball := playground.props.spawn(&"beach_ball", &"bot", at)
	var boulder := playground.props.spawn(
		&"boulder", &"bot", at + Vector3(6.0, 0.0, 0.0)
	)

	_check(ball != null and boulder != null, "two props spawn")

	if ball == null or boulder == null:
		return

	var ball_body := ball.node as PlaygroundProp
	var boulder_body := boulder.node as PlaygroundProp

	_check(
		ball_body != null and boulder_body != null,
		"and both are the project's own configurable body"
	)

	_check_near(ball_body.mass, 2.0, 0.01, "a beach ball weighs what it says")
	_check_near(boulder_body.mass, 900.0, 0.01, "and a boulder weighs what it says")

	# The whole reason for that check: they are the same scene file, so the only
	# thing that can make them different masses is the definition reaching the body.
	_check(
		ball.def.scene_path == boulder.def.scene_path,
		"from one scene, which is why the mass had to come from the definition"
	)

	var ball_shape := (ball_body.get_node("Collision") as CollisionShape3D).shape
	var boulder_shape := (
		boulder_body.get_node("Collision") as CollisionShape3D
	).shape

	_check(ball_shape is SphereShape3D, "a ball is round")
	_check(
		ball_shape is SphereShape3D
		and is_equal_approx((ball_shape as SphereShape3D).radius, 1.2),
		"at the radius its extent asks for"
	)
	_check(
		boulder_shape is SphereShape3D
		and (boulder_shape as SphereShape3D).radius > (
			ball_shape as SphereShape3D
		).radius,
		"and the boulder is bigger than it while weighing 450 times as much"
	)

	var plank := playground.props.spawn(&"plank", &"bot", at + Vector3.UP * 4.0)
	var plank_shape := (
		(plank.node as PlaygroundProp).get_node("Collision") as CollisionShape3D
	).shape

	_check(
		plank_shape is BoxShape3D
		and (plank_shape as BoxShape3D).size.is_equal_approx(
			Vector3(3.0, 0.15, 0.6)
		),
		"and a plank is a plank"
	)

	# The catalogue itself, because the menu is built out of it and a category with
	# nothing in it is a tab that does nothing.
	var catalogue := playground.props.catalogue
	var categories := catalogue.categories()

	_check(catalogue.size() >= 12, "the catalogue has enough in it to build with",
		"%d props" % catalogue.size())
	_check(categories.size() >= 3, "in at least three categories",
		"%s" % ", ".join(categories))

	for category in categories:
		_check(
			not catalogue.in_category(StringName(category)).is_empty(),
			"category '%s' has props in it" % category
		)

	_check(catalogue.problems().is_empty(), "and nothing is wrong with it",
		"; ".join(catalogue.problems()))

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)


## An entity is a prop with a script, and the script is loaded by path.
##
## [b]This is the whole "spawning things that carry code" mechanism.[/b] The scene is a
## bare `RigidBody3D`; the script comes from `meta`, is loaded by PATH rather than by
## class, and is attached by `Playground._configure_entity`. The path matters: a
## mounted dot-cloud pack's `class_name` globals are not registered in the host, so an
## entity named by class could only ever ship inside the build.
func _test_entities_run_their_scripts() -> void:
	print("entities that run their own scripts")

	# On the sandbox, deliberately. The previous tests leave the game on whichever map
	# they finished with, and an NPC walking about on the bhop map's blocks-with-gaps
	# falls off one — so "does the chaser close the distance" would be measuring the
	# terrain rather than the script. Flat ground is the only surface on which the
	# answer is about the entity.
	var loaded: DotResult = await playground.change_map(&"pg_lobby")
	_check(loaded.ok, "the sandbox loads")

	playground.spawn_player(&"bot")

	# Driven with an EMPTY command for a moment, which is not busywork.
	# `DotFpsController.apply_command` sets the pending command and it stays set: the
	# bot arrives here still holding forward and jump from the bhop test several
	# tests ago, so it auto-hops across the sandbox for the whole of this one — and
	# "does the chaser close the distance" then measures a player who is running
	# away. It also gives them the third of a second it takes to fall the metre from
	# the spawn onto the floor.
	await _drive(&"bot", DotFpsCommand.new(), 60)

	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	var at := Vector3(0.0, 1.2, 0.0)
	var npc := playground.props.spawn(&"npc_wanderer", &"bot", at)

	_check(npc != null, "an entity spawns")

	if npc == null:
		return

	var body := npc.node as PlaygroundEntity

	_check(body != null, "and its body is a PlaygroundEntity, not a plain prop")
	_check(
		body != null and body.get_script() != null
		and body.get_script().resource_path
			== PlaygroundSpawnables.script_of(npc.def),
		"running exactly the script its definition names",
		body.get_script().resource_path if body != null else "none"
	)
	_check(
		playground.entities.has(body),
		"and it is on the list the simulation ticks"
	)

	# `_ready` has already run by the time the script is attached — the spawner adds
	# the body to the world before it emits — so `bind` is what an entity gets
	# instead, and an entity whose world never arrived would sit there being a crate.
	_check(body != null and body.game == playground, "it knows its world")
	_check(body != null and body.instance == npc, "and its own row in the spawner")

	# It moves. Everything above is satisfied by an entity that does nothing at all.
	var before := body.global_position
	var ticks := 0
	var moved := 0.0

	while ticks < 240:
		await get_tree().physics_frame
		ticks += 1
		moved = maxf(moved, before.distance_to(body.global_position))

	_check(moved > 1.0, "and it walks about", "%.2f m" % moved)
	_check(body.age > 0.0, "counting simulated time, not wall time",
		"%.2f s" % body.age)

	# A held entity is furniture. Without that, the NPC fights the physics gun's
	# spring — the gun writes a velocity toward the goal and the NPC writes one
	# toward wherever it was walking — and the prop shudders between them.
	npc.held_by = &"bot"

	var held_at := body.global_position
	body.linear_velocity = Vector3.ZERO

	for _i in range(30):
		await get_tree().physics_frame

	_check(
		held_at.distance_to(body.global_position) < 0.6,
		"a held entity stops driving itself",
		"%.2f m" % held_at.distance_to(body.global_position)
	)

	npc.held_by = &""

	# A chaser goes toward somebody. The bot is at the origin-ish; put the chaser
	# out and check the distance closes, which is the one thing that distinguishes
	# this script from the wanderer.
	var player: PlaygroundPlayer = playground.players[&"bot"]
	var chaser := playground.props.spawn(
		&"npc_chaser", &"bot", player.global_position + Vector3(14.0, 1.2, 0.0)
	)

	_check(chaser != null, "a chaser spawns")

	if chaser != null:
		var opening := chaser.node.global_position.distance_to(
			player.global_position
		)

		for _i in range(300):
			await get_tree().physics_frame

		var closing := chaser.node.global_position.distance_to(
			player.global_position
		)

		_check(
			closing < opening - 3.0,
			"and walks toward the player",
			"%.1f m -> %.1f m" % [opening, closing]
		)

	# A definition whose script is missing does not leave a body in the world. One
	# that did would sit there being a crate, which is indistinguishable from an NPC
	# with nothing to do — and "the NPC does not move" sends the next person to the
	# movement code.
	var broken := DotPropDef.make(&"npc_broken", PlaygroundSpawnables.SCENE_ENTITY)
	broken.meta = {"kind": "entity", "script": "res://game/entities/nope.gd"}
	playground.props.catalogue.add(broken)

	var before_count := playground.props.world_count()
	var refused := playground.props.spawn(&"npc_broken", &"bot", at)

	await get_tree().process_frame

	_check(
		playground.props.world_count() == before_count,
		"an entity whose script is missing leaves nothing in the world",
		"%d -> %d" % [before_count, playground.props.world_count()]
	)
	_check(
		refused == null or not refused.is_alive(),
		"and its row is dead rather than counted against a budget"
	)

	# One that points at a real script which is not an entity is the same failure by
	# a different route, and it is the one a copy-paste actually produces.
	var wrong := DotPropDef.make(&"npc_wrong", PlaygroundSpawnables.SCENE_ENTITY)
	wrong.meta = {"kind": "entity", "script": "res://game/playground_config.gd"}
	playground.props.catalogue.add(wrong)

	before_count = playground.props.world_count()
	playground.props.spawn(&"npc_wrong", &"bot", at)

	await get_tree().process_frame

	_check(
		playground.props.world_count() == before_count,
		"and so does one whose script is not an entity"
	)

	playground.props.catalogue.remove(&"npc_broken")
	playground.props.catalogue.remove(&"npc_wrong")
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	await get_tree().process_frame

	_check(playground.entities.is_empty(), "clearing the world empties the tick list")


## Weapons: a script loaded by path, held rather than spawned.
func _test_weapons() -> void:
	print("weapons")

	var defs := PlaygroundWeapons.built_in()

	_check(defs.size() >= 3, "the build ships an arsenal", "%d" % defs.size())
	_check(
		playground.weapons.size() == defs.size(),
		"and the game offers it"
	)

	for def in defs:
		_check(def.validate().ok, "'%s' is a usable definition" % def.id)

	var launcher := PlaygroundWeapons.make(
		PlaygroundWeapons.find(defs, &"launcher")
	)

	_check(launcher != null, "a weapon is built from its definition")
	_check(
		launcher != null and launcher.get_script().resource_path
			== PlaygroundWeapons.find(defs, &"launcher").script_path,
		"running exactly the script it names"
	)

	# The two ways a catalogue entry is wrong, and neither may hand back a working-
	# looking weapon: a base `PlaygroundWeapon` whose buttons do nothing is
	# indistinguishable from a weapon that is fine and pointed at nothing.
	var missing := PlaygroundWeaponDef.make(&"x", "X", "res://game/weapons/nope.gd")
	_check(
		PlaygroundWeapons.make(missing) == null,
		"a weapon whose script is missing is refused"
	)

	var not_a_weapon := PlaygroundWeaponDef.make(
		&"y", "Y", "res://game/playground_config.gd"
	)
	_check(
		PlaygroundWeapons.make(not_a_weapon) == null,
		"and so is one whose script is not a weapon"
	)

	# The launcher fires whatever the menu armed, which is what saves it having a
	# second list of ammunition and a second way to choose from it.
	playground.props.limits.spawn_interval = 0.0
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	launcher.equip(playground, PlaygroundWeapons.find(defs, &"launcher"))
	launcher.wielder = &"bot"
	launcher.armed = &"beach_ball"

	var fired := launcher.primary(null, Vector3(0.0, 6.0, 0.0), Vector3.FORWARD)

	_check(fired.ok, "the launcher fires")

	if fired.ok:
		var shot := fired.value as DotPropInstance

		_check(shot.def.id == &"beach_ball", "the prop the menu armed")
		_check(
			shot.body().linear_velocity.length() > 10.0,
			"at a muzzle velocity",
			"%.1f m/s" % shot.body().linear_velocity.length()
		)

		# A muzzle velocity, not an impulse. An impulse is divided by the mass, which
		# is right for a punt and exactly wrong here: a launcher whose boulder leaves
		# at a fortieth of the speed of its ball is one nobody can aim.
		launcher.armed = &"boulder"

		var heavy := launcher.primary(null, Vector3(0.0, 6.0, 0.0), Vector3.FORWARD)

		_check(
			heavy.ok and is_equal_approx(
				(heavy.value as DotPropInstance).body().linear_velocity.length(),
				shot.body().linear_velocity.length()
			),
			"and a 900 kg prop leaves as fast as a 2 kg one"
		)

	# Armed with something the catalogue no longer has — a map change can do that —
	# it falls back rather than being refused with "no such prop", which reads as the
	# weapon being broken rather than as the ammunition being gone.
	launcher.armed = &"nothing_like_this"

	var fallback := launcher.primary(null, Vector3(0.0, 6.0, 0.0), Vector3.FORWARD)

	_check(fallback.ok, "an armed prop that no longer exists falls back")

	# The impulse gun shoves what is near it, and leaves frozen props alone: freezing
	# is how a builder says "this is finished", and a blast that undid it would make
	# the two tools fight.
	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)

	var loose := playground.props.spawn(&"crate", &"bot", Vector3(2.0, 1.0, 0.0))
	var stuck := playground.props.spawn(&"crate", &"bot", Vector3(-2.0, 1.0, 0.0))

	DotPhysGun.set_frozen(stuck, true)

	var impulse := PlaygroundWeapons.make(PlaygroundWeapons.find(defs, &"impulse"))
	impulse.equip(playground, PlaygroundWeapons.find(defs, &"impulse"))
	impulse.wielder = &"bot"

	loose.body().linear_velocity = Vector3.ZERO

	var blast := impulse.primary(null, Vector3.ZERO, Vector3.FORWARD)

	# Two steps, not one. `apply_central_impulse` is not readable in
	# `linear_velocity` until the step that consumes it has run — dot-props' own
	# suite found the same thing and says so — and awaiting a physics frame lands
	# before that step rather than after it.
	await get_tree().physics_frame
	await get_tree().physics_frame

	_check(blast.ok and int(blast.value) >= 1, "the impulse gun moves something")
	_check(
		loose.body().linear_velocity.length() > 1.0,
		"a loose prop is shoved",
		"%.1f m/s" % loose.body().linear_velocity.length()
	)
	_check(
		stuck.body().linear_velocity.length() < 0.5,
		"and a frozen one is left alone",
		"%.1f m/s" % stuck.body().linear_velocity.length()
	)

	# The remover's right click clears what you own, and goes through the spawner so
	# the budget it frees is real.
	var remover := PlaygroundWeapons.make(PlaygroundWeapons.find(defs, &"remover"))
	remover.equip(playground, PlaygroundWeapons.find(defs, &"remover"))
	remover.wielder = &"bot"

	var cleared := remover.secondary(null, Vector3.ZERO, Vector3.FORWARD)

	_check(cleared.ok and int(cleared.value) >= 2, "the remover clears your props")
	_check(playground.props.player_count(&"bot") == 0, "and the budget goes with them")

	playground.props.clear_all(DotPropSpawner.REASON_ADMIN)


## The spawn menu, driven the way a player drives it.
##
## [b]dot-ui's suite cannot reach this and neither can dot-props'.[/b] A menu built
## out of a catalogue is exactly the seam this project exists to run: the screen stack
## is one addon, the catalogue is another, and the code joining them is here. It is
## also a `Control` built entirely in code, which is the shape that produced the
## family's `set_anchors_preset` bug — so the sizes are checked, not just the
## contents.
func _test_spawn_menu() -> void:
	print("the spawn menu")

	var menu := PlaygroundSpawnMenu.new()
	menu.catalogue = playground.props.catalogue
	menu.weapons = playground.weapons
	add_child(menu)

	# Registered on a real stack rather than shown directly: pushing is what calls
	# `_on_push`, and `_on_push` is what fills the grid.
	var stack := DotScreenStack.new()
	add_child(stack)

	var ready := stack.setup()
	_check(ready.ok, "the screen stack sets up")

	var registered := stack.register(menu)
	_check(registered.ok, "and the menu registers on it")

	var pushed := stack.push(menu.screen_id())
	_check(pushed.ok, "and opens")
	_check(stack.any_open(), "and the stack knows a menu is up")

	await get_tree().process_frame

	_check(
		menu.size.x > 100.0 and menu.size.y > 100.0,
		"the menu has a size, which a Control built in code does not get for free",
		"%.0f x %.0f" % [menu.size.x, menu.size.y]
	)

	# --- Props tab -----------------------------------------------------------

	var props_shown := menu.shown()
	var prop_count := 0

	for def in playground.props.catalogue.props:
		if PlaygroundSpawnables.kind_of(def) == PlaygroundSpawnables.Kind.PROP:
			prop_count += 1

	_check(
		props_shown.size() == prop_count,
		"the props tab shows every prop and no entities",
		"%d of %d" % [props_shown.size(), prop_count]
	)
	_check(
		not props_shown.has(&"npc_wanderer"),
		"and an entity is not among them"
	)
	_check(menu.card_for(&"crate") != null, "each one has a card that names it")

	# Icons. Nothing here ships art, so every card is drawn from the definition —
	# and a card with no icon at all is the failure that looks like a working menu
	# right up until somebody opens it.
	var crate_card := menu.card_for(&"crate")
	var ball_card := menu.card_for(&"ball")

	_check(
		crate_card != null and crate_card.icon != null
		and crate_card.icon.get_width() == PlaygroundIcons.SIZE,
		"with an icon on it"
	)
	_check(
		crate_card != null and ball_card != null
		and crate_card.icon != ball_card.icon,
		"and a box and a sphere do not get the same one"
	)

	# The cache is keyed on the drawing, not on the prop, so two props that draw the
	# same share a texture. That is what stops a four-hundred-prop catalogue building
	# four hundred images every time somebody presses Q.
	_check(
		PlaygroundIcons.generated(PlaygroundIcons.Glyph.BOX, 1.0, Color.RED)
		== PlaygroundIcons.generated(PlaygroundIcons.Glyph.BOX, 1.0, Color.RED),
		"an icon drawn twice is one texture"
	)

	# Clicking spawns. The menu never spawns anything itself — it emits, and the
	# client asks the server — which is what lets this file work unchanged when the
	# spawn becomes a dot-net message.
	var chosen: Array[StringName] = []
	menu.prop_chosen.connect(
		func(id: StringName) -> void: chosen.append(id)
	)

	menu.card_for(&"barrel").pressed.emit()

	_check(chosen.size() == 1 and chosen[0] == &"barrel",
		"clicking a prop asks for that prop")
	_check(menu.selected == &"barrel", "and arms it for the spawn key")

	# Search reaches across every category on the tab, because a player who types
	# "barrel" wants the barrel and not "no such prop, you are on the Toys tab".
	menu._on_search_changed("boulder")
	await get_tree().process_frame

	var found := menu.shown()
	_check(found.has(&"boulder"), "searching finds a prop by name")
	_check(found.size() < props_shown.size(), "and narrows the grid")

	menu._on_search_changed("zzzz")
	await get_tree().process_frame

	_check(
		menu.shown().is_empty(),
		"a search that matches nothing shows nothing"
	)

	menu._on_search_changed("")
	await get_tree().process_frame

	# --- Entities tab --------------------------------------------------------

	menu.show_tab(PlaygroundSpawnMenu.Tab.ENTITIES)
	await get_tree().process_frame

	var entities_shown := menu.shown()

	_check(not entities_shown.is_empty(), "the entities tab has entities on it")
	_check(
		entities_shown.has(&"npc_wanderer") and not entities_shown.has(&"crate"),
		"and no props"
	)

	# --- Weapons tab ---------------------------------------------------------

	menu.show_tab(PlaygroundSpawnMenu.Tab.WEAPONS)
	await get_tree().process_frame

	var weapons_shown := menu.shown()

	_check(
		weapons_shown.size() == playground.weapons.size(),
		"the weapons tab shows every weapon",
		"%d of %d" % [weapons_shown.size(), playground.weapons.size()]
	)

	var equipped: Array[StringName] = []
	menu.weapon_chosen.connect(
		func(id: StringName) -> void: equipped.append(id)
	)

	menu.card_for(&"launcher").pressed.emit()

	_check(
		equipped.size() == 1 and equipped[0] == &"launcher",
		"and clicking one asks to equip it rather than to spawn it"
	)

	# Switching tabs clears the filter. Carrying "containers" onto the weapons tab
	# would show nothing and read as the tab being broken.
	menu.show_tab(PlaygroundSpawnMenu.Tab.PROPS)
	await get_tree().process_frame

	_check(
		menu.shown().size() == prop_count,
		"and going back to props shows all of them again"
	)

	_check(
		PlaygroundSpawnMenu.name_of_tool(&"phys") == "physics gun"
		and PlaygroundSpawnMenu.name_of_tool(&"") == "nothing",
		"a tool id has a name, and an empty one is not silently a gravity gun"
	)

	var popped := stack.pop(menu.screen_id())
	_check(popped.ok and not stack.any_open(), "the menu closes")

	stack.queue_free()


# --- The sandbox, and the course in the corner of it ------------------------

## `pg_lobby` is a sandbox on the main track and a jump course on bonus 1.
##
## [b]Both halves are the test.[/b] The main track still has no start and no end, so
## everything the game does works with no timer running — which is what `pg_lobby`
## has always been for. The bonus track is a real course with a start, a finish, a
## split and a reset volume, which is what proves the timer is not a surf-and-bhop
## thing: nothing about a jump course is a movement genre.
func _test_the_sandbox_and_its_course() -> void:
	print("the sandbox and its course")

	var changed: DotResult = await playground.change_map(&"pg_lobby")
	_check(changed.ok, "the sandbox loads")

	var player: PlaygroundPlayer = playground.players[&"bot"]
	var zones := playground.timers.zones

	_check(zones != null and not zones.zones.is_empty(), "and it has zones")

	if zones == null:
		return

	_check(
		zones.of_kind(DotTimerZone.Kind.START, DotTimerTrack.MAIN).is_empty()
		and zones.of_kind(DotTimerZone.Kind.END, DotTimerTrack.MAIN).is_empty(),
		"the main track has no start and no end: it is somewhere to build"
	)
	_check(
		zones.of_kind(
			DotTimerZone.Kind.START, DotTimerTrack.BONUS_FIRST
		).size() == 1,
		"and the course on bonus 1 has one start"
	)
	_check(
		zones.of_kind(
			DotTimerZone.Kind.END, DotTimerTrack.BONUS_FIRST
		).size() == 1,
		"and one finish"
	)
	_check(zones.problems().is_empty(), "with nothing wrong with the set",
		"; ".join(zones.problems()))

	var tracks := playground.tracks_on_this_map()
	_check(
		tracks == [DotTimerTrack.MAIN, DotTimerTrack.BONUS_FIRST],
		"the game can see both tracks without being told about them",
		str(tracks)
	)

	# The main track, exactly as before: walking about starts nothing.
	player.timer.set_track(DotTimerTrack.MAIN)
	playground.spawn_player(&"bot")

	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)

	await _drive(&"bot", forward, 200)

	_check(
		not player.timer.run.is_active(),
		"no run starts on the track with no start zone"
	)
	_check(
		player.controller.state.is_grounded(),
		"and the player walks on it normally"
	)

	playground.props.limits.spawn_interval = 0.0
	var crate := playground.props.spawn(
		&"crate", &"bot", player.global_position + Vector3.UP * 3.0
	)
	_check(crate != null, "and can still spawn props")

	# The course. Switching track moves the player to its spawn, which is the only
	# way onto it — the start pad is six metres up on a pillar.
	_check(player.timer.set_track(DotTimerTrack.BONUS_FIRST), "the track switches")
	playground.spawn_player(&"bot")

	var spawn := PgLobby.build_zones().first_of_kind(
		DotTimerZone.Kind.SPAWN, DotTimerTrack.BONUS_FIRST
	)

	_check(
		player.global_position.distance_to(spawn.destination) < 0.5,
		"and puts the player on the course's start pad",
		"%.2f m away" % player.global_position.distance_to(spawn.destination)
	)

	# Walking off the pad starts the run, and falling off the course puts the player
	# back on the pad. Driven as one stretch and watched through the signals rather
	# than sampled between two short drives: a bot walking off a platform is at the
	# mercy of where in a tick it left the edge, and a test that checked "has it
	# started yet" after a fixed number of ticks would be timing-sensitive for no
	# reason.
	var started: Array[bool] = [false]
	var respawns: Array[int] = []

	# An Array, not a counter: a GDScript lambda captures locals by value, so an int
	# incremented in a handler reads zero outside it and the test reports a failure
	# for a signal that fired perfectly.
	var on_start := func(_run: DotTimerRun) -> void: started[0] = true
	var on_effect := func(id: StringName, zone: DotTimerZone) -> void:
		if id == &"bot" and zone.kind == DotTimerZone.Kind.RESPAWN:
			respawns.append(zone.id)

	player.timer.run_started.connect(on_start)
	playground.timers.effect_requested.connect(on_effect)

	await _drive(&"bot", forward, 400)

	player.timer.run_started.disconnect(on_start)
	playground.timers.effect_requested.disconnect(on_effect)

	_check(started[0], "walking off the pad starts a run on the bonus track")

	# This is the check that would have failed for as long as this family has
	# existed. `DotTimer.effect_requested` was declared, forwarded by the manager and
	# connected by both games — and emitted by NOTHING, so every RESPAWN zone in the
	# family did exactly nothing and a player who fell off a surf map fell for ever.
	# Fixed in dot-timer; this is the join it was missing from.
	_check(
		not respawns.is_empty(),
		"falling off the course asks the game to put the player back"
	)

	# And the game actually did it: six metres up, on the course, rather than on the
	# sandbox floor the course is built over.
	_check(
		player.global_position.y > 5.0,
		"which puts them back on the course rather than under it",
		"y = %.2f" % player.global_position.y
	)
	_check(
		not player.timer.run.is_active(),
		"and the run they were on is abandoned rather than left running"
	)

	# The same volume, on the main track, must do nothing: somebody building under
	# the course would otherwise be teleported onto it every few seconds.
	player.timer.set_track(DotTimerTrack.MAIN)

	var under := Vector3(PgLobby.COURSE_X, 1.0, PgLobby.COURSE_START_Z)
	player.teleport(under, 0.0)

	var still := DotFpsCommand.new()
	await _drive(&"bot", still, 60)

	_check(
		player.global_position.distance_to(under) < 3.0,
		"a sandbox player standing under the course is left alone",
		"%.2f m away" % player.global_position.distance_to(under)
	)

	playground.remove_player(&"bot")
	_check(playground.players.is_empty(), "a player can leave cleanly")
	_check(
		playground.props.world_count() == 0,
		"and their props go with them"
	)


# --- The client -------------------------------------------------------------

## A real `PlaygroundClient` boots and ends up with a player, a camera and a menu.
##
## [b]The one path in this project no other test touches, and it broke silently.[/b]
## Everything above drives `Playground` directly, because that is the half that runs
## headless — so the client's own boot sequence was covered by nothing, and when it
## started waiting for a signal that had already been emitted it simply stopped
## halfway through `_ready`. No error, no failed load, nothing in the log: a black
## screen with a `Playground` ticking behind it. Only a screenshot showed it.
##
## `change_map` completes without ever suspending when the map is a scene already in
## the build, which is every map here — so this test exercises exactly the case that
## broke. It would deadlock, not fail, without `booted` being checked before the
## await; the suite's own `timeout` is what turns that into a red run.
func _test_the_client_boots() -> void:
	print("the client boots")

	var client := PlaygroundClient.new()
	client.name = "Client"

	# Its own config, records in memory. A test must not write into the user's data
	# directory, and this is the only reason `PlaygroundClient.config` exists.
	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.record_replays = false
	client.config = config

	add_child(client)

	for _i in range(4):
		await get_tree().process_frame

	_check(client.playground != null, "the client builds a playground")
	_check(
		client.playground != null and client.playground.booted,
		"which finishes booting"
	)
	_check(
		client.playground != null and client.playground.maps.current != null,
		"with a map up",
		String(client.playground.maps.current.id)
			if client.playground != null and client.playground.maps.current != null
			else "none"
	)

	# The four things that are all missing together when `_ready` stops halfway.
	_check(client.player != null, "the client has a player")
	_check(client.camera != null, "and a camera")
	_check(client.hud != null, "and a HUD")
	_check(
		client.screens != null and client.menu != null,
		"and a spawn menu registered on a stack"
	)

	_check(
		client.menu != null and client.screens != null
		and client.screens.screen(client.menu.screen_id()) == client.menu,
		"which the stack can find by id"
	)
	_check(
		client.player != null and client.player.samples_input
		and client.player.sampler != null,
		"and the player samples input, with a sampler actually built"
	)

	client.queue_free()

	await get_tree().process_frame
	await get_tree().process_frame

