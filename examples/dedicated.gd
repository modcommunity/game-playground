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
var platform: PlaygroundPlatform = null


## The loaded module, looked up rather than kept.
##
## [b]Looked up every time, because `_test_module_unloads_cleanly` unloads it.[/b] A field
## holding it would be a freed object the moment that section ran, and every section after
## it would be testing a use-after-free rather than the thing it names.
##
## Typed as [DotModule] rather than as its own class, because `playground_module.gd` has
## **no `class_name`** — it is loaded by path, which is the shape a module delivered in a
## dot-cloud pack must have. Its fields come back through `get()` for the same reason.
func _module() -> DotModule:
	return server.modules.get_module("playground")


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
		_test_services()
		await _test_moderation()
		_test_arena()
		_test_waves()
		_test_shop()
		_test_spectating()
		await _test_downed()
		await _test_progress()
		_test_vote()
		_test_identity()
		_test_disconnect_is_handled()
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

	# [b]The identity half, before the modules.[/b] [DotPlatformModule] refuses to load
	# without a [DotPlatformHub] in the registry, and building the hub is awaited work —
	# which is why it is here, in the application, rather than inside a module's
	# `_module_load`, which dot-server's module host does not await.
	platform = PlaygroundPlatform.new()
	platform.name = "Identity"
	platform.directory = "user://pg_dedicated_identity"
	add_child(platform)

	var identity: DotResult = await platform.setup()
	_check(identity.ok, "profiles and avatars are up", str(identity.error))

	var platform_module := server.modules.load_module(
		"res://addons/dot_platform/dot_platform_module.gd"
	)
	_check(platform_module.ok, "the platform module loads", str(platform_module.error))

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

	# The plain name, which is dot-map's now. It used to be dot-server's and it changed the
	# GAME -- so on this server, one game and several maps, `map` did the one thing an
	# operator typing it did not mean.
	var plain := _run_command("map")
	_check(_said(plain, "pg_surf_intro"), "`map` lists the maps", str(plain))

	_run_command("map pg_surf_intro")
	for _i in range(10):
		await get_tree().process_frame
	_check(
		game.maps.current.id == &"pg_surf_intro",
		"and `map <id>` changes it, through the game's own reset rather than the session",
		String(game.maps.current.id)
	)

	var map_command: DotConCommand = server.console.find_command("map")
	_check(map_command != null, "`map` is registered")
	_check(
		map_command != null and map_command.chat_allowed,
		"and IS typable in chat here, because a sandbox has no ranked run for it to destroy"
	)
	_check(
		server.console.find_command("game") != null,
		"while `game` is what changes the game, which is what dot-server's `map` used to do"
	)
	_check(
		server.console.find_command("mapinfo") != null,
		"and `mapinfo` answers what `nextmap` and `timeleft` would, without taking dot-vote's names"
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


## A disconnect actually reaches the module.
##
## [b]This is an ARITY check dressed as a behaviour check, and it is the only kind that
## could have caught what it caught.[/b] `DotServer.client_disconnected` emits
## `(session, reason)` and the handler took only the session, so Godot refused every call
## — "Method expected 1 argument(s), but called with 2" — and the handler never ran. No
## player was removed, no peer released, and the server kept building snapshots for
## clients that had gone, three engine errors a tick, for ever.
##
## Nothing here had ever disconnected: every other test in this file adds its players
## directly and the module is torn down at the end. So the bug needed a real browser
## client to show, and this is the check that means it will not need one again.
## Chat, voice, and the one join between them that has to work.
func _test_services() -> void:
	print("")
	print("chat and voice")

	var services: PlaygroundServices = _module().get("services")

	_check(services != null, "the services are up")
	_check(
		services.chat != null and services.chat.channel_ids().size() == 4,
		"with four chat channels (%d)"
			% (services.chat.channel_ids().size() if services.chat != null else -1)
	)
	_check(
		services.chat.channel(PlaygroundServices.CHANNEL_NEAR).scope
			== DotChatChannel.Scope.RADIUS,
		"one of which is a radius, so a build is a conversation"
	)
	_check(
		services.chat.channel(PlaygroundServices.CHANNEL_NEAR).backlog == 0,
		"and has no backlog, because a line said quietly beside a build must not be "
		+ "replayed to a stranger who was not standing there"
	)

	# [b]THE join.[/b] dot-chat consults a `dot_mute_source` and dot-moderation publishes
	# one, and neither imports the other — so the only thing that makes a gag work is that
	# something is registered under that name.
	_check(
		DotRegistry.has(DotModerationManager.MUTE_SERVICE),
		"a mute source is registered, which is the only thing that makes a gag work"
	)
	_check(
		DotRegistry.has(DotModerationManager.BAN_SERVICE),
		"and a ban source, which dot-server's admission check consults"
	)

	# [b]Voice is the whole server here, and the near channel is text's.[/b] The other two
	# games chose differently and all three are right for what they are — a lobby you can
	# see all of, an arena bigger than a screen, and a sandbox that is both at once.
	_check(
		services.voice != null
			and services.voice.default_channel == DotVoiceRouter.Channel.ALL,
		"voice reaches the whole server, and the near channel is text's"
	)
	_check(
		services.voice.config.format_fingerprint()
			== PlaygroundServices.voice_config().format_fingerprint(),
		"and its format is the one a client builds from the same file"
	)

	# dot-server's own chat is cancelled rather than run beside the router.
	var legacy := server.events.fire("player_chat", {
		"userid": 1, "name": "Nobody", "text": "hello", "team_only": false,
	})
	_check(
		legacy.cancelled,
		"dot-server's own chat broadcast is cancelled, so there is exactly one path"
	)

	# The wire, both directions. Every encoder against its decoder, because the two have
	# to be exact inverses and nothing can check that for you.
	var line := DotChatMessage.make(
		DotChatMessage.Kind.SAY, PlaygroundServices.CHANNEL_NEAR, "7", "Ada", "over here"
	)
	line.seq = 3

	var wire := line.to_dictionary()
	wire["x"] = {"p": 7}

	var back := PlaygroundEvents.read_chat(
		DotNetReader.new(PlaygroundEvents.write_chat(wire))
	)
	_check(bool(back["ok"]), "a chat line round-trips")
	_check(String(back["m"]) == "over here", "with the text")
	_check(
		String(back["c"]) == String(PlaygroundServices.CHANNEL_NEAR),
		"and the channel it was said on"
	)
	_check(
		typeof(back.get("x")) == TYPE_DICTIONARY
			and int((back["x"] as Dictionary).get("p", 0)) == 7,
		"and who said it, which is the one meta field this wire carries"
	)

	# Every value of the enum, because dot-moderation's bug was exactly one value with no
	# case — and the two ends of a serialisation are as capable of never meeting as the
	# two ends of a wire.
	var kinds_ok := true

	for kind in DotChatMessage.Kind.values():
		var one := DotChatMessage.make(
			kind as DotChatMessage.Kind, PlaygroundServices.CHANNEL_ALL, "1", "Ada", "x"
		)
		var round_trip := PlaygroundEvents.read_chat(
			DotNetReader.new(PlaygroundEvents.write_chat(one.to_dictionary()))
		)

		if String(round_trip["k"]) != one.kind_name():
			kinds_ok = false

	_check(kinds_ok, "every chat kind survives the wire, not just the common one")


## A gag, written and read back off disk.
func _test_moderation() -> void:
	print("")
	print("moderation")

	var services: PlaygroundServices = _module().get("services")
	var subject := DotPunishmentSubject.for_uid("uid-pg-test")

	var gagged: DotResult = await services.moderation.issue(
		DotPunishment.Kind.GAG, subject, "testing", "console", 60
	)
	_check(gagged.ok, "a gag is issued and stored", str(gagged.error))

	var reloaded := DotModerationManager.new()
	reloaded.store = DotPunishmentStoreFile.new(services.punishments_path)
	reloaded.register_mute_source = false
	reloaded.register_ban_source = false
	add_child(reloaded)
	reloaded.load_all()

	var found := reloaded.active_of_kind(subject, DotPunishment.Kind.GAG)
	_check(
		found != null and found.kind == DotPunishment.Kind.GAG,
		"and comes back off disk as a GAG rather than as a WARN",
		"the kind is written and read through one table for exactly this reason"
	)

	var muted: DotResult = await services.moderation.issue(
		DotPunishment.Kind.VOICE_MUTE, subject, "testing", "console", 60
	)
	_check(muted.ok, "a voice mute is issued", str(muted.error))
	_check(
		services.moderation.is_voice_muted_key(subject),
		"and reads back as a voice mute rather than as a warning"
	)
	reloaded.queue_free()


## Health, weapons that hurt, and a round.
func _test_arena() -> void:
	print("")
	print("the arena")

	var arena: PlaygroundArena = _module().get("arena")

	_check(arena != null, "the arena is built")
	_check(
		not arena.enabled,
		"and is OFF by default",
		"a server where somebody can shoot you while you are building is a different "
		+ "server, and an addon must not turn one into the other silently"
	)

	# The schema, which is what a dedicated server validates a loadout against without
	# loading a single model.
	var schema := arena.loadouts.schema
	var problems := schema.validate()
	_check(problems.ok, "the loadout schema validates", str(problems.error))
	_check(
		schema.slot(&"primary") != null and schema.slot(&"primary").required
			and schema.slot(&"primary").default_item != &"",
		"and its required slot has a default",
		"a required slot with none cannot be repaired, so a player who has never "
		+ "chosen could never spawn"
	)

	# [b]Entitlements default to nothing, and that default is the important one.[/b] A
	# server that granted everything would work perfectly in every test, ship, and
	# quietly be a game where every unlock is free — which nobody reports as a bug.
	var free_only := schema.choices_for(&"primary", DotLoadoutEntitlements.none())
	var everything := schema.choices_for(&"primary", DotLoadoutEntitlements.everything())
	_check(
		everything.size() > free_only.size(),
		"and something is locked (%d free of %d)" % [free_only.size(), everything.size()]
	)

	_run_command("pg_arena on")
	_check(arena.enabled, "the console turns it on")

	arena.admit(&"u900", "Alice")
	arena.admit(&"u901", "Bob")

	var alice := arena.health_of(&"u900")
	_check(alice != null and alice.health == PlaygroundArena.MAX_HEALTH,
		"somebody admitted starts on full health")

	# [b]Spawn protection is counted in ticks, and this is what it is for.[/b] A player
	# shot on the tick they appear has not had a game.
	_check(alice.is_protected(0), "and is protected on the tick they appear")

	# [b]Through the arena's own tick, not the health's.[/b] Spawn protection is checked
	# by `DotHealth.apply` against the tick the MANAGER last saw, and ticking only the
	# health leaves the manager on zero — so the protection reads as expired everywhere
	# except in the one place that decides. A test that ticked the health alone would pass
	# its own assertion and then be refused by the thing it was setting up.
	for step in range(game.tick_rate * 5):
		arena.tick(step, 1.0 / float(game.tick_rate))

	_check(
		not alice.is_protected(arena._tick),
		"and is not, five seconds later"
	)

	var hit := arena.hurt(&"u901", &"u900", 30.0, 5.0)
	_check(hit != null and not hit.refused, "a hit lands", str(hit))
	_check(
		alice.health < PlaygroundArena.MAX_HEALTH,
		"and takes health off (%.0f)" % alice.health
	)

	# Falloff. [b]The whole reason it is worth having[/b]: a shot from across the map has
	# to be worth less than one at point blank, or range is not a decision.
	var far := arena.hurt(&"u901", &"u900", 30.0, 200.0)
	_check(
		far != null and far.amount < hit.amount,
		"and one from across the map does less (%.1f against %.1f)"
			% [far.amount if far != null else -1.0, hit.amount]
	)

	# Self damage is on and scaled, because launching a boulder at your own feet hurting
	# you is the joke the weapon exists for — and hurting you as much as somebody else is
	# not.
	var own := arena.hurt(&"u900", &"u900", 30.0, 1.0)
	_check(
		own != null and not own.refused and own.amount < 30.0,
		"self damage lands and is scaled down (%.1f)"
			% (own.amount if own != null else -1.0)
	)

	arena.release(&"u900")
	arena.release(&"u901")
	_run_command("pg_arena off")
	_check(not arena.enabled, "and the console turns it off again")


## NPCs the server releases.
func _test_waves() -> void:
	print("")
	print("waves")

	var waves: PlaygroundWaves = _module().get("waves")

	_check(waves != null, "the wave layer is built")
	_check(not waves.is_enabled(), "and is off by default")
	_check(
		waves.spawner != null and not waves.spawner.two_dimensional,
		"its spawner is a 3D one"
	)
	_check(
		PlaygroundWaves.shared_catalogue().size() == 3,
		"with three kinds (%d)" % PlaygroundWaves.shared_catalogue().size()
	)

	# [b]Line of sight is ON here and off in the other two games, and that is the point of
	# the flag.[/b] A sandbox has walls, pillars and whatever somebody built; an NPC that
	# saw through all of it would make cover meaningless.
	var runner := PlaygroundWaves.shared_catalogue().get_npc(&"runner")
	_check(
		runner != null and runner.require_line_of_sight,
		"and they need to actually see you"
	)

	_run_command("pg_waves on")
	_check(waves.is_enabled(), "the console turns them on")

	# The director wants somebody to pace against. With nobody in the world it must not
	# spawn anything — a wave released at an empty server is a wave nobody meets and a
	# population budget spent on nothing.
	for _step in range(120):
		waves.tick(_step, 1.0 / float(game.tick_rate))

	_check(
		waves.count() == 0,
		"and release nothing with nobody playing (%d)" % waves.count(),
		"the director paces against players, and there are none"
	)

	_run_command("pg_waves off")
	_check(not waves.is_enabled(), "the console turns them off")


## Statistics, and what they are worth.
# --- The shop ---------------------------------------------------------------

func _test_shop() -> void:
	print("")
	print("the shop")

	var shop: PlaygroundShop = _module().get("shop")

	_check(shop != null, "the shop is built")

	if shop == null:
		return

	_check(
		not shop.enabled,
		"and is OFF by default",
		"a sandbox where everything is free is a sandbox and one where a jeep costs "
		+ "four hundred credits is a game; an addon must not turn one into the other"
	)

	# Free while it is off, and that is what makes it a layer a caller can consult
	# unconditionally rather than a branch at every call site.
	var free := shop.may_have(&"nobody", &"pg_crate")
	_check(free.ok, "everything is free while it is off", str(free.error))

	var prices := _run_command("pg_shop prices")
	_check(prices.size() > 3, "the price list can be read", "%d lines" % prices.size())

	# Derived from the catalogue rather than authored, which is why there are as many
	# entries as there are props and weapons.
	var expected := 0
	if game.props != null and game.props.catalogue != null:
		expected += game.props.catalogue.props.size()
	expected += game.weapons.size()
	_check(
		shop.economy.shop.items.size() == expected,
		"and has one entry per prop and weapon the game ships",
		"%d against %d" % [shop.economy.shop.items.size(), expected]
	)

	var _on := _run_command("pg_shop on")
	_check(shop.enabled, "it turns on")

	var buyer := &"shopper"
	shop.on_player_added(buyer)
	_check(
		shop.balance(buyer) == PlaygroundShop.START_CREDITS,
		"a player starts with credits",
		str(shop.balance(buyer))
	)

	# Something cheap, then everything, then something at all.
	var cheapest := shop.economy.shop.for_team(1)[0]
	var bought := shop.charge(buyer, cheapest.id)
	_check(bought.ok, "and can buy the cheapest thing", str(bought.error))
	_check(
		shop.balance(buyer) == PlaygroundShop.START_CREDITS - cheapest.price,
		"which costs what it says",
		str(shop.balance(buyer))
	)

	var _spent := shop.award(buyer, -shop.balance(buyer), &"test")
	var refused := shop.charge(buyer, cheapest.id)
	_check(
		not refused.ok,
		"and cannot buy anything with nothing"
	)
	_check(
		refused.error.message.contains("short"),
		"with a message that says how short they are",
		refused.error.message
	)

	shop.on_wave_kill(buyer)
	_check(
		shop.balance(buyer) == PlaygroundShop.WAVE_KILL,
		"killing something the director sent pays",
		str(shop.balance(buyer))
	)

	var _off := _run_command("pg_shop off")
	_check(not shop.enabled, "and it turns off again")
	_check(
		shop.may_have(buyer, cheapest.id).ok,
		"after which everything is free again even with an empty account"
	)


# --- Spectating -------------------------------------------------------------

func _test_spectating() -> void:
	print("")
	print("spectating")

	var spectate: PlaygroundSpectate = _module().get("spectate")

	_check(spectate != null, "the spectate layer is built")

	if spectate == null:
		return

	_check(
		spectate.manager.rules.force_camera == 0,
		"and anybody may watch anybody in a sandbox",
		str(spectate.manager.rules.force_camera)
	)
	_check(
		spectate.manager.rules.allow_roaming,
		"with a free camera, which is how you look at a contraption from the outside"
	)

	# And the moment it stops being a sandbox.
	spectate.set_fighting(true)
	_check(
		spectate.manager.rules.force_camera == 1
		and not spectate.manager.rules.allow_roaming,
		"and the policy tightens when the arena is on, because a living player "
		+ "watching a living one while they shoot at each other is a wallhack"
	)
	spectate.set_fighting(false)
	_check(
		spectate.manager.rules.force_camera == 0,
		"and loosens again when it is off"
	)


# --- Down rather than dead ---------------------------------------------------

func _test_downed() -> void:
	print("")
	print("down rather than dead")

	var downs: PlaygroundDowns = _module().get("downs")
	var arena: PlaygroundArena = _module().get("arena")

	_check(downs != null, "the downs layer is built")

	if downs == null or arena == null:
		return

	_check(
		not downs.enabled,
		"and is off while the waves are",
		"a sandbox where nobody dies is a very confusing bug"
	)
	_check(
		arena.death_rule_fn.is_valid(),
		"the arena asks it before reporting a death, so the rule lives in ONE place "
		+ "rather than at every damage site"
	)
	_check(
		StringName(str(downs.report_zero_health(&"nobody"))) == &"dead",
		"and while it is off, zero health is death"
	)

	var _on := _run_command("pg_waves on")
	_check(
		downs.enabled,
		"turning the waves on turns it on too, because being killed by a wave is what "
		+ "it is for"
	)

	var victim := &"faller"
	var helper := &"lifter"
	_check(
		StringName(str(downs.report_zero_health(victim))) == &"down",
		"and now zero health is going down"
	)
	_check(downs.is_down(victim), "they are down")

	var state := downs.state_of(victim)
	_check(state != null and state.incaps == 1, "for the first time")
	_check(
		state != null and is_equal_approx(state.health, downs.effects.rules.downed_health),
		"with a full bleed-out pool"
	)

	# Nobody near them: the revive is refused rather than silently doing nothing.
	var far := downs.begin_revive(victim, helper)
	_check(
		not far.ok,
		"and nobody picks them up from across the map",
		str(far.error)
	)

	# Bleeding out is a death the scoreboard still has to hear about, and the arena's
	# own path was skipped when they went down. This is the other end of that decision.
	for _i in range(int(downs.effects.rules.bleed_out_ticks()) + 4):
		downs.tick(1.0 / float(game.tick_rate))
		game.tick_once(game.current_tick() + 1)

	_check(
		not downs.is_down(victim),
		"and a player nobody picks up bleeds out"
	)
	_check(
		downs.state_of(victim).is_dead(),
		"and is dead rather than still lying there"
	)

	var _off := _run_command("pg_waves off")
	_check(not downs.enabled, "turning the waves off turns it off")


func _test_progress() -> void:
	print("")
	print("statistics and achievements")

	var progress: PlaygroundProgress = _module().get("progress")

	_check(progress != null, "the progress layer is built")
	_check(
		progress.stats != null and progress.stats.schema.size() >= 9,
		"with a stats schema (%d)"
			% (progress.stats.schema.size() if progress.stats != null else -1)
	)
	_check(progress.link != null, "and a link from the stats to the achievements")

	# [b]Every stat an achievement watches has to be one the game declares.[/b] An
	# achievement watching a stat nothing reports never unlocks, nothing errors, and the
	# only symptom is a player who did the thing and was not told.
	var schema := PlaygroundProgress.stats_schema()
	var missing := PackedStringArray()

	for stat in progress.achievements.catalogue.watched_stats():
		if not schema.has(stat):
			missing.append(String(stat))

	_check(
		missing.is_empty(),
		"every watched stat is one the game declares",
		"missing: %s" % str(missing)
	)

	var problems := progress.achievements.catalogue.validate()
	_check(problems.ok, "the catalogue validates", str(problems.error))

	# [b]Wipe this player's stored progress first.[/b] `DotAchievementStoreFile` writes to
	# `user://`, so every run of this suite ADDED sixty spawns to whatever the last one
	# left — and after about nine runs the "and not the second" check below crossed 500
	# and started failing for ever, on a tree with no changes in it. A suite that carries
	# state between runs is a suite whose result depends on how many times it has been
	# run, which is the one thing a check must not depend on.
	#
	# Matched by substring rather than by a filename this test would have to know: the
	# store's naming is the store's business, and a second copy of it here is the
	# family's most repeated bug in miniature.
	_forget_stored_progress(progress, "pg-test")

	progress.begin("pg-test")

	for _one in range(60):
		progress.achievements.record("pg-test", &"props", 1.0)

	_check(
		progress.achievements.is_unlocked("pg-test", &"build_50"),
		"fifty spawns unlocks the first tier"
	)
	_check(
		not progress.achievements.is_unlocked("pg-test", &"build_500"),
		"and not the second"
	)

	# A LOWEST merge, which is the other end of dot-stats' four kinds — and the reason
	# `DotAchievementRule.Merge` is deliberately the same table: the two would otherwise
	# disagree about what a new reading does to an old one.
	progress.achievements.record("pg-test", &"fastest_run", 40.0)
	progress.achievements.record("pg-test", &"fastest_run", 18.0)
	progress.achievements.record("pg-test", &"fastest_run", 55.0)
	_check(
		progress.achievements.is_unlocked("pg-test", &"under_20"),
		"a best time keeps the LOWEST reading, not the newest"
	)

	var written: DotResult = await progress.achievements.flush()
	_check(written.ok, "progress writes to disk", str(written.error))


## What plays next, decided by the players.
func _test_vote() -> void:
	print("")
	print("the vote")

	var vote: PlaygroundVote = _module().get("vote")

	_check(vote != null, "the vote is built")
	_check(
		vote.director != null and vote.director.source != null
			and vote.director.source.is_usable(),
		"with a source over dot-map's own catalogue",
		"one engine, two sources — game-hungario votes over games and this votes over "
		+ "maps, and neither file names the other"
	)

	var options := vote.director.build_options(2)
	_check(options.size() > 0, "a ballot has something on it (%d)" % options.size())

	var next := vote.next_in_rotation()
	_check(next != &"", "something is next in the rotation (%s)" % String(next))
	_check(
		game.maps.current == null or next != game.maps.current.id,
		"and it is not the map that is playing"
	)

	# Rocking the vote with nobody playing. The threshold is a fraction of the head count
	# and `rtv_min_players` is 2, so this is refused — which is the check: a refusal that
	# ARRIVES is a rule that ran, and dot-vote shipped a version where rocking the vote
	# was refused for ever on the deployment that depends on it.
	var rocked := vote.director.rock_the_vote(&"u1")
	_check(
		rocked != null,
		"rocking the vote answers rather than doing nothing",
		str(rocked.error) if not rocked.ok else "accepted"
	)

	_check(
		not vote.director.begin_on_apply,
		"the director does not announce its own change",
		"the host announces it, which also fires for an operator typing pg_map — both "
		+ "firing halves every cooldown"
	)

	_check(
		vote.director.rules.nomination_seconding,
		"seconding is allowed, which is what makes MOST_NOMINATED mean anything",
		"without it every nomination count is exactly 1 and there is nothing to sort by"
	)


## Profiles and avatars: ids and a schema, and no art anywhere.
func _test_identity() -> void:
	print("")
	print("identity")

	_check(platform.hub != null and platform.hub.is_ready(), "the platform is up")
	_check(
		server.modules.get_module("platform") != null,
		"and its module is loaded beside the game's"
	)

	var schema := PlaygroundPlatform.avatar_schema()
	var problems := schema.validate_schema()

	# [b]A schema that validates is not a formality.[/b] game-hungario shipped a part that
	# was its own fallback — a resolution loop that cannot terminate — and its suite never
	# noticed, because it never validated a schema.
	_check(problems.ok, "the avatar schema is valid", str(problems.error))

	var legal := DotAvatar.make(&"pg_builder")
	legal.set_part(&"body", &"body_overalls")
	legal.set_part(&"hat", &"hat_cap")

	_check(
		schema.validate(legal, DotAvatarEntitlements.none()).ok,
		"a free avatar is accepted with no entitlements at all"
	)

	var locked := DotAvatar.make(&"pg_builder")
	locked.set_part(&"body", &"body_plain")
	locked.set_part(&"hat", &"hat_hard")

	# [b]Entitlements default to nothing and that default is the important one.[/b] A
	# server that granted everything would work perfectly in every test, ship, and quietly
	# be a game where every unlock is free — which nobody reports as a bug.
	_check(
		not schema.validate(locked, DotAvatarEntitlements.none()).ok,
		"and one nobody has unlocked is refused"
	)
	_check(
		schema.validate(locked, DotAvatarEntitlements.of([&"hat_hard"])).ok,
		"until they hold it"
	)

	# [b]The key a statistic is filed under, and the reason dot-platform is here at
	# all.[/b] dot-stats refuses an account id as a player key before it leaves the
	# server, and a board is exactly the same kind of record — so the one function that
	# decides has to give a scoped id when there is an identity stack and something
	# honest when there is not.
	var key := PlaygroundPlatform.key_for_session(server, null)
	_check(key == "", "no session is no key rather than a guessed one")

	_check(
		PlaygroundProgress.stats_schema().has(&"props"),
		"the stats schema declares what the game reports"
	)


func _test_disconnect_is_handled() -> void:
	print("a client disconnecting reaches the module")

	var session := DotClientSession.new()
	session.userid = 4242
	session.peer_id = 0
	session.display_name = "Leaver"

	game.add_player(&"u4242", "Leaver")
	_check(game.players.has(&"u4242"), "a player is in the game")

	# Emitted with BOTH arguments, exactly as DotServer emits it. A handler with the
	# wrong arity is refused by the engine rather than adapted to.
	server.client_disconnected.emit(session, "closed")

	_check(
		not game.players.has(&"u4242"),
		"and the disconnect took them back out again"
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


## Deletes any file the achievement store has written for [param player].
##
## The store is a directory of files under `user://` and it is not part of what this
## suite is testing; what matters is that a run starts from nothing. Failing to open the
## directory is not an error — the first run on a machine has no directory yet.
func _forget_stored_progress(progress: PlaygroundProgress, player: String) -> void:
	var dir := DirAccess.open(progress.progress_dir)

	if dir == null:
		return

	for file in dir.get_files():
		if file.contains(player):
			dir.remove(file)
