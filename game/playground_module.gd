extends DotModule

## Binds a [Playground] to a [DotServer]: the console commands an operator and an
## admin actually type.
##
## [b]This is the only file in the project that names dot-server[/b], which is where
## the family's own documentation says such a bridge belongs — dot-timer does not
## import dot-server, dot-map does not, and dot-props does not, so a game that wants
## a dedicated server writes one file and it is this one.
##
## [codeblock]
## server.modules.load_module("res://game/playground_module.gd")
## [/codeblock]
##
## [b]The commands are the point of the module, not a garnish.[/b] A surf or bhop
## server is administered from a console: maps are changed, zones are drawn on maps
## whose authors never used this engine, styles are switched, and props are cleared
## when somebody has built a wall across the start. Without a console, every one of
## those needs a code change — which is exactly the position community servers were
## in before their admin plugins, and the reason console zone tools exist.
##
## The zone commands reproduce that workflow deliberately: stand on one corner, run
## the command, stand on the other, run it again.

const CHANNEL := "playground.module"

var game: Playground = null

## Per-admin zone painters, by session user id.
##
## One each, because two admins drawing at once would otherwise share a first corner
## — and the failure is a zone spanning the distance between them, saved, with
## nothing to say it was not meant.
var _painters: Dictionary = {}


func _module_name() -> String:
	return "playground"


func _module_version() -> String:
	return "0.1.0"


func _module_description() -> String:
	return "Surf, bunny-hop and a sandbox: timers, maps, zones and props."


func _module_author() -> String:
	return "dot"


func _module_load() -> DotResult:
	game = DotRegistry.get_node_service(Playground.SERVICE) as Playground

	if game == null:
		# Refusing to load is right. A module that loaded and did nothing would leave
		# a server that accepts players into a game that does not exist, and the
		# symptom is players who connect and never spawn.
		return DotResult.fail(
			DotError.CODE_STATE,
			"No Playground is registered. Create one before loading this module."
		)

	# --- The timer ---------------------------------------------------------
	add_command(
		"pg_timer", _cmd_timer,
		"Show a player's run, or your own", ""
	)
	add_command(
		"pg_restart", _cmd_restart,
		"Put yourself back at the map's spawn and abandon the run", ""
	)
	add_command(
		"pg_style", _cmd_style,
		"List the styles, or switch to one", ""
	)
	add_command(
		"pg_track", _cmd_track,
		"Switch track: main, or bonus <n>", ""
	)
	add_command(
		"pg_top", _cmd_top,
		"The fastest times on this map, track and style", ""
	)

	# --- Practice ----------------------------------------------------------
	add_command("pg_cp", _cmd_checkpoint, "Save a practice checkpoint", "")
	add_command("pg_tp", _cmd_teleport, "Go back to a practice checkpoint", "")
	add_command("pg_cp_clear", _cmd_checkpoint_clear, "Forget them all", "")

	# --- Zones, the sm_zones workflow --------------------------------------
	#
	# CHANGEMAP rather than GENERIC: drawing a start line is editing the map's rules,
	# and somebody who can do it can invalidate every record on it.
	add_command(
		"pg_zone", _cmd_zone,
		"Draw a zone: pg_zone <start|end|stage|respawn|stop> [track] [number]",
		DotAdminFlags.CHANGEMAP
	)
	add_command(
		"pg_zone_mark", _cmd_zone_mark,
		"Mark a corner where you are standing",
		DotAdminFlags.CHANGEMAP
	)
	add_command(
		"pg_zone_spawn", _cmd_zone_spawn,
		"Set this track's spawn where you are standing",
		DotAdminFlags.CHANGEMAP
	)
	add_command(
		"pg_zone_list", _cmd_zone_list, "List this map's zones",
		DotAdminFlags.CHANGEMAP
	)
	add_command(
		"pg_zone_undo", _cmd_zone_undo, "Remove the last zone drawn",
		DotAdminFlags.CHANGEMAP
	)
	add_command(
		"pg_zone_save", _cmd_zone_save, "Write this map's zones to disk",
		DotAdminFlags.CHANGEMAP
	)

	# --- Maps --------------------------------------------------------------
	add_command(
		"pg_map", _cmd_map, "Change map, or list what there is",
		DotAdminFlags.CHANGEMAP
	)
	add_command("pg_nextmap", _cmd_nextmap, "What plays next, and how long is left", "")
	add_command("pg_rtv", _cmd_rtv, "Rock the vote", "")
	add_command(
		"pg_extend", _cmd_extend, "Extend the current map",
		DotAdminFlags.CHANGEMAP
	)

	# --- Props -------------------------------------------------------------
	add_command("pg_prop", _cmd_prop, "Spawn a prop in front of you", "")
	add_command("pg_undo", _cmd_undo, "Remove the last prop you spawned", "")
	add_command(
		"pg_props_clear", _cmd_props_clear,
		"Remove every prop, or one player's",
		DotAdminFlags.GENERIC
	)

	add_command("pg_status", _cmd_status, "What this server is doing", "")

	# The tick rate is dot-server's `sv_tickrate` and is deliberately not duplicated
	# here. A second cvar for the same number is a second number that can disagree
	# with the first, and the timer reads the engine — see
	# `DotTimerManager.adopt_engine_tick_rate`.
	add_cvar(
		"pg_map_seconds",
		str(int(game.maps.time_limit.duration)),
		"Seconds a map runs before the next one is chosen. 0 disables it."
	)

	server.client_disconnected.connect(_on_client_disconnected)
	game.maps.map_over.connect(_on_map_over)
	game.run_filed.connect(_on_run_filed)

	hook_post("client_spawn", _on_client_spawn)

	log_info("playground loaded", {
		"map": String(game.maps.current.id) if game.maps.current != null else "-",
		"tick_rate": game.tick_rate,
	})

	return DotResult.success(null)


func _module_unload() -> void:
	if server != null and server.client_disconnected.is_connected(_on_client_disconnected):
		server.client_disconnected.disconnect(_on_client_disconnected)

	if game != null and is_instance_valid(game):
		if game.maps.map_over.is_connected(_on_map_over):
			game.maps.map_over.disconnect(_on_map_over)
		if game.run_filed.is_connected(_on_run_filed):
			game.run_filed.disconnect(_on_run_filed)

		# Every player this module put in the game comes back out. A module that
		# unloaded and left them would leave the game holding players whose sessions
		# no longer exist — and the next record filed would be attributed to a ghost.
		for id in game.players.keys():
			game.remove_player(id)

	_painters.clear()


# --- Sessions --------------------------------------------------------------

## A client finished the signon and is in the world.
##
## `client_spawn`, not `client_connected`: a connected client has a socket and
## nothing else — no identity, no content, no confirmation it can load the map.
func _on_client_spawn(event: DotEvent) -> void:
	var session := server.session_of(event.get_int("peer_id"))

	if session == null:
		return

	var id := _player_id(session)

	if game.players.has(id):
		return

	game.add_player(id, session.label())

	log_info("player joined the game", {"player": String(id)})


func _on_client_disconnected(session: DotClientSession) -> void:
	var id := _player_id(session)

	_painters.erase(id)
	game.remove_player(id)


## The id the game files records under.
##
## [b]The session's own scoped id, not a site account.[/b] The identity layer hands a
## server a per-scope pseudonymous id precisely so operators cannot correlate their
## players across servers, and a records table keyed on anything global would undo
## that for every server running this.
func _player_id(session: DotClientSession) -> StringName:
	return StringName("u%d" % session.userid)


# --- Helpers ---------------------------------------------------------------

## The player a command is about: a named one for an admin, otherwise the caller.
func _target(ctx: DotCmdContext, allow_named: bool = true) -> StringName:
	if allow_named and ctx.args.size() > 0 and ctx.session == null:
		# Only from the server console: letting a player name somebody else would be
		# letting them restart a stranger's run.
		return StringName(ctx.args[0])

	if ctx.session == null:
		return &""

	return _player_id(ctx.session)


func _caller(ctx: DotCmdContext) -> PlaygroundPlayer:
	var id := _target(ctx, false)

	if id == &"":
		return null

	var found: Variant = game.players.get(id)
	return found if found is PlaygroundPlayer else null


func _painter_for(id: StringName) -> DotTimerZonePainter:
	if not _painters.has(id):
		_painters[id] = DotTimerZonePainter.on(game.timers.zones)

	var painter: DotTimerZonePainter = _painters[id]

	# Re-pointed every time rather than once: the map may have changed since this
	# admin last drew anything, and a painter still holding the previous map's set
	# would add zones to a map nobody is on.
	painter.zones = game.timers.zones

	return painter


# --- Timer commands --------------------------------------------------------

func _cmd_timer(ctx: DotCmdContext) -> void:
	var id := _target(ctx)
	var run := game.timers.run_for(id)

	if run == null:
		ctx.reply("No timer for %s." % String(id))
		return

	ctx.reply_lines(run.describe_lines())


func _cmd_restart(ctx: DotCmdContext) -> void:
	var id := _target(ctx)

	if not game.players.has(id):
		ctx.reply("You are not in the game.")
		return

	game.spawn_player(id)
	ctx.reply("Back at the start.")


func _cmd_style(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		var lines := PackedStringArray(["Styles:"])

		for style in game.timers.styles_in_order():
			lines.append("  %-16s %-4s %s" % [
				String(style.id),
				style.short_name,
				"unranked" if not style.ranked else "x%.2f points" % style.points_multiplier,
			])

		ctx.reply_lines(lines)
		return

	var id := _target(ctx, false)

	if id == &"" or not game.players.has(id):
		ctx.reply("Only a player can switch style.")
		return

	var wanted := StringName(ctx.args[0])

	if not game.set_player_style(id, wanted):
		ctx.reply("No such style: %s" % ctx.args[0])
		return

	ctx.reply("Style: %s" % String(wanted))


func _cmd_track(ctx: DotCmdContext) -> void:
	var id := _target(ctx, false)

	if id == &"" or not game.players.has(id):
		ctx.reply("Only a player can switch track.")
		return

	if ctx.args.is_empty():
		ctx.reply("Track: %s" % DotTimerTrack.name_of(game.timers.timer_for(id).track))
		return

	var track := DotTimerTrack.parse(" ".join(Array(ctx.args)))

	if track < 0:
		# Refused rather than falling back to the main track: a command that quietly
		# read "bonus 9" as "main" would put somebody on a track they did not ask
		# for, and file their record there.
		ctx.reply("No such track: %s" % " ".join(Array(ctx.args)))
		return

	if not game.timers.set_player_track(id, track):
		ctx.reply("Already on %s." % DotTimerTrack.name_of(track))
		return

	game.spawn_player(id)
	ctx.reply("Track: %s" % DotTimerTrack.name_of(track))


func _cmd_top(ctx: DotCmdContext) -> void:
	if game.maps.current == null or game.timers.store == null:
		ctx.reply("No records here.")
		return

	var id := _target(ctx, false)
	var timer := game.timers.timer_for(id)

	var track := timer.track if timer != null else DotTimerTrack.MAIN
	var style: StringName = (
		timer.style.id if timer != null and timer.style != null else &"normal"
	)

	var listed := game.timers.store.top(game.maps.current.id, track, style, 10)

	if not listed.ok:
		ctx.reply_error(listed)
		return

	var rows: Array = listed.value

	if rows.is_empty():
		ctx.reply("Nobody has finished %s on %s yet." % [
			String(game.maps.current.id), String(style)
		])
		return

	var lines := PackedStringArray(["%s — %s, %s:" % [
		game.maps.current.name_or_id(), DotTimerTrack.name_of(track), String(style)
	]])

	for i in range(rows.size()):
		var record: DotTimerRecord = rows[i]
		lines.append("  %2d. %-20s %s" % [
			i + 1, record.player_name, record.formatted_time()
		])

	ctx.reply_lines(lines)


# --- Practice --------------------------------------------------------------

func _cmd_checkpoint(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)

	if player == null:
		ctx.reply("Only a player has checkpoints.")
		return

	var checkpoints := game.timers.checkpoints_for(player.player_id)
	var state := player.controller.state

	var saved := checkpoints.save(
		state.position, state.velocity, state.yaw, state.pitch,
		state.is_grounded(), state.is_crouched()
	)

	if not saved.ok:
		ctx.reply_error(saved)
		return

	ctx.reply("Checkpoint %d saved." % checkpoints.count())


func _cmd_teleport(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)

	if player == null:
		ctx.reply("Only a player has checkpoints.")
		return

	var checkpoints := game.timers.checkpoints_for(player.player_id)

	if ctx.args.size() > 0 and ctx.args[0].is_valid_int():
		checkpoints.index = clampi(
			ctx.args[0].to_int() - 1, 0, maxi(checkpoints.count() - 1, 0)
		)

	# load_current(), not peek(): this is the teleport, and the teleport is what
	# taints the run. Peeking at a checkpoint costs nothing.
	var checkpoint := checkpoints.load_current()

	if checkpoint == null:
		ctx.reply("You have no checkpoints. pg_cp saves one.")
		return

	player.teleport(checkpoint.position, checkpoint.yaw)
	player.controller.state.velocity = checkpoint.velocity
	player.controller.state.pitch = checkpoint.pitch

	ctx.reply("Checkpoint %d of %d." % [
		checkpoints.index + 1, checkpoints.count()
	])


func _cmd_checkpoint_clear(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)

	if player == null:
		ctx.reply("Only a player has checkpoints.")
		return

	game.timers.checkpoints_for(player.player_id).clear()
	ctx.reply("Checkpoints cleared. The current run is still flagged.")


# --- Zone commands ---------------------------------------------------------

## Where a zone command marks from.
##
## An admin's feet when a player runs it, and the map's spawn from the server
## console — because somebody typing into a terminal has no position, and refusing
## them outright would make the whole workflow unusable over RCON.
func _mark_position(ctx: DotCmdContext) -> Vector3:
	var player := _caller(ctx)

	if player != null:
		return player.controller.state.position

	var map := game.current_map_node()

	return map.spawn_for(DotTimerTrack.MAIN) if map != null else Vector3.ZERO


func _cmd_zone(ctx: DotCmdContext) -> void:
	if game.timers.zones == null:
		ctx.reply("This map has no zone set to draw into.")
		return

	if ctx.args.is_empty():
		ctx.reply("pg_zone <start|end|stage|respawn|stop|teleport> [track] [number]")
		return

	var kinds := {
		"start": DotTimerZone.Kind.START,
		"end": DotTimerZone.Kind.END,
		"stage": DotTimerZone.Kind.STAGE,
		"respawn": DotTimerZone.Kind.RESPAWN,
		"stop": DotTimerZone.Kind.STOP,
		"teleport": DotTimerZone.Kind.TELEPORT,
		"slay": DotTimerZone.Kind.SLAY,
	}

	var wanted := ctx.args[0].to_lower()

	if not kinds.has(wanted):
		ctx.reply("No such zone kind: %s" % ctx.args[0])
		return

	# The track may be one token (`b3`, `main`, `2`) or two (`bonus 3`), because
	# both are what somebody types. Reading only the first silently turned
	# `bonus 99` into bonus 1 — the parse of "bonus" alone — and then read the 99 as
	# the stage number, so an impossible track became a plausible zone on the wrong
	# one. Consuming the second token when the first is a bare `bonus` is what makes
	# the refusal reachable.
	var track := DotTimerTrack.MAIN
	var consumed := 1

	if ctx.args.size() > 1:
		var text := ctx.args[1]
		var bare := text.to_lower()

		if (bare == "bonus" or bare == "b") and ctx.args.size() > 2:
			text = "%s %s" % [text, ctx.args[2]]
			consumed = 2

		track = DotTimerTrack.parse(text)

		if track < 0:
			ctx.reply("No such track: %s" % text)
			return

	var number := 0.0
	var number_index := consumed + 1

	if ctx.args.size() > number_index and ctx.args[number_index].is_valid_float():
		number = ctx.args[number_index].to_float()

	var painter := _painter_for(_target(ctx, false))
	var began := painter.begin(kinds[wanted], track, number)

	if not began.ok:
		ctx.reply_error(began)
		return

	ctx.reply(
		"Drawing a %s zone on %s. Stand on one corner and run pg_zone_mark, then the other."
		% [wanted, DotTimerTrack.name_of(track)]
	)


func _cmd_zone_mark(ctx: DotCmdContext) -> void:
	var painter := _painter_for(_target(ctx, false))

	if painter.zones == null:
		ctx.reply("This map has no zone set to draw into.")
		return

	var marked := painter.mark(_mark_position(ctx))

	if not marked.ok:
		ctx.reply_error(marked)
		return

	if marked.value == null:
		ctx.reply("First corner. Now stand on the opposite one and run it again.")
		return

	var zone: DotTimerZone = marked.value

	# Rebound immediately, so the zone is live for everybody the moment it is drawn.
	# An admin who had to reload the map to test a start line would test it once.
	game.timers.set_zones(painter.zones)

	ctx.reply("Drew %s. %s" % [str(zone), " ".join(Array(painter.zones.problems()))])


func _cmd_zone_spawn(ctx: DotCmdContext) -> void:
	var painter := _painter_for(_target(ctx, false))

	if painter.zones == null:
		ctx.reply("This map has no zone set.")
		return

	var track := DotTimerTrack.MAIN

	if ctx.args.size() > 0:
		track = DotTimerTrack.parse(ctx.args[0])

		if track < 0:
			ctx.reply("No such track: %s" % ctx.args[0])
			return

	painter.track = track

	var player := _caller(ctx)
	var yaw := player.controller.state.yaw if player != null else 0.0

	var marked := painter.mark_point(_mark_position(ctx), yaw)

	if not marked.ok:
		ctx.reply_error(marked)
		return

	game.timers.set_zones(painter.zones)
	ctx.reply("%s spawns here." % DotTimerTrack.name_of(track))


func _cmd_zone_list(ctx: DotCmdContext) -> void:
	if game.timers.zones == null:
		ctx.reply("This map has no zones.")
		return

	var painter := _painter_for(_target(ctx, false))
	var lines := painter.summary()

	if lines.is_empty():
		ctx.reply("No zones drawn yet.")
		return

	ctx.reply_lines(lines)


func _cmd_zone_undo(ctx: DotCmdContext) -> void:
	var painter := _painter_for(_target(ctx, false))
	var undone := painter.undo()

	if not undone.ok:
		ctx.reply_error(undone)
		return

	game.timers.set_zones(painter.zones)
	ctx.reply("Removed %s." % str(undone.value))


func _cmd_zone_save(ctx: DotCmdContext) -> void:
	if game.timers.zones == null:
		ctx.reply("This map has no zones to save.")
		return

	var problems := game.timers.zones.problems()

	if not problems.is_empty():
		# Refused rather than saved with a warning. A zone file with a start and no
		# end is playable and unfinishable, and the moment it is on disk somebody
		# else has a copy.
		ctx.reply("Not saving — fix these first:")
		ctx.reply_lines(problems)
		return

	var path := "user://zones/%s.json" % String(game.timers.zones.map_id)

	if ctx.args.size() > 0:
		path = ctx.args[0]

	var wrote := game.timers.zones.save_json(path)

	if not wrote.ok:
		ctx.reply_error(wrote)
		return

	ctx.reply("Wrote %s (%d zones, %s)." % [
		path, game.timers.zones.zones.size(), game.timers.zones.fingerprint()
	])


# --- Map commands ----------------------------------------------------------

func _cmd_map(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		var lines := PackedStringArray(["Maps:"])

		for map in game.maps.catalogue.maps:
			lines.append("  %-24s tier %d  %s%s" % [
				String(map.id), map.tier, String(map.kind),
				"" if map.enabled else "  (disabled)",
			])

		ctx.reply_lines(lines)
		return

	var found := game.maps.catalogue.search(ctx.args[0])

	if found.is_empty():
		ctx.reply("No map matches '%s'." % ctx.args[0])
		return

	if found.size() > 1:
		var names := PackedStringArray()
		for map in found:
			names.append(String(map.id))
		ctx.reply("Which one? %s" % ", ".join(names))
		return

	ctx.reply("Changing to %s." % found[0].name_or_id())

	var changed: DotResult = await game.change_map(found[0].id)

	if not changed.ok:
		ctx.reply_error(changed)


func _cmd_nextmap(ctx: DotCmdContext) -> void:
	var next := game.maps.rotation.choose(game.players.size())

	ctx.reply("Next: %s   ·   %s left   ·   %d rocked the vote (%d needed)" % [
		next.name_or_id() if next != null else "-",
		game.maps.time_limit.formatted_remaining(),
		game.maps.time_limit.rtv_votes(),
		game.maps.time_limit.rtv_needed(game.players.size()),
	])


func _cmd_rtv(ctx: DotCmdContext) -> void:
	var id := _target(ctx, false)

	if id == &"":
		ctx.reply("Only a player can rock the vote.")
		return

	if game.maps.time_limit.has_rocked(id):
		# Said rather than silently ignored: typing it twice is what somebody does
		# when nothing visible happened, and "nothing happened again" is the worst
		# possible answer.
		ctx.reply("You have already rocked the vote. %d of %d." % [
			game.maps.time_limit.rtv_votes(),
			game.maps.time_limit.rtv_needed(game.players.size()),
		])
		return

	if game.rock_the_vote(id):
		ctx.reply("The vote passed.")
		return

	ctx.reply("%d of %d." % [
		game.maps.time_limit.rtv_votes(),
		game.maps.time_limit.rtv_needed(game.players.size()),
	])


func _cmd_extend(ctx: DotCmdContext) -> void:
	var seconds := -1.0

	if ctx.args.size() > 0 and ctx.args[0].is_valid_float():
		seconds = ctx.args[0].to_float()

	if not game.maps.extend_map(seconds):
		ctx.reply("This map has been extended as often as it may be.")
		return

	ctx.reply("Extended. %s left." % game.maps.time_limit.formatted_remaining())


# --- Prop commands ---------------------------------------------------------

func _cmd_prop(ctx: DotCmdContext) -> void:
	var player := _caller(ctx)

	if player == null:
		ctx.reply("Only a player can spawn props.")
		return

	if ctx.args.is_empty():
		# Grouped, because a flat list of fourteen ids in a console window is
		# unreadable and a delivered catalogue is four hundred. The categories are
		# the same ones the spawn menu tabs on, so what an admin sees here and what
		# a player sees in the menu cannot drift apart.
		for category in game.props.catalogue.categories():
			var names := PackedStringArray()

			for prop in game.props.catalogue.in_category(StringName(category)):
				names.append(String(prop.id))

			ctx.reply("%s: %s" % [category.capitalize(), ", ".join(names)])

		return

	var found := game.props.catalogue.search(ctx.args[0])

	if found.is_empty():
		ctx.reply("No prop matches '%s'." % ctx.args[0])
		return

	var at := player.eye_position() + player.aim_direction() * 3.0
	var spawned := game.props.spawn(found[0].id, player.player_id, at)

	# The refusal reason reaches the player through the spawner's own signal, which
	# the HUD is already listening to — so this says nothing on failure rather than
	# saying it twice.
	if spawned != null:
		ctx.reply("Spawned %s." % found[0].name_or_id())


func _cmd_undo(ctx: DotCmdContext) -> void:
	var id := _target(ctx, false)

	if id == &"" or not game.props.undo(id):
		ctx.reply("Nothing to undo.")
		return

	ctx.reply("Removed.")


func _cmd_props_clear(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		var count := game.props.clear_all(DotPropSpawner.REASON_ADMIN)
		ctx.reply("Removed %d props." % count)
		return

	var count := game.props.clear_player(
		StringName(ctx.args[0]), DotPropSpawner.REASON_ADMIN
	)
	ctx.reply("Removed %d of %s's props." % [count, ctx.args[0]])


# --- Status ----------------------------------------------------------------

func _cmd_status(ctx: DotCmdContext) -> void:
	ctx.reply_lines(game.describe_lines())


func _on_map_over(_map: DotMapDef, reason: StringName) -> void:
	log_info("the map is over", {"reason": String(reason)})


func _on_run_filed(
	player_id: StringName, run: DotTimerRun, rank: int, reason: String
) -> void:
	if reason != "":
		log_info("a run was not recorded", {
			"player": String(player_id), "why": reason
		})
		return

	log_info("a run was recorded", {
		"player": String(player_id), "time": run.formatted_time(), "rank": rank
	})
