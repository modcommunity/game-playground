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

## The netcode, and the seam that joins it to the game. Built here because a module is
## what a dedicated server loads and unloads, so the netcode goes away with the game
## rather than outliving it.
var net: DotNetManager = null
var bridge: PlaygroundNetBridge = null

## Chat, moderation and voice. Built here rather than in the game, because they are about
## the people connected rather than about the world.
var services: PlaygroundServices = null

## Health, weapons that hurt, and a round. Off unless an operator turns it on.
var arena: PlaygroundArena = null

## NPCs the server releases, paced by a director. Also off by default.
var waves: PlaygroundWaves = null

## A price list over the spawn menu, when an operator has turned one on. `pg_shop`.
var shop: PlaygroundShop = null

## Watching somebody else build, fight, or drive into a wall.
var spectate: PlaygroundSpectate = null

## Down rather than dead, while the waves are on. The co-operative half.
var downs: PlaygroundDowns = null

## Per-player statistics, and what they are worth.
var progress: PlaygroundProgress = null

## What plays next, decided by the players.
var vote: PlaygroundVote = null

## Which userids have already been given a player, so a re-fired spawn does not add a
## second one.
var _joined: Dictionary = {}

var _tick: int = 0

## Per-admin zone painters, by session user id.
##
## One each, because two admins drawing at once would otherwise share a first corner
## — and the failure is a zone spanning the distance between them, saved, with
## nothing to say it was not meant.
var _painters: Dictionary = {}

## Who last said something. What `pg_status` reports, off the accepted line.
var _last_spoke: String = ""


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

	var netted := _build_netcode()

	if not netted.ok:
		return netted

	var extras := _build_extras()

	if not extras.ok:
		return extras

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

	# --- The addons an operator turns on -----------------------------------
	add_command(
		"pg_services", _cmd_services,
		"Show chat, voice and moderation", DotAdminFlags.GENERIC
	)
	add_command(
		"pg_arena", _cmd_arena,
		"pg_arena [on|off] — health, weapons that hurt, and a round",
		DotAdminFlags.CHANGEMAP
	)
	add_command(
		"pg_waves", _cmd_waves,
		"pg_waves [on|off|clear] — NPCs the server releases",
		DotAdminFlags.CHANGEMAP
	)
	# No flag: this is a player command rather than an administrative one, and
	# `_on_chat_command` routes `!pg_spec` through the console like every other.
	add_command(
		"pg_spec", _cmd_spec,
		"pg_spec [player|off|next] — watch somebody else", ""
	)
	add_command(
		"pg_shop", _cmd_shop,
		"pg_shop [on|off|prices] — a price list over the spawn menu",
		DotAdminFlags.CHANGEMAP
	)
	add_command(
		"pg_credits", _cmd_credits,
		"pg_credits [player] [+amount] — what somebody has, and giving them some",
		DotAdminFlags.CHANGEMAP
	)
	add_command(
		"pg_vote", _cmd_vote,
		"pg_vote [open|next|status] — what plays next", DotAdminFlags.CHANGEMAP
	)
	add_command(
		"pg_achievements", _cmd_achievements,
		"pg_achievements [player] — what somebody has earned", ""
	)
	# MUTE rather than BAN: quieting somebody and removing them are different powers, and
	# dot-server's own flags are what distinguish them.
	add_command(
		"pg_gag", _cmd_gag, "pg_gag <who> <seconds> [reason]", DotAdminFlags.MUTE
	)
	add_command(
		"pg_mute", _cmd_mute, "pg_mute <who> <seconds> [reason]", DotAdminFlags.MUTE
	)

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

	# [b]dot-server's own chat is cancelled here rather than listened to.[/b]
	# [DotChatRouter] has the rules now, and the one thing that must not happen is both
	# running: two sets of rules to keep in step, and the one that skipped the filter would
	# be the one that leaked admin chat. A pre-hook is what can cancel;
	# [method DotChatManager.handle_message] broadcasts the moment the event returns.
	hook_pre("player_chat", _on_player_chat)

	# dot-chat makes the join and leave notices now, so dot-server's would be a second one
	# on a second path.
	if server.chat != null:
		server.chat.announce_joins = false

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


## Everything that is not the netcode.
##
## [b]Built in this order because each one needs the last.[/b] The services register a mute
## source the chat router warns about the absence of; the progress layer watches the prop
## spawner and the timer; the arena and the waves both act on the world. None of it
## suspends, because [method DotModuleHost.load_module] does not await `_module_load` and a
## module whose load suspends returns null to it.
func _build_extras() -> DotResult:
	services = PlaygroundServices.new()
	services.name = "Services"
	services.bridge = bridge
	services.game = game
	services.server = server
	add_child(services)

	var serviced := services.setup()

	if not serviced.ok:
		return serviced.wrap("The services could not be set up")

	bridge.say_requested.connect(_on_say_requested)
	bridge.voice_requested.connect(_on_voice_requested)
	bridge.vote_requested.connect(_on_vote_requested)
	bridge.loadout_requested.connect(_on_loadout_requested)
	services.command_entered.connect(_on_chat_command)
	services.chat.message_accepted.connect(_on_chat_accepted)

	arena = PlaygroundArena.new()
	arena.name = "Arena"
	add_child(arena)

	var fought := arena.setup(game)

	if not fought.ok:
		return fought.wrap("The arena could not be set up")

	arena.health_changed.connect(_on_health_changed)
	arena.player_killed.connect(_on_player_killed)
	arena.player_killed.connect(func(victim: StringName, killer: StringName) -> void:
		shop.on_arena_kill(killer, victim)
		var player: PlaygroundPlayer = game.players.get(victim, null)
		var at := player.controller.state.position if player != null else Vector3.ZERO
		spectate.on_death(victim, at, killer)
	)
	arena.clock_changed.connect(bridge.broadcast_match)

	waves = PlaygroundWaves.new()
	waves.name = "Waves"
	add_child(waves)

	var waved := waves.setup(game)

	if not waved.ok:
		return waved.wrap("The waves could not be set up")

	# The director paces against real health when the arena is on, and against proximity
	# alone when it is not. One callable rather than two code paths.
	# Something the director sent has died, and somebody killed it. The wave mode is
	# what makes a price list worth having: a wave pays, a jeep costs, and a player who
	# spent everything on turrets has to earn the next one.
	waves.spawner.died.connect(func(_npc: DotNpcInstance, by: StringName) -> void:
		shop.on_wave_kill(by))

	waves.health_fn = func(id: StringName) -> float:
		var health := arena.health_of(id)
		return health.fraction() if health != null else 1.0

	shop = PlaygroundShop.new()
	shop.name = "Shop"
	add_child(shop)

	var priced := shop.setup(game)

	if not priced.ok:
		return priced.wrap("The shop could not be set up")

	# The bridge charges through this and knows nothing about prices. Unset it and
	# everything is free, which is what this game was before there was a price list.
	bridge.charge_fn = shop.charge

	spectate = PlaygroundSpectate.new()
	spectate.name = "Spectate"
	add_child(spectate)

	var watching := spectate.setup(game)

	if not watching.ok:
		return watching.wrap("Spectating could not be set up")

	spectate.arena = arena

	downs = PlaygroundDowns.new()
	downs.name = "Downs"
	add_child(downs)

	var dropped := downs.setup(game)

	if not dropped.ok:
		return dropped.wrap("Incapacitation could not be set up")

	downs.arena = arena

	# The arena asks and the downs layer answers, so the rule lives in one place. Unset
	# it and everybody dies, which is what a deathmatch is.
	arena.death_rule_fn = downs.report_zero_health

	# A downed player who bleeds out is a death the scoreboard and the respawn queue
	# still have to hear about, and the arena's own path was skipped when they went
	# down. This is the other end of that decision.
	downs.died.connect(func(player_id: StringName, _reason: StringName) -> void:
		if arena.enabled and player_id != &"":
			arena.match_node.report_kill("", String(player_id), &"bleed_out", game.current_tick())
	)

	downs.revived.connect(func(player_id: StringName, _by: StringName, health: float) -> void:
		var record := arena.health_of(player_id)
		if record != null:
			record.revive(clampf(health / PlaygroundArena.MAX_HEALTH, 0.05, 1.0))
	)

	# Being killed by a wave is what being downed is FOR, so the two switch together.
	# The alternative — a separate cvar — is an operator who turned the waves on and
	# wonders why nobody is being picked up.
	downs.set_enabled(waves.is_enabled())

	progress = PlaygroundProgress.new()
	progress.name = "Progress"
	progress.backbone = null
	progress.key_for = _stats_key_for
	add_child(progress)

	var earned := progress.setup(game)

	if not earned.ok:
		return earned.wrap("Progress could not be set up")

	progress.earned.connect(_on_earned)

	vote = PlaygroundVote.new()
	vote.name = "Vote"
	vote.player_count_fn = func() -> int: return game.players.size()
	vote.is_admin_fn = _voter_is_admin
	add_child(vote)

	var voted := vote.setup(game)

	if not voted.ok:
		return voted.wrap("The vote could not be set up")

	vote.change_due.connect(_on_vote_change_due)
	vote.announced.connect(_on_vote_announced)

	# [b]The one signal that fires for every change however it happened.[/b] An operator
	# typing `pg_map`, the time limit expiring and the vote applying all end at
	# `DotMapSession.changed` — which is why the director does not announce its own change
	# and why this is the only connection. Two of them is two entries in the play history
	# for one play, and a "played in the last N" cooldown that is quietly half what it
	# says: dot-vote's fifth bug, from the other side.
	game.maps.changed.connect(func(map: DotMapDef, _world: Node) -> void:
		vote.note_playing(map.id)
	)

	if game.maps.current != null:
		vote.note_playing(game.maps.current.id)

	return DotResult.success(null)


# --- Chat, voice and votes -------------------------------------------------

## Somebody said something through dot-server's own chat path.
##
## Taken and cancelled, not watched: this game's rules are [DotChatRouter]'s now, and
## cancelling is what makes there be exactly one path.
func _on_player_chat(event: DotEvent) -> void:
	event.cancel("routed by the sandbox's chat", _module_name())

	var session := event.get_session()

	if session == null or services == null or services.chat == null:
		return

	_on_say_requested(
		session.peer_id, PlaygroundServices.CHANNEL_ALL, event.get_string("text")
	)


func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var said := services.chat.submit(peer_id, channel_id, text)

	if not said.ok and said.error != null:
		# Back to the sender and nowhere else: dot-chat is deliberate that a rate-limited
		# or gagged player must not be able to measure the difference from outside.
		services.chat.notice(peer_id, said.error.message, channel_id)


func _on_voice_requested(peer_id: int, payload: PackedByteArray) -> void:
	services.voice.relay(peer_id, payload)


func _on_chat_accepted(message: DotChatMessage, _to: PackedInt32Array) -> void:
	if message.sender_peer > 0:
		_last_spoke = message.sender_name


## An unclaimed `!command` from chat, routed into dot-server's own console with the
## player's permissions.
##
## [b]Not a second command table.[/b] dot-server already decides what a session may run,
## logs it to the audit log and answers it — and this game's console surface is the largest
## in the family, so a second table would be the larger half unaudited.
func _on_chat_command(peer_id: int, command: String, args: PackedStringArray) -> void:
	var session := server.session_of(peer_id)

	if session == null:
		return

	if server.console.find_command(command) == null:
		DotLog.debug(CHANNEL, "an unknown chat command was ignored", {
			"peer": peer_id, "command": command,
		})
		return

	var ctx := session.make_context(
		command,
		args,
		DotCmdContext.Source.CHAT,
		func(line: String) -> void:
			services.chat.notice(peer_id, line, PlaygroundServices.CHANNEL_ALL)
	)

	var line := command

	for arg in args:
		line += " " + arg

	server.console.execute(line, ctx)


func _on_vote_requested(peer_id: int, token: String) -> void:
	var session_id := bridge.player_for_peer(peer_id)

	if session_id == 0:
		return

	var result := vote.submit(StringName("u%d" % session_id), token)

	if not result.ok and services != null:
		services.chat.notice(
			peer_id, result.error.message, PlaygroundServices.CHANNEL_ALL
		)


func _voter_is_admin(voter: StringName) -> bool:
	var text := String(voter)

	if not text.begins_with("u"):
		return false

	var session := server.session_by_userid(text.substr(1).to_int())
	return session != null and session.is_admin()


func _on_vote_announced(line: String) -> void:
	if services != null and services.chat != null:
		services.chat.announce(line, PlaygroundServices.CHANNEL_ALL)


## The vote picked a map. The game is what changes to it.
func _on_vote_change_due(map_id: StringName) -> void:
	game.change_map(map_id)


# --- Loadouts, combat and progress ----------------------------------------

func _on_loadout_requested(peer_id: int, pairs: Array) -> void:
	var session_id := bridge.player_for_peer(peer_id)

	if session_id == 0 or arena == null or arena.loadouts == null:
		return

	var loadout := DotLoadout.new()

	for pair in pairs:
		var row: Array = pair
		loadout.set_item(StringName(str(row[0])), StringName(str(row[1])))

	# [b]Validated on the way in, conformed on the way out.[/b] A client that can make the
	# server repair its way to a legal loadout can put anything in any slot and have the
	# server pick the nearest legal thing — so this direction refuses, and
	# `conform_on_load` is on for the other one, where refusing would mean a player who
	# has not played since a weapon changed cannot spawn.
	# [b]Awaited, and this handler is therefore a coroutine.[/b] The store write is the
	# suspension: a publish that reported success before the write returned would be a
	# loadout a player believes they have and a server that has not kept it. Nothing after
	# this line depends on anything else, so suspending here costs nothing — which is the
	# only reason it is safe to do it inside a signal handler.
	var published: DotResult = await arena.loadouts.publish(
		"u%d" % session_id, loadout, 0
	)

	if not published.ok and services != null:
		services.chat.notice(
			peer_id, published.error.message, PlaygroundServices.CHANNEL_ALL
		)


func _on_health_changed(
	player_id: StringName, health: float, armour: float, by: StringName
) -> void:
	bridge.broadcast_combat(
		_session_of(player_id), int(health), int(armour), _session_of(by), false
	)


func _on_player_killed(victim: StringName, killer: StringName) -> void:
	bridge.broadcast_combat(_session_of(victim), 0, 0, _session_of(killer), true)

	if progress != null:
		progress.note(victim, &"deaths", 1.0)

		if killer != &"" and killer != victim:
			progress.note(killer, &"kills", 1.0)


func _on_earned(player_key: String, id: StringName, title: String, points: int) -> void:
	# The session the key belongs to, so a client can colour the line. Linear over at most
	# a few dozen players, a few times a session.
	for userid in _joined.keys():
		var session := server.session_by_userid(int(userid))

		if session == null:
			continue

		if PlaygroundPlatform.key_for_session(server, session) != player_key:
			continue

		bridge.broadcast_progress(session.userid, id, title, points)
		return


## The key a statistic is filed under.
##
## [b]The scoped pseudonymous one when there is a dot-platform, and the session id when
## there is not.[/b] dot-stats refuses an account id as a player key before it leaves the
## server, and this is the one function that decides — a LAN sandbox files under something
## that lasts as long as the session, which is honest.
func _stats_key_for(player_id: StringName) -> String:
	var text := String(player_id)

	if not text.begins_with("u"):
		return text

	var session := server.session_by_userid(text.substr(1).to_int())

	if session == null:
		return text

	return PlaygroundPlatform.key_for_session(server, session)


## A world player id back to a dot-server session id, or zero.
func _session_of(player_id: StringName) -> int:
	var text := String(player_id)
	return text.substr(1).to_int() if text.begins_with("u") else 0


# --- The netcode -----------------------------------------------------------

func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = true
	net.local_peer_id = 1
	net.auto_tick = false
	net.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = 32
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 64
	config.world_extent = 512.0
	net.config = config
	add_child(net)

	var ready_result := net.setup()

	if not ready_result.ok:
		return ready_result.wrap("The netcode could not start")

	bridge = PlaygroundNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	# `server` is the node the link mirrors: a client's DotClientLink is named to match,
	# and the name IS the RPC routing.
	var attached := bridge.attach(game, net, server)

	if not attached.ok:
		return attached

	net.messages.seal()
	return net.start()


## The server's tick, which is the whole game's.
##
## Driven from here rather than by the game's own loop, because it has to happen between
## dot-net applying the inputs that arrived and building the snapshot that goes back out.
## `Playground.external_tick` is what stands the game's loop down.
func _physics_process(_delta: float) -> void:
	if not loaded or bridge == null:
		return

	_tick += 1
	bridge.server_tick(_tick)

	# [b]After the world has ticked, and that is the ordering that matters.[/b] dot-combat
	# rewinds to resolve a shot and the waves read where everybody is, and both have to
	# work on positions the movement has just produced — a list built before the tick is a
	# list of where everybody WAS, which is the one-tick lag this family has documented
	# three times now.
	var step := 1.0 / float(maxi(game.tick_rate, 1))

	if arena != null:
		arena.tick(_tick, step)

	if shop != null:
		shop.tick(step)

	if spectate != null:
		spectate.tick(step)

	if downs != null:
		downs.tick(step)

	if waves != null:
		waves.tick(_tick, step)

	if vote != null:
		vote.advance(step)


# --- Sessions --------------------------------------------------------------

## A client finished the signon and is in the world.
##
## `client_spawn`, not `client_connected`: a connected client has a socket and
## nothing else — no identity, no content, no confirmation it can load the map.
## [b]`client_spawn` carries `userid`, and it does NOT carry `peer_id`.[/b] This handler
## asked for one, got 0, looked a session up by it and found null — and a null session is
## a legitimate thing to find, so it returned quietly and NOBODY EVER JOINED. Nothing
## errored, in every configuration, for as long as this module has existed; it survived
## because the only thing that had ever loaded it was a headless test that adds its
## players directly. The family's CLAUDE.md has carried this exact warning since
## game-hungario hit it.
func _on_client_spawn(event: DotEvent) -> void:
	var session := server.session_by_userid(event.get_int("userid"))

	if session == null or _joined.has(session.userid):
		return

	var id := _player_id(session)

	if game.players.has(id):
		return

	# Through the bridge, not through the game: the bridge is what builds the entity
	# that replicates them and announces the join. game.add_player alone would put a
	# player in the world that no client is ever told about.
	var added := bridge.add_player(session.peer_id, session.userid, session.label())

	if not added.ok:
		log_warn("could not add a player", {
			"userid": session.userid, "error": str(added.error)
		})
		return

	_joined[session.userid] = true

	# Voice and chat learn about them before anything is sent, so a frame or a line that
	# lands in the same flush as the admission has somewhere to go.
	if services != null:
		services.add_peer(session.peer_id)

	if progress != null:
		progress.begin(PlaygroundPlatform.key_for_session(server, session))

	if arena != null and arena.enabled:
		arena.admit(id, session.label())

	_welcome(session)

	log_info("player joined the game", {"player": String(id)})


## What somebody is told once they are in: the backlog, and the clock.
##
## [b]After the admission, never before it.[/b] Nothing may be sent to a peer before it has
## said it can receive — dot-server's signon finishes and *then* the client builds its
## scene, and everything sent in between lands on a node that does not exist and is lost,
## one "Node not found" per call.
func _welcome(session: DotClientSession) -> void:
	if bridge == null or not bridge.peer_is_ready(session.peer_id):
		return

	if services != null:
		# The backlog: what was said before they walked in. dot-chat computes it per peer,
		# because a channel with `backlog = 0` — the proximity one — must not replay a
		# line somebody said quietly beside their build to a stranger who was not there.
		for line in services.chat.backlog_for(session.peer_id):
			bridge.send_chat(session.peer_id, line)

		services.chat.join_notice(session.peer_id, PlaygroundServices.CHANNEL_ALL)

	# The match clock, once, so a client that joined mid-round is not told `IDLE` until
	# the next second ticks over.
	if arena != null and arena.enabled:
		arena._announce_clock()


## [b]`client_disconnected` emits TWO arguments — the session and a reason — and this
## took one.[/b] Godot then refuses the call outright ("Method expected 1 argument(s), but
## called with 2") and the handler NEVER RUNS: no player was ever removed, no peer was
## ever released, and the server went on building a snapshot for every client that had
## ever connected and sending it to a socket that was gone. One engine error per
## disconnect and three per tick after that.
##
## It survived because nothing had ever disconnected from this module: `dedicated.tscn`
## adds its players directly and tears the module down at the end. The default keeps it
## callable from anything that emits only the session.
func _on_client_disconnected(session: DotClientSession, _reason: String = "") -> void:
	var id := _player_id(session)

	# [b]Off the broadcast set first.[/b] Everything below announces something about this
	# person to everybody ELSE, and their socket has already gone.
	if bridge != null:
		bridge.mark_not_ready(session.peer_id)

	if services != null:
		services.chat.leave_notice(session.peer_id, PlaygroundServices.CHANNEL_ALL)
		services.remove_peer(session.peer_id)

	if vote != null and vote.director != null:
		# The vote forgets them, or a rock-the-vote threshold counts a ballot from
		# somebody who has left — which is how a server ends up unable to change at all.
		vote.director.forget_voter(id)

	if arena != null:
		arena.release(id)

	if progress != null:
		progress.end(PlaygroundPlatform.key_for_session(server, session))

	_painters.erase(id)
	_joined.erase(session.userid)

	# The bridge releases the entity, tells every other client, and forgets the peer.
	# Removing them from the game alone would leave a replicated entity pointing at a
	# freed player.
	if bridge != null:
		bridge.remove_player(session.userid)
	else:
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

	if _last_spoke != "":
		ctx.reply("last spoke   %s" % _last_spoke)

	for layer in [arena, waves, vote]:
		if layer != null:
			ctx.reply_lines(layer.describe_lines())


func _cmd_services(ctx: DotCmdContext) -> void:
	ctx.reply_lines(services.describe_lines())


func _cmd_arena(ctx: DotCmdContext) -> void:
	match ctx.arg(0):
		"on":
			arena.set_enabled(true)
			# A living player watching a living one while they are shooting at each
			# other is a wallhack, and this is the moment it stops being a sandbox.
			spectate.set_fighting(true)

			# Everybody already here joins the fight. A match that only admitted people
			# who connected *after* it started would be a match the server's existing
			# players are spectators in, with nothing saying so.
			for id in game.players.keys():
				arena.admit(id, String(id))

			ctx.reply("The arena is on: %d fighting." % game.players.size())
		"off":
			arena.set_enabled(false)
			spectate.set_fighting(false)
			ctx.reply("The arena is off. This is a sandbox again.")
		_:
			ctx.reply_lines(arena.describe_lines())


func _cmd_waves(ctx: DotCmdContext) -> void:
	match ctx.arg(0):
		"on":
			waves.set_enabled(true)
			# Being killed by a wave is what being downed is for, so the two switch
			# together. A separate cvar is an operator who turned the waves on and
			# wonders why nobody is being picked up.
			downs.set_enabled(true)
			ctx.reply("Waves are on, and a player at zero health goes down rather than dying.")
		"off":
			waves.set_enabled(false)
			downs.set_enabled(false)
			ctx.reply("Waves are off, and the map is cleared of them.")
		"clear":
			var gone := waves.spawner.clear_all()
			ctx.reply("Cleared %d." % gone)
		_:
			ctx.reply_lines(waves.describe_lines())


## `pg_spec` — watch somebody else.
##
## A sandbox is the one place where watching is not about being dead: the interesting
## thing on a server like this is usually what somebody else is making, and the answer to
## "what is that noise in the corner" is a camera.
func _cmd_spec(ctx: DotCmdContext) -> void:
	var session := ctx.session

	if session == null:
		ctx.reply("Only a player can watch somebody.")
		return

	var viewer := _player_id(session)

	match ctx.arg(0):
		"", "next":
			var res := spectate.next_target(viewer)
			ctx.reply(
				("Watching %s." % String(spectate.target_of(viewer))) if res.ok
				else res.error.message
			)
		"off", "stop":
			spectate.stop(viewer)
			ctx.reply("Back to your own view.")
		_:
			var wanted := _player_named(ctx.arg(0))

			if wanted == &"":
				ctx.reply("There is nobody called '%s' here." % ctx.arg(0))
				return

			var res := spectate.watch(viewer, wanted)
			ctx.reply(
				("Watching %s." % String(wanted)) if res.ok else res.error.message
			)


## A player id by display name, case-insensitively and by prefix.
##
## What every server in this genre does: `!pg_spec ad` finds Ada. The first match wins
## and the order is the roster's, which is stable — the alternative is refusing an
## ambiguous prefix, and a player who typed two letters and got "be more specific" types
## three letters and gives up.
func _player_named(text: String) -> StringName:
	var wanted := text.strip_edges().to_lower()

	if wanted == "":
		return &""

	for session in server.sessions():
		var name := session.display_name.to_lower()
		if name == wanted or name.begins_with(wanted):
			return _player_id(session)

	for id: Variant in game.players.keys():
		var name := String(id).to_lower()
		if name == wanted or name.begins_with(wanted):
			return StringName(id)

	return &""


## `pg_shop` — turn the price list on, off, or read it.
##
## Off by default, and the cvar is the point: a sandbox where everything is free is a
## sandbox, and one where a jeep costs four hundred credits is a game. Turning one into
## the other because an addon was installed is what this family's rule about cvars
## exists to prevent.
func _cmd_shop(ctx: DotCmdContext) -> void:
	match ctx.arg(0):
		"on":
			shop.set_enabled(true)
			ctx.reply("The shop is on. Everything has a price now.")
		"off":
			shop.set_enabled(false)
			ctx.reply("The shop is off. Take what you like.")
		"prices":
			if shop.economy == null or shop.economy.shop == null:
				ctx.reply("There is no price list.")
			else:
				ctx.reply_lines(shop.economy.shop.describe_lines())
		_:
			ctx.reply_lines(shop.describe_lines())


## `pg_credits` — read a balance, or hand somebody a few.
func _cmd_credits(ctx: DotCmdContext) -> void:
	var who := ctx.arg(0)

	if who == "":
		var lines := PackedStringArray()
		for id: Variant in game.players.keys():
			lines.append("%-20s %d" % [String(id), shop.balance(StringName(id))])
		if lines.is_empty():
			lines.append("Nobody is here.")
		ctx.reply_lines(lines)
		return

	var target := _player_named(who)

	if target == &"":
		ctx.reply("There is nobody called '%s' here." % who)
		return

	var amount := ctx.arg(1)

	if amount == "":
		ctx.reply("%s has %d." % [String(target), shop.balance(target)])
		return

	var paid := shop.award(target, amount.to_int(), &"admin")
	ctx.reply(
		"%s now has %d (%s%d)."
			% [String(target), shop.balance(target), "+" if paid >= 0 else "", paid]
	)


func _cmd_vote(ctx: DotCmdContext) -> void:
	match ctx.arg(0):
		"open":
			var opened := vote.director.open_vote()

			if opened.ok:
				ctx.reply("Vote opened.")
			else:
				ctx.reply_error(opened)
		"next":
			ctx.reply("Next in rotation: %s" % String(vote.next_in_rotation()))
		_:
			ctx.reply_lines(vote.describe_lines())


func _cmd_achievements(ctx: DotCmdContext) -> void:
	var session := ctx.session

	if ctx.args.size() > 0:
		var found := server.find_sessions(ctx.arg(0), ctx.session)
		session = found[0] if not found.is_empty() else null

	if session == null:
		ctx.reply("Who?")
		return

	var key := PlaygroundPlatform.key_for_session(server, session)
	var listing := progress.achievements.listing(key)

	if listing.is_empty():
		ctx.reply("%s has earned nothing yet." % session.display_name)
		return

	ctx.reply("%s — %d points" % [
		session.display_name, progress.achievements.points_of(key)
	])

	for row in listing:
		var entry: Dictionary = row

		# A secret one that has not been earned is not listed at all. That is what
		# `secret` means, and a listing that named it would be a listing that spoils it.
		if bool(entry.get("secret", false)) and not bool(entry.get("unlocked", false)):
			continue

		ctx.reply("  %s %-24s %s" % [
			"*" if bool(entry.get("unlocked", false)) else " ",
			str(entry.get("name", "")),
			str(entry.get("description", "")),
		])


func _cmd_gag(ctx: DotCmdContext) -> void:
	await _punish(ctx, DotPunishment.Kind.GAG, "gagged")


func _cmd_mute(ctx: DotCmdContext) -> void:
	await _punish(ctx, DotPunishment.Kind.VOICE_MUTE, "muted")


## The shared half of gag and mute.
##
## One function because the only difference is a kind: dot-moderation already models both
## as one record with an expiry, a scope and a revocation, and writing them separately
## would be two chances to forget the duration parsing or the immunity.
func _punish(ctx: DotCmdContext, kind: DotPunishment.Kind, verb: String) -> void:
	if ctx.args.size() < 2:
		ctx.reply("Usage: %s <who> <seconds, 0 for permanent> [reason]" % ctx.command)
		return

	var targets := server.find_sessions(ctx.args[0], ctx.session)

	if targets.is_empty():
		ctx.reply("Nobody matches '%s'." % ctx.args[0])
		return

	if targets.size() > 1:
		# Refused rather than applied to all of them: `@me` and a name prefix both match
		# more than one person, and a mute applied to four people by accident is a thing
		# an operator finds out about from the four people.
		ctx.reply("'%s' matches %d people. Be more specific." % [
			ctx.args[0], targets.size()
		])
		return

	var session := targets[0]
	var seconds := maxi(0, ctx.arg_int(1))
	var reason := ctx.rest(2) if ctx.args.size() > 2 else "No reason given."

	var issued: DotResult = await services.moderation.issue(
		kind,
		DotPunishmentSubject.for_uid(session.uid()),
		reason,
		ctx.caller_label(),
		seconds,
		ctx.immunity
	)

	if not issued.ok:
		ctx.reply("Refused: %s" % issued.error.message)
		return

	ctx.reply("%s %s: %s" % [
		session.display_name, verb, DotPunishment.format_duration(seconds)
	])

	# Told to the person it happened to, on the channel they are reading. A mute nobody is
	# told about is a microphone that has stopped working, which is what they report.
	services.chat.notice(
		session.peer_id,
		(issued.value as DotPunishment).player_message(),
		PlaygroundServices.CHANNEL_ALL
	)


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
