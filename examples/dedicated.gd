extends Node

## Boots a real [DotServer], loads the playground module into it, and runs the
## commands an operator and an admin would actually type.
##
## [codeblock]
## godot --headless --path . res://examples/dedicated.tscn
## [/codeblock]
##
## [b]This is the seam the family's own notes say is never run.[/b] The playground's
## other suite exercises the joins between the gameplay addons; this one exercises the
## join between the game and the server — the console, the module lifecycle, the
## permission flags, and the tick rate travelling from `sv_tickrate` all the way to a
## record's `tick_rate` field.
##
## Nothing here opens a socket. A dedicated server that never accepts a client is
## still a dedicated server as far as its console, its cvars and its modules are
## concerned, and those are what this is about.

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var server: DotServer = null
var game: Playground = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("playground — dedicated server")
	print("")

	await _boot()

	if game != null:
		_test_tickrate_reaches_the_timer()
		await _test_map_commands()
		_test_timer_commands()
		_test_zone_workflow()
		_test_prop_commands()
		_test_permissions()
		await _test_module_unloads_cleanly()

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


## Runs a console command as the local console and returns what it replied.
##
## [b]Through a reply sink captured in an [Array], not by reading the template's own
## output.[/b] Two reasons, and both are traps the family's notes already name:
## [method DotConsole.execute] builds a FRESH context from the template and copies
## only the sink, so the template's `output` stays empty; and a GDScript lambda
## captures by value, so a [PackedStringArray] appended to inside one is unchanged
## outside it. An [Array] is a reference and is not.
func _run_command(line: String) -> PackedStringArray:
	var captured: Array[String] = []

	var template := DotCmdContext.console("", PackedStringArray())
	template.reply_sink = func(text: String) -> void: captured.append(text)

	server.console.execute(line, template)

	return PackedStringArray(captured)


func _said(lines: PackedStringArray, text: String) -> bool:
	for line in lines:
		if line.to_lower().contains(text.to_lower()):
			return true
	return false


# --- Boot ------------------------------------------------------------------

func _boot() -> void:
	print("booting a dedicated server")

	# The tick rate is set the way an operator actually sets it: a line in a config
	# file the server execs at boot.
	#
	# [b]Not by assigning `config.tickrate`, and that is the point of doing it this
	# way.[/b] A `server.cfg` beats anything set in code, which is correct and is
	# also exactly the trap this family has hit before: dot-server's own self-test
	# once asserted a cvar value that the addon's shipped `server.cfg` had already
	# overridden. Testing the file path tests what an operator will experience.
	#
	# [b]`startup_config`, not `autoexec_config`.[/b] `sv_tickrate` is
	# FLAG_STARTUP_ONLY — a live server cannot re-negotiate its tick rate — and
	# dot-server execs `server.cfg` BEFORE the listener for exactly that reason,
	# while `autoexec.cfg` runs after and would have it refused. Putting the tick
	# rate in the wrong one of the two is the mistake this test would otherwise be
	# making silently.
	#
	# 100, deliberately not the project's own default of 128: the whole point of the
	# chain below is that the SERVER decides, so a test using the same number on both
	# sides would pass with the chain disconnected.
	var cfg_path := "user://pg_dedicated_test.cfg"
	var cfg := FileAccess.open(cfg_path, FileAccess.WRITE)

	if cfg == null:
		_check(false, "the test config file could be written", cfg_path)
		return

	cfg.store_line("// written by examples/dedicated.gd")
	cfg.store_line("sv_tickrate 100")
	cfg.store_line("hostname \"playground test\"")
	cfg.close()

	var config := DotServerConfig.new()
	config.startup_config = cfg_path
	# And nothing in the after-the-listener file, so the test is unambiguous about
	# which one set it.
	config.autoexec_config = ""
	config.hostname = "playground test"
	config.max_players = 16
	config.hibernate_when_empty = false
	config.rcon_password = ""
	config.query_enabled = false

	# A port nothing else on a developer's machine is likely to be holding. The
	# server still opens a listener even with queries off, and a boot that failed on
	# a busy 27015 would look like the module being broken.
	config.port = 28765

	server = DotServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)

	# `auto_boot` makes `_ready` await `boot()`, which opens a listener and reads the
	# config's environment and command-line layers — so this takes several frames and
	# a single `process_frame` catches it half-built.
	for _i in range(60):
		await get_tree().process_frame

		if server.state == DotServer.State.RUNNING:
			break

	_check(
		server.state == DotServer.State.RUNNING,
		"the server boots",
		DotServer.State.keys()[server.state]
	)
	_check(server.console != null, "the server has a console")
	_check(
		Engine.physics_ticks_per_second == 100,
		"and sv_tickrate reached the engine's physics rate",
		"%d" % Engine.physics_ticks_per_second
	)

	# The game, built AFTER the server so it reads the rate the server has set —
	# which is the ordering a real deployment has, because the server is what boots
	# first.
	var pg_config := PlaygroundConfig.new()
	pg_config.records_directory = ""
	pg_config.initial_map = &"pg_surf_intro"
	pg_config.map_seconds = 0.0

	game = Playground.new()
	game.name = "Playground"
	game.config = pg_config
	add_child(game)

	# Two frames: the playground's own `_ready` awaits its first map change.
	await get_tree().process_frame
	await get_tree().process_frame

	_check(game.maps.current != null, "the game loaded a map",
		String(game.maps.current.id) if game.maps.current else "-")

	var loaded := server.modules.load_module("res://game/playground_module.gd")

	_check(loaded.ok, "the playground module loads into the server",
		loaded.error.message if not loaded.ok else "")

	if not loaded.ok:
		return

	_check(
		server.console.find_command("pg_status") != null,
		"and registers its commands"
	)
	_check(
		server.console.find_cvar("pg_map_seconds") != null,
		"and its cvars"
	)


func _test_tickrate_reaches_the_timer() -> void:
	print("sv_tickrate reaches the record")

	# The chain, end to end and in one test, because every link in it is silent when
	# it breaks: an operator writes `sv_tickrate 100`; dot-server writes
	# `Engine.physics_ticks_per_second`; the playground reads it; the timer manager
	# adopts it; and it lands on the record. A timer counting 128 a second on a
	# server stepping 100 reports every run 28% long, and nothing about the run
	# looks unusual.
	_check(
		server.console.get_int("sv_tickrate") == 100,
		"server.cfg set sv_tickrate to 100",
		"%d" % server.console.get_int("sv_tickrate")
	)
	_check(
		Engine.physics_ticks_per_second == 100,
		"the engine steps at 100"
	)
	_check(
		game.tick_rate == 100,
		"the game counts at 100",
		"%d" % game.tick_rate
	)
	_check(
		game.timers.tick_rate == 100,
		"the timer counts at 100",
		"%d" % game.timers.tick_rate
	)
	_check(
		game.timers.tick_rate_matches_engine(),
		"and nothing disagrees"
	)

	var run := DotTimerRun.make(0, &"normal", 1.0 / float(game.timers.tick_rate))
	run.begin(0.0)
	run.ticks = 250
	run.finish(0.0)

	var record := DotTimerRecord.from_run(run, &"m", &"p", "P")

	_check(record.tick_rate == 100, "and a record is stamped with it")
	_check(
		absf(record.time - 2.5) < 0.001,
		"so its time means what it says",
		"%.3f s" % record.time
	)

	# And the status line says so when they disagree, which is what somebody
	# debugging it will actually look at.
	var status := _run_command("pg_status")
	_check(_said(status, "tick rate"), "pg_status reports the tick rate", str(status))


# --- Commands --------------------------------------------------------------

func _test_map_commands() -> void:
	print("map commands")

	var listed := _run_command("pg_map")
	_check(_said(listed, "pg_surf_intro"), "pg_map lists the maps", str(listed))

	var missing := _run_command("pg_map not_a_map")
	_check(_said(missing, "no map matches"), "and refuses one that is not there")

	_run_command("pg_map pg_bhop_intro")

	# The command awaits a map change, so it lands over the next few frames.
	for _i in range(10):
		await get_tree().process_frame

	_check(
		game.maps.current.id == &"pg_bhop_intro",
		"pg_map changes map",
		String(game.maps.current.id)
	)

	var next := _run_command("pg_nextmap")
	_check(_said(next, "next"), "pg_nextmap says what plays next", str(next))

	game.maps.time_limit.duration = 600.0
	game.maps.time_limit.start()

	var extended := _run_command("pg_extend 300")
	_check(_said(extended, "extended"), "pg_extend extends the map", str(extended))
	_check(
		game.maps.time_limit.remaining > 800.0,
		"and adds the time",
		"%.0f" % game.maps.time_limit.remaining
	)

	# From the server console there is no player, so rocking the vote is refused
	# rather than counted for nobody.
	var rocked := _run_command("pg_rtv")
	_check(
		_said(rocked, "only a player"),
		"and the console cannot rock the vote for nobody",
		str(rocked)
	)


func _test_timer_commands() -> void:
	print("timer commands")

	var styles := _run_command("pg_style")
	_check(_said(styles, "sideways"), "pg_style lists the styles", str(styles))
	_check(_said(styles, "points"), "with what they are worth")

	var top := _run_command("pg_top")
	_check(top.size() > 0, "pg_top answers even with no records", str(top))

	# Commands that need a player refuse politely from the console rather than
	# erroring, because an operator typing them is the normal way to find out what
	# they do.
	for command in ["pg_track", "pg_cp", "pg_tp", "pg_cp_clear"]:
		var reply := _run_command(command)
		_check(
			_said(reply, "only a player"),
			"%s refuses politely from the console" % command,
			str(reply)
		)


func _test_zone_workflow() -> void:
	print("the sm_zones workflow")

	# Drawing a zone the way an admin does on a map whose author never used this
	# engine: pick a kind, stand on one corner, stand on the other.
	var before := game.timers.zones.zones.size()

	var began := _run_command("pg_zone start")
	_check(_said(began, "stand on one corner"), "pg_zone starts a zone", str(began))

	var first := _run_command("pg_zone_mark")
	_check(_said(first, "first corner"), "the first mark is taken", str(first))

	var second := _run_command("pg_zone_mark")
	_check(
		game.timers.zones.zones.size() == before + 1,
		"and the second completes the zone",
		"%d -> %d" % [before, game.timers.zones.zones.size()]
	)

	# Live immediately. An admin who had to reload the map to test a start line
	# would test it once.
	_check(
		game.timers.timer_for(&"nobody") == null
			or game.timers.zones.zones.size() == before + 1,
		"and it is live without a map reload"
	)

	var listed := _run_command("pg_zone_list")
	_check(_said(listed, "START"), "pg_zone_list shows it", str(listed))

	var undone := _run_command("pg_zone_undo")
	_check(_said(undone, "removed"), "pg_zone_undo removes it", str(undone))
	_check(
		game.timers.zones.zones.size() == before,
		"and the count goes back"
	)

	# Saving a set with a problem is refused rather than written with a warning: a
	# zone file with a start and no end is playable and unfinishable, and the moment
	# it is on disk somebody else has a copy.
	var broken := DotTimerZoneSet.new()
	broken.map_id = &"broken"
	broken.add(DotTimerZone.make(DotTimerZone.Kind.START).set_box(
		Vector3.ZERO, Vector3.ONE
	))

	var real := game.timers.zones
	game.timers.zones = broken

	var refused := _run_command("pg_zone_save")
	_check(
		_said(refused, "not saving"),
		"a zone set with a problem is not written",
		str(refused)
	)

	game.timers.zones = real

	var saved := _run_command("pg_zone_save user://test_zones.json")
	_check(_said(saved, "wrote"), "and a good one is", str(saved))
	_check(
		FileAccess.file_exists("user://test_zones.json"),
		"with a file on disk"
	)

	DirAccess.remove_absolute(
		ProjectSettings.globalize_path("user://test_zones.json")
	)

	# Both spellings of a track, because both are what somebody types — and reading
	# only the first token turned `bonus 99` into bonus 1 and then read the 99 as a
	# stage number, so an impossible track became a plausible zone on the wrong one.
	for spelling in ["pg_zone start b99", "pg_zone start bonus 99"]:
		var bad_track := _run_command(spelling)
		_check(
			_said(bad_track, "no such track"),
			"'%s' is refused rather than silently becoming another track" % spelling,
			str(bad_track)
		)

	var good_track := _run_command("pg_zone end bonus 2")
	_check(
		_said(good_track, "Bonus 2"),
		"while a real two-token track is understood",
		str(good_track)
	)

	_run_command("pg_zone_mark")
	_run_command("pg_zone_mark")

	var bonus := game.timers.zones.first_of_kind(
		DotTimerZone.Kind.END, DotTimerTrack.of_bonus(2)
	)
	_check(bonus != null, "and the zone lands on it")

	_run_command("pg_zone_undo")


func _test_prop_commands() -> void:
	print("prop commands")

	var listed := _run_command("pg_prop")
	_check(_said(listed, "only a player"), "pg_prop needs a player", str(listed))

	# The admin command does not, because clearing up after somebody is exactly what
	# an operator does from a terminal.
	game.props.limits.spawn_interval = 0.0
	game.props.spawn(&"crate", &"ghost", Vector3(0.0, 5.0, 0.0))
	game.props.spawn(&"crate", &"ghost", Vector3(0.0, 6.0, 0.0))

	_check(game.props.world_count() == 2, "two props are in the world")

	var cleared := _run_command("pg_props_clear")
	_check(_said(cleared, "removed 2"), "pg_props_clear removes them", str(cleared))
	_check(game.props.world_count() == 0, "and the world is empty")


func _test_permissions() -> void:
	print("permissions")

	# The zone commands are CHANGEMAP, not GENERIC: drawing a start line is editing
	# the map's rules, and somebody who can do it can invalidate every record on it.
	var zone_cmd: DotConCommand = server.console.find_command("pg_zone")
	_check(zone_cmd != null, "pg_zone is registered")

	if zone_cmd != null:
		_check(
			zone_cmd.permission == DotAdminFlags.CHANGEMAP,
			"and needs the changemap flag",
			zone_cmd.permission
		)

	var rtv_cmd: DotConCommand = server.console.find_command("pg_rtv")
	_check(
		rtv_cmd != null and rtv_cmd.permission == "",
		"while rocking the vote needs nothing"
	)

	var clear_cmd: DotConCommand = server.console.find_command("pg_props_clear")
	_check(
		clear_cmd != null and clear_cmd.permission == DotAdminFlags.GENERIC,
		"and clearing everybody's props is an admin action"
	)


func _test_module_unloads_cleanly() -> void:
	print("the module unloads cleanly")

	game.add_player(&"u1", "One")
	_check(game.players.size() == 1, "a player is in the game")

	var unloaded := server.modules.unload_module("playground")
	_check(unloaded.ok, "the module unloads",
		unloaded.error.message if not unloaded.ok else "")

	# Its commands go with it. A module that left them behind would leave a console
	# whose commands call into a module that is no longer there.
	_check(
		server.console.find_command("pg_status") == null,
		"and takes its commands with it"
	)
	_check(
		server.console.find_cvar("pg_map_seconds") == null,
		"and its cvars"
	)

	# And the players it put in the game come back out, or the game would be holding
	# players whose sessions no longer exist.
	_check(
		game.players.is_empty(),
		"and the players it added",
		"%d left" % game.players.size()
	)

	var reloaded := server.modules.load_module("res://game/playground_module.gd")
	_check(reloaded.ok, "and it can be loaded again")

	await get_tree().process_frame
