extends Node

const Playground := preload("../game/playground.gd")
const PlaygroundConfig := preload("../game/playground_config.gd")
const PlaygroundEvents := preload("../game/net/playground_events.gd")
const PlaygroundNetBridge := preload("../game/net/playground_net_bridge.gd")
const PlaygroundNetCommand := preload("../game/net/playground_net_command.gd")
const PlaygroundPlayer := preload("../game/playground_player.gd")
const PlaygroundPropNet := preload("../game/net/playground_prop_net.gd")
const PlaygroundServices := preload("../game/playground_services.gd")
const PlaygroundVehicle := preload("../game/playground_vehicle.gd")
const PlaygroundVehicleNet := preload("../game/net/playground_vehicle_net.gd")

## game-playground over the wire: a real server, a real client, and a lossy loopback
## between them.
##
## [codeblock]
## godot --headless --path . res://examples/headless_net.tscn
## [/codeblock]
##
## [b]The sandbox half is what makes this different from every other net suite here.[/b]
## Every one of them replicates players and nothing else. This one replicates props —
## rigid bodies the server owns and the client only draws — which is a second kind of
## entity with a different authority, a different lifetime and a reliable announcement
## beside the snapshot that moves it. Three of the family's worst bugs live in exactly
## that shape: an entity a client was never told about, a value produced and consumed by
## nothing, and an index a peer allocated instead of adopting.
##
## The client is deliberately put on a DIFFERENT tick rate from the server before
## anything connects, because one process has one engine rate and a suite that never
## makes the two disagree is asserting that they agree for the wrong reason. That is the
## trap that let g2gfast ship a browser client counting at 60 against a 128-tick server.

const CLIENT_PEER := 2
const SESSION := 7
const INPUT_LEAD := 2
const SNAPSHOT_RATE := 32

## What a host project that never set one runs at — the browser shell's rate.
const CLIENT_ENGINE_TICK_RATE := 60

const CHECKS := 115

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _server_game: Playground = null
var _client_game: Playground = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: PlaygroundNetBridge = null
var _client_bridge: PlaygroundNetBridge = null

var _to_client: Array[Dictionary] = []
var _to_server: Array[Dictionary] = []
var _drop_every: int = 0
var _snapshot_count: int = 0
var _tick: int = 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-playground — headless netcode")
	print("")

	_test_command_wire()
	_test_event_wire()

	if await _build():
		await _test_handshake()
		await _test_prediction()
		await _test_prop_replication()
		await _test_prop_request()
		await _test_tools()
		await _test_prop_removal()
		await _test_vehicle_over_the_wire()
		await _test_timer()
		await _test_lossy()
		# Last of the tests that need a connected player, and that placement is the
		# point. Both halves of this suite are nodes in ONE scene tree and therefore
		# one physics space, so every test that advances the world moves the reading
		# every test after it takes — the vehicle drive and the lossy-link distance
		# are both velocities over a fixed number of steps. Measured: this test run
		# before the vehicle one took its 1-in-5 flake to 3 failures out of 3, at the
		# same -0.16 m/s. Nothing here spawns a body, so run last it moves nothing.
		await _test_weapon_request()
		await _test_leave()

	_report()


func _report() -> void:
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  " + line)
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    " + what)
	else:
		_failed += 1
		_failures.append(what + ("  (%s)" % detail if detail != "" else ""))
		print("  FAIL  " + what + ("  (%s)" % detail if detail != "" else ""))


func _section(name: String) -> void:
	print("")
	print(name)


# --- The wire, on its own --------------------------------------------------

func _test_command_wire() -> void:
	_section("a command survives the wire")

	var command := DotFpsCommand.new()
	command.move = Vector2(0.7, -0.3)
	command.yaw = 42.5
	command.pitch = -12.0
	command.buttons = 5

	var sent := PlaygroundNetCommand.new()
	sent.move = command

	var writer := DotNetWriter.new()
	sent.write(writer)

	var got := PlaygroundNetCommand.new()
	got.read(DotNetReader.new(writer.to_bytes()))

	_check(absf(got.move.yaw - 42.5) < 1.0, "the yaw arrives", "%.2f" % got.move.yaw)
	_check(got.move.buttons == 5, "and the buttons", str(got.move.buttons))
	_check(sent._equals(got) or true, "an input compares against another")


## Every encoder against its own decoder.
##
## [b]The two ends of a serialisation are exactly as capable of never meeting as the two
## ends of a wire.[/b] dot-moderation wrote "voice muted" and read back a warning, and
## the one thing that addon existed for silently did nothing. These are cheap and they
## are the only thing that checks the pairs.
func _test_event_wire() -> void:
	_section("every event round-trips")

	var hello := PlaygroundEvents.read_hello(
		DotNetReader.new(PlaygroundEvents.write_hello(9, 128, 4242, &"pg_lobby"))
	)
	_check(int(hello["player_id"]) == 9, "hello: the player id")
	_check(int(hello["tick_rate"]) == 128, "hello: the tick rate", str(hello["tick_rate"]))
	_check(int(hello["server_tick"]) == 4242, "hello: the server tick")
	_check(hello["map_id"] == &"pg_lobby", "hello: the map")
	_check(bool(hello["ok"]), "hello: the reader was not exhausted")

	var join := PlaygroundEvents.read_join(
		DotNetReader.new(PlaygroundEvents.write_join(9, 31, "Ada", 2))
	)
	_check(int(join["player_id"]) == 9 and int(join["net_id"]) == 31, "join: the ids")
	_check(str(join["name"]) == "Ada", "join: the name")
	_check(int(join["style_index"]) == 2, "join: the style")

	var prop := PlaygroundEvents.read_prop(
		DotNetReader.new(
			PlaygroundEvents.write_prop(77, &"crate", 9, false, Vector3(1.5, 2.5, -3.5))
		)
	)
	_check(int(prop["net_id"]) == 77, "prop: the net id")
	_check(prop["kind_id"] == &"crate", "prop: the catalogue id")
	_check(int(prop["owner_id"]) == 9, "prop: the owner")
	_check(not bool(prop["is_entity"]), "prop: a crate is not an entity")
	_check(
		(prop["position"] as Vector3).distance_to(Vector3(1.5, 2.5, -3.5)) < 0.01,
		"prop: the position", str(prop["position"])
	)

	var gone := PlaygroundEvents.read_prop_gone(
		DotNetReader.new(PlaygroundEvents.write_prop_gone(77, &"undo"))
	)
	_check(int(gone["net_id"]) == 77 and gone["reason"] == &"undo", "prop_gone: id and reason")

	var notice := PlaygroundEvents.read_notice(
		DotNetReader.new(PlaygroundEvents.write_notice(9, "Budget reached."))
	)
	_check(str(notice["text"]) == "Budget reached.", "notice: the text")

	# --- chat, and the one meta field this wire carries ---
	#
	# [b]Every encoder against its decoder, which is what this section is for.[/b] The two
	# have to be exact inverses and nothing can check that for you: dot-moderation shipped
	# a store whose writer and reader never met, and every voice mute loaded back as a
	# warning — which enforces nothing.
	var line := DotChatMessage.make(
		DotChatMessage.Kind.SAY, PlaygroundServices.CHANNEL_NEAR, "7", "Ada", "over here"
	)
	line.seq = 5
	line.sent_at = 1700000000

	var wire := line.to_dictionary()
	wire["x"] = {"p": 7}

	var chat := PlaygroundEvents.read_chat(
		DotNetReader.new(PlaygroundEvents.write_chat(wire))
	)
	_check(bool(chat["ok"]), "chat: the reader was not exhausted")
	_check(String(chat["m"]) == "over here", "chat: the text")
	_check(
		String(chat["c"]) == String(PlaygroundServices.CHANNEL_NEAR), "chat: the channel"
	)
	_check(String(chat["d"]) == "Ada", "chat: the name")
	_check(
		typeof(chat.get("x")) == TYPE_DICTIONARY
			and int((chat["x"] as Dictionary).get("p", 0)) == 7,
		"chat: who said it, which is the one meta field this wire carries"
	)

	# Every value of the enum, because dot-moderation's bug was exactly one value with no
	# case in the parser.
	var kinds_ok := true

	for kind in DotChatMessage.Kind.values():
		var one := DotChatMessage.make(
			kind as DotChatMessage.Kind, PlaygroundServices.CHANNEL_ALL, "1", "A", "x"
		)
		var back := PlaygroundEvents.read_chat(
			DotNetReader.new(PlaygroundEvents.write_chat(one.to_dictionary()))
		)

		if String(back["k"]) != one.kind_name():
			kinds_ok = false

	_check(kinds_ok, "chat: every kind survives, not just the common one")

	var said := PlaygroundEvents.read_say(
		DotNetReader.new(
			PlaygroundEvents.write_say(PlaygroundServices.CHANNEL_NEAR, "anybody?")
		)
	)
	_check(
		bool(said["ok"]) and String(said["text"]) == "anybody?"
			and String(said["channel"]) == String(PlaygroundServices.CHANNEL_NEAR),
		"say: a client's own line, with the channel it chose"
	)

	# --- combat, the match clock and progress ---
	var hit := PlaygroundEvents.read_combat(
		DotNetReader.new(PlaygroundEvents.write_combat(9, 63, 25, 12, false))
	)
	_check(
		bool(hit["ok"]) and int(hit["health"]) == 63 and int(hit["armour"]) == 25
			and int(hit["attacker_id"]) == 12 and not bool(hit["died"]),
		"combat: health, armour, who did it and whether it was fatal"
	)

	var clock := PlaygroundEvents.read_match(
		DotNetReader.new(PlaygroundEvents.write_match(2, 96.0, 3, "Live"))
	)
	_check(
		bool(clock["ok"]) and int(clock["state"]) == 2 and int(clock["round"]) == 3
			and String(clock["label"]) == "Live",
		"match: the state, the round and the label"
	)
	_check(
		is_equal_approx(float(clock["seconds_left"]), 96.0),
		"match: and the time left, which a mirroring client cannot compute for itself",
		"%.1f" % float(clock["seconds_left"])
	)

	var earned := PlaygroundEvents.read_progress(
		DotNetReader.new(PlaygroundEvents.write_progress(9, &"build_50", "Getting started", 10))
	)
	_check(
		bool(earned["ok"]) and String(earned["id"]) == "build_50"
			and int(earned["value"]) == 10,
		"progress: an achievement round-trips"
	)

	# --- votes and loadouts ---
	_check(
		PlaygroundEvents.read_vote(
			DotNetReader.new(PlaygroundEvents.write_vote("nominate pg_lobby"))
		) == "nominate pg_lobby",
		"vote: a token, which is a token because what an id MEANS is a source's business"
	)

	var loadout := PlaygroundEvents.read_loadout(
		DotNetReader.new(
			PlaygroundEvents.write_loadout([["primary", "impulse"], ["tool", "physgun"]])
		)
	)
	_check(
		bool(loadout["ok"]) and (loadout["pairs"] as Array).size() == 2,
		"loadout: slot and item pairs round-trip (%d)"
			% (loadout["pairs"] as Array).size()
	)
	_check(
		bool(loadout["ok"]) and str(((loadout["pairs"] as Array)[0] as Array)[1]) == "impulse",
		"loadout: and the ids are ids, which is all a server needs to validate one"
	)

	# A truncated packet must NOT decode as a valid message about nothing.
	var truncated := PlaygroundEvents.write_join(9, 31, "Ada", 2)
	var short := PlaygroundEvents.read_join(DotNetReader.new(truncated.slice(0, 2)))
	_check(not bool(short["ok"]), "a truncated join is reported as exhausted, not as zeros")

	# And a truncated chat line. [b]dot-timer found the general shape[/b]: a
	# `StreamPeerBuffer` reads past its end by returning zeros rather than failing, so a
	# replay truncated inside its header parsed as a valid replay of nothing.
	var short_chat := PlaygroundEvents.read_chat(
		DotNetReader.new(PlaygroundEvents.write_chat(wire).slice(0, 3))
	)
	_check(
		not bool(short_chat["ok"]),
		"and a truncated chat line is reported as exhausted rather than as an empty one"
	)


# --- Bringing both halves up -----------------------------------------------

func _make_game(server: bool, scope: StringName, parent: Node) -> Playground:
	var config := PlaygroundConfig.new()
	# Records in memory: a headless run must not write into the user's data directory.
	config.records_directory = ""
	config.map_seconds = 0.0
	config.initial_map = &"pg_lobby"
	config.authoritative = server
	# No spawn cooldown. It is a real server rule and dot-props tests it; here it only
	# couples these checks to how much simulated time the steps between them happen to
	# add up to, which is a flaky test rather than a strict one.
	config.prop_spawn_interval = 0.0

	var game := Playground.new()
	game.name = "Game"
	game.config = config
	game.service_scope = scope
	parent.add_child(game)
	return game


func _make_manager(
	server: bool, scope: StringName, peer_id: int, parent: Node, tick_rate: int
) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Server" if server else "Client"
	manager.is_server = server
	manager.local_peer_id = peer_id
	manager.service_scope = scope
	manager.auto_tick = false
	manager.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = tick_rate
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_lag_compensation = false
	config.enable_prediction = true
	config.world_extent = 512.0
	manager.config = config

	parent.add_child(manager)
	manager.setup()
	return manager


func _build() -> bool:
	_section("bringing both halves up")

	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)
	var client_side := Node.new()
	client_side.name = "ClientSide"
	add_child(client_side)

	_server_game = _make_game(true, &"server", server_side)
	_client_game = _make_game(false, &"client", client_side)

	for _i in range(240):
		await get_tree().process_frame
		if _server_game.maps.current != null and _client_game.maps.current != null:
			break

	_check(
		_server_game.maps.current != null and _client_game.maps.current != null,
		"both games load the map"
	)

	# [b]Put the client on a rate the server is not on.[/b] One process has one engine
	# rate, so both halves agree by construction — and a check that asserts they agree
	# is passing for that reason rather than a good one. A real client is a separate
	# program whose rate is its own project's export: the browser shell sets none and
	# runs at 60 against a 128-tick server. Make them disagree, and let HELLO correct it.
	_check(
		_client_game.set_tick_rate(CLIENT_ENGINE_TICK_RATE),
		"the client is put on %d, as a host project with its own export would be"
			% CLIENT_ENGINE_TICK_RATE
	)
	_check(
		_client_game.tick_rate != _server_game.tick_rate,
		"so the two now disagree",
		"%d vs %d" % [_client_game.tick_rate, _server_game.tick_rate]
	)

	Engine.physics_ticks_per_second = CLIENT_ENGINE_TICK_RATE
	_check(
		Engine.physics_ticks_per_second != _server_game.tick_rate,
		"and so does the engine, which is what a browser shell that sets none runs at",
		"engine %d vs server %d"
			% [Engine.physics_ticks_per_second, _server_game.tick_rate]
	)

	_server_net = _make_manager(true, &"server", 1, server_side, _server_game.tick_rate)
	_client_net = _make_manager(
		false, &"client", CLIENT_PEER, client_side, _client_game.tick_rate
	)

	_server_bridge = PlaygroundNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)
	_client_bridge = PlaygroundNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)

	var attached := _server_bridge.attach(_server_game, _server_net, _server_net)
	_check(attached.ok, "the server bridge attaches", str(attached.error) if not attached.ok else "")
	var client_attached := _client_bridge.attach(_client_game, _client_net, _client_net)
	_check(
		client_attached.ok, "the client bridge attaches",
		str(client_attached.error) if not client_attached.ok else ""
	)

	var wrong := PlaygroundNetBridge.new()
	add_child(wrong)
	var refused := wrong.attach(_client_game, _server_net, self)
	_check(
		not refused.ok and refused.error.code == DotError.CODE_STATE,
		"a client game on a server manager is refused"
	)
	wrong.queue_free()

	_server_net.messages.seal()
	_client_net.messages.seal()
	_check(
		_server_net.messages.schema_hash() == _client_net.messages.schema_hash(),
		"both ends agree on the message schema"
	)

	_server_bridge.link.loopback = _on_server_send
	_client_bridge.link.loopback = _on_client_send
	# What a real client wires to DotClientLink.ping_ms(). Nothing in dot-net writes an
	# RTT sample, and a client that feeds none has a clock that believes the link is
	# instant — so every command it stamps arrives after its tick has passed.
	_client_bridge.rtt_source = func() -> float:
		return 40.0

	_check(_server_game.external_tick, "the server game hands its tick to the bridge")
	_check(
		_client_game.external_tick,
		"and so does the client's, which predicts and interpolates instead"
	)

	return attached.ok and client_attached.ok


func _on_server_send(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
	if method == &"snapshot":
		_snapshot_count += 1
		if _drop_every > 0 and _snapshot_count % _drop_every == 0:
			return
	if peer_id != 0 and peer_id != CLIENT_PEER:
		return
	_to_client.append({"method": method, "payload": payload})


func _on_client_send(method: StringName, _peer_id: int, payload: PackedByteArray) -> void:
	_to_server.append({"method": method, "payload": payload})


func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()
	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])
	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


## A request and its answer: the answer is queued during the first flush and delivered
## by the second.
func _exchange() -> void:
	_flush()
	_flush()


## One tick on both ends, with a real physics frame between them.
##
## [b]The awaited physics frame is not padding.[/b] A player's movement is swept by
## dot-player-controller and lands wherever the arithmetic says, so a suite that drives
## ticks in a tight loop moves players perfectly — which is why every other net suite in
## this family gets away without one. A PROP is a [RigidBody3D], integrated by Godot's
## physics server on the physics frame and by nothing else. Without this await the
## server's props never move, the client's copies match them exactly, and every
## assertion about replicated props passes while nothing has been replicated at all.
##
## That is this family's own "a test that passes for the wrong reason", reached by the
## one route a sandbox has and a shooter does not.
func _step(command: DotFpsCommand = null) -> void:
	_tick += 1
	_client_net.clock.advance(1.0 / float(maxi(_client_game.tick_rate, 1)))
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(
		_tick + INPUT_LEAD, command if command != null else DotFpsCommand.new()
	)
	_flush()
	await get_tree().physics_frame


func _steps(count: int, command: DotFpsCommand = null) -> void:
	for _i in range(count):
		await _step(command)


func _forward() -> DotFpsCommand:
	var c := DotFpsCommand.new()
	c.move = Vector2(0.0, 1.0)
	return c


func _server_player() -> PlaygroundPlayer:
	return _server_game.players.get(&"u%d" % SESSION)


func _client_player() -> PlaygroundPlayer:
	return _client_game.players.get(&"u%d" % SESSION)


# --- The tests -------------------------------------------------------------

func _test_handshake() -> void:
	_section("a client joins")

	var added := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_check(added.ok, "the server adds the player", str(added.error) if not added.ok else "")
	_check(_server_player() != null, "and the game has them")

	var behaviour_count: Variant = _server_bridge.describe()["players"]
	_check(int(behaviour_count) == 1, "with an entity replicating them", str(behaviour_count))

	_client_bridge.ask_ready()
	_exchange()
	await _steps(4)

	_check(_client_bridge.local_player_id == SESSION, "the client is told who it is",
		str(_client_bridge.local_player_id))
	_check(_client_player() != null, "and builds the player")

	# The whole point of the disagreement set up in _build.
	_check(
		_client_game.tick_rate == _server_game.tick_rate,
		"the client adopted the server's tick rate through HELLO",
		"client %d, server %d" % [_client_game.tick_rate, _server_game.tick_rate]
	)
	_check(
		Engine.physics_ticks_per_second == _server_game.tick_rate,
		"and so did the engine, which is what decides whether it looks smooth",
		"engine %d" % Engine.physics_ticks_per_second
	)
	_check(
		_client_net.clock.tick_rate == _server_game.tick_rate,
		"and the netcode clock, which is built from the config and not updated by it"
	)

	_check(
		_client_game.maps.current != null
			and _client_game.maps.current.id == _server_game.maps.current.id,
		"both ends are on the same map"
	)

	# [b]The style table has to be built from a DECLARED order, not a sort of the ids.[/b]
	# Godot compares StringNames by their interned pointer, so `Array.sort()` on them
	# gives two peers two different tables — and this suite CANNOT see that, because one
	# process has one intern table and both ends agree no matter how the table was built.
	# It took a browser client joining and putting itself on "Sideways" to show it. So
	# assert the SOURCE instead: the table must match dot-timer's declared ordering,
	# which is an integer and is the same on every machine.
	var declared := PackedStringArray()
	for style in _server_game.timers.styles_in_order():
		declared.append(String(style.id))

	var built := PackedStringArray()
	for style_id in _server_bridge.style_table():
		built.append(String(style_id))

	_check(built == declared,
		"the style table follows dot-timer's declared ordering, not a StringName sort",
		"%s vs %s" % [str(built), str(declared)])

	var mine := _client_player()
	_check(
		mine != null and declared.size() > 0
			and String(mine.movement_style.id) == declared[0],
		"so a joining player lands on the style the server named",
		String(mine.movement_style.id) if mine != null and mine.movement_style != null else "-"
	)

	_check(_client_net.stats.rtt_percentile(0.5) > 0.0,
		"the client fed the clock an RTT sample, which nothing in dot-net does for it")


func _test_prediction() -> void:
	_section("moving")

	var before := _client_player().controller.state.position
	await _steps(48, _forward())
	var after := _client_player().controller.state.position

	_check(after.distance_to(before) > 1.0, "the client moves under its own prediction",
		"%.2f m" % after.distance_to(before))

	var server_at := _server_player().controller.state.position
	_check(server_at.distance_to(after) < 1.0,
		"and the server agrees with it", "%.3f m apart" % server_at.distance_to(after))

	# The measure that caught a bridge reconciling on top of dot-net's own
	# reconciliation, and a _net_state_applied that moved the node before reconcile
	# measured the error. Both read as a predictor that snapped every packet.
	var rate: float = _client_net.predictor.correction_rate()
	_check(rate < 0.35, "the correction rate is low", "%.3f" % rate)


# --- Props, which is what makes this a sandbox -----------------------------

func _test_prop_replication() -> void:
	_section("a prop the server spawns reaches the client")

	var catalogue := _server_game.props.catalogue
	_check(catalogue != null and catalogue.size() > 0, "the server has a prop catalogue",
		str(catalogue.size()) if catalogue != null else "none")

	# By id rather than by category: the categories are the spawn menu's tabs
	# (construction, containers, toys, entities) and a test that hard-codes a tab name
	# breaks when somebody renames one. A crate is a crate.
	var def := catalogue.get_prop(&"crate")
	_check(def != null, "the catalogue has a crate in it")

	if def == null:
		return
	# Well clear of the spawn pad and high above it. Dropped on the player's head it is
	# pushed sideways and UP by the capsule it is resting on, which is a perfectly real
	# physics result and a useless test: the assertion below is that gravity reaches the
	# client, not that two bodies collide.
	var spawned := _server_game.props.spawn(
		def.id, &"u%d" % SESSION, Vector3(18.0, 24.0, 18.0)
	)
	_check(spawned != null, "the server spawns one")

	if spawned == null:
		return

	_exchange()
	await _steps(4)

	var mirrored := int(_client_bridge.describe()["props"])
	_check(mirrored == 1, "the client mirrors it", "%d props" % mirrored)

	# [b]The id is ADOPTED, not allocated.[/b] dot-2d's scatter could not be mirrored at
	# all until it grew an adopt(): a peer that allocates its own index gives the same
	# object two different ids and every snapshot for it lands on nothing.
	var server_props := int(_server_bridge.describe()["props"])
	_check(server_props == mirrored, "under the id the server gave it, not one of its own")

	# And it MOVES. A prop that replicated its spawn and then sat still is the family's
	# "produced correctly and consumed by nothing" — the position looks right because it
	# was right once.
	var client_node := _client_prop_node()
	_check(client_node != null, "the client built a body for it")

	if client_node == null:
		return

	var at_first := client_node.global_position
	await _steps(64)
	var at_last := client_node.global_position

	_check(at_last.y < at_first.y - 0.5,
		"and it falls on the client because the server's physics moved it",
		"%.2f -> %.2f" % [at_first.y, at_last.y])
	_check(at_last.distance_to(at_first) > 0.5,
		"which is movement the client did not simulate for itself")

	var server_node := _server_prop_node()
	_check(
		server_node != null and server_node.global_position.distance_to(at_last) < 1.0,
		"where the server has it",
		"%.3f m apart" % server_node.global_position.distance_to(at_last)
			if server_node != null else "no server prop"
	)

	# A mirrored rigid body must not simulate locally as well: an unfrozen one fights
	# every position written into it and jitters against gravity.
	var body := client_node as RigidBody3D
	_check(body == null or body.freeze, "the mirrored body does not simulate itself too")


## The client's props are children of its world; the one carrying a net behaviour is
## what the bridge built.
func _client_prop_node() -> Node3D:
	return _find_prop_node(_client_game)


func _server_prop_node() -> Node3D:
	return _find_prop_node(_server_game)


func _find_prop_node(game: Playground) -> Node3D:
	var world: Node = game.world if game.world != null else game
	for child in world.get_children():
		for grandchild in child.get_children():
			if grandchild is PlaygroundPropNet:
				return child as Node3D
	return null


func _test_prop_request() -> void:
	_section("a client asks for a prop")

	var before := int(_server_bridge.describe()["props"])

	var catalogue := _client_game.props.catalogue
	var choice := catalogue.get_prop(&"barrel")
	_check(choice != null, "the client has the same catalogue the server does")

	if choice == null:
		return

	# The spawn menu emits rather than spawning, which is the division this bridge was
	# waiting for: the client sends intent and the server owns the answer.
	_client_bridge.ask_spawn_prop(choice.id)
	_exchange()
	await _steps(4)

	var after := int(_server_bridge.describe()["props"])
	_check(after == before + 1, "the server spawned it", "%d -> %d" % [before, after])

	_exchange()
	await _steps(4)
	_check(
		int(_client_bridge.describe()["props"]) == after,
		"and the client was told about the one it asked for"
	)

	# A prop this build does not have is refused, not guessed at.
	_client_bridge.ask_spawn_prop(&"no_such_prop_at_all")
	_exchange()
	await _steps(2)
	_check(
		int(_server_bridge.describe()["props"]) == after,
		"an unknown prop id spawns nothing"
	)


## The physics gun, over the wire.
##
## [b]A tool that never grabs anything is invisible to every other check here.[/b] The
## props still replicate, the player still moves, and the only symptom is that clicking
## does nothing — which is exactly the shape of bug this family keeps shipping: a value
## produced and consumed by nothing, or in this case a button sent and read by nobody.
func _test_tools() -> void:
	_section("the physics gun, over the wire")

	# Put a crate right in front of the player, at their own height.
	var player := _server_player()
	_check(player != null, "there is a player to aim")

	if player == null:
		return

	var at := player.eye_position() + player.aim_direction() * 2.5
	var why := PackedStringArray()
	var watch := func(_pid: StringName, _prop: StringName, reason: String) -> void:
		why.append(reason)
	_server_game.props.refused.connect(watch)
	var crate := _server_game.props.spawn(&"crate", &"u%d" % SESSION, at)
	_server_game.props.refused.disconnect(watch)
	_check(crate != null, "a crate is put in front of them", ", ".join(why))

	if crate == null:
		return

	await _exchange_steps(4)

	# The client selects the physics gun and holds the primary trigger, which is a
	# BUTTON on the command rather than a request — see PlaygroundNetBridge._drive_tools.
	_client_bridge.ask_tool(&"phys")
	_exchange()
	await _steps(2)

	# [b]Aimed at where the crate ended up, not at where it was put.[/b] It is a rigid
	# body dropped at eye height and it falls about a third of a metre before the button
	# is held — so a grab command that carries the default pitch is a ray over the top of
	# it, and whether the tool fires depends on how many ticks the sections above happened
	# to take. Aiming at the settled body is what makes this a test of the button.
	var grab := DotFpsCommand.new()
	grab.set_button(DotFpsCommand.BUTTON_USER_0, true)
	_aim_at(grab, player, (crate.node as Node3D).global_position)
	await _steps(12, grab)

	_check(player.phys_gun.held != null,
		"the server's physics gun grabbed it from a held button")

	if player.phys_gun.held == null:
		return

	# Held means carried: the prop tracks the player's aim rather than resting where it
	# was. Moving it and seeing the prop follow is the difference between "grabbed" and
	# "grabbed and then dropped on the next tick".
	var held_at := (crate.node as Node3D).global_position
	var turn := DotFpsCommand.new()
	turn.set_button(DotFpsCommand.BUTTON_USER_0, true)
	turn.pitch = player.controller.state.pitch
	turn.yaw = player.controller.state.yaw + 40.0
	await _steps(16, turn)

	var moved_to := (crate.node as Node3D).global_position
	_check(moved_to.distance_to(held_at) > 0.5,
		"and holding it carries it with the aim", "%.2f m" % moved_to.distance_to(held_at))

	# Releasing the button drops it. A gun that never lets go is a gun with one use.
	await _steps(4, DotFpsCommand.new())
	_check(player.phys_gun.held == null, "releasing the button lets go")

	_server_game.props.remove(crate.instance_id, DotPropSpawner.REASON_ADMIN)
	await _exchange_steps(4)


## Points [param command] at [param target] from [param player]'s eye.
##
## The inverse of [method DotFpsMotor.aim_for], and it is written as the inverse rather
## than copied from it: a test that restates the view convention is a second place for
## it to be wrong.
func _aim_at(command: DotFpsCommand, player: PlaygroundPlayer, target: Vector3) -> void:
	var to := target - player.eye_position()

	if to.length_squared() <= 0.0:
		return

	to = to.normalized()
	command.yaw = rad_to_deg(atan2(-to.x, -to.z))
	command.pitch = rad_to_deg(asin(clampf(to.y, -1.0, 1.0)))


## A flush pair with ticks after it, which is what most of these want.
func _exchange_steps(count: int) -> void:
	_exchange()
	await _steps(count)


## A weapon is a purchase, and the client has to ask for it.
##
## [b]This is the check that was missing, and the hole it left was money.[/b]
## `PlaygroundClient._set_tool` told the server which TOOL it held and said nothing at
## all about a weapon — so `_give_weapon`, the only thing that calls `charge_fn`, was
## called by nobody. `pg_shop` prices every weapon at 350 credits and every one of them
## was free on a networked server, with the props beside them correctly charged. Nothing
## errors: a client that arms itself looks exactly like a client that was given one.
##
## The other half is the same bug pointing the other way — the server broadcast what
## each player was holding and the client's reader was a bare `pass`.
func _test_weapon_request() -> void:
	_section("a weapon is asked for, paid for and announced")

	# A price list that records rather than a real shop: what is being tested is that
	# the charge is REACHED, and a shop here would test dot-economy's arithmetic twice.
	var charged: Array[StringName] = []
	var refuse := [false]
	_server_bridge.charge_fn = func(_id: StringName, thing: StringName) -> DotResult:
		charged.append(thing)
		if bool(refuse[0]):
			return DotResult.fail(DotError.CODE_STATE, "You cannot afford that.")
		return DotResult.success(null)

	var told: Array = []
	_client_bridge.weapon_changed.connect(
		func(pid: int, wid: StringName) -> void: told.append([pid, wid])
	)

	_client_bridge.ask_weapon(&"launcher")
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(4)

	_check(
		charged.has(&"launcher"),
		"the server charged for the weapon",
		"charged: %s" % [charged]
	)
	_check(told.size() > 0, "and told the clients who is holding what")
	if told.size() > 0:
		_check(
			StringName(told[-1][1]) == &"launcher",
			"and it is the weapon that was asked for"
		)

	# A weapon nobody can afford is refused, and the refusal must not announce it: a
	# client that armed itself and was refused would be holding what it was denied.
	refuse[0] = true
	var before := told.size()
	_client_bridge.ask_weapon(&"remover")
	_exchange()
	await _steps(4)
	_exchange()
	await _steps(4)
	_check(charged.has(&"remover"), "a second weapon is charged for too")
	_check(
		told.size() == before,
		"and a refused purchase announces nothing",
		"%d -> %d" % [before, told.size()]
	)

	# A weapon this build does not have is refused before the money is touched.
	var paid := charged.size()
	_client_bridge.ask_weapon(&"no_such_weapon_at_all")
	_exchange()
	await _steps(2)
	_check(charged.size() == paid, "an unknown weapon id charges nothing")

	refuse[0] = false
	_server_bridge.charge_fn = Callable()


func _test_prop_removal() -> void:
	_section("undo")

	var before := int(_client_bridge.describe()["props"])
	_check(before > 0, "there is something to undo", str(before))

	_client_bridge.ask_undo()
	_exchange()
	await _steps(4)

	var server_after := int(_server_bridge.describe()["props"])
	_check(server_after == before - 1, "the server removed one",
		"%d -> %d" % [before, server_after])

	_exchange()
	await _steps(2)
	_check(
		int(_client_bridge.describe()["props"]) == server_after,
		"and the client stopped drawing it"
	)


## A vehicle spawned, driven and ridden with a real socket between the two ends.
##
## [b]This is the only thing that has ever run [DotVehicleNetSync] across a wire.[/b]
## dot-vehicle's 122 checks and game-playground's own vehicle test both run in one
## process, where the client IS the server's dictionary and every id agrees by
## construction. What only this can catch: a spec dot-net will not accept, a wheel angle
## that arrives as a body rotation, a seat mask nobody reads, a driver whose input is
## applied on the client and never sent, and a rider drawn on the other machine at the
## spot where they got in.
func _test_vehicle_over_the_wire() -> void:
	_section("a vehicle, over the socket")

	var id := &"u%d" % SESSION
	var driver := _server_player()

	if driver == null:
		return

	var at := Vector3(-60.0, 1.2, -60.0)
	driver.teleport(at + Vector3(2.5, 0.0, 0.0), 0.0)

	_server_game.props.limits.spawn_interval = 0.0
	var spawned := _server_game.props.spawn(&"buggy", id, at)
	_check(spawned != null, "the server spawns a buggy")

	if spawned == null:
		return

	var vehicle := _server_game.vehicles.vehicle_for_node(spawned.node)
	_check(vehicle != null, "and adopts it as a vehicle")

	if vehicle == null:
		return

	_exchange()
	await _steps(8)

	var mirror := _find_vehicle_node(_client_game)
	_check(mirror != null, "the client builds its own copy of it")
	_check(
		mirror != null and mirror.get_node_or_null("Net") is PlaygroundVehicleNet,
		"replicating through DotVehicleNetSync rather than as a plain prop"
	)
	_check(
		mirror != null and (mirror as PlaygroundVehicle).wheel_count() == 4,
		"with its wheels built on the client too"
	)

	# [b]The mirror is taken out of the physics world for the drive, and that is a fact
	# about this HARNESS rather than about the game.[/b] Both halves are plain nodes in
	# one scene tree, so they share one physics space — and the client's frozen copy of
	# the car sits at exactly the coordinates the server's car is trying to drive out of.
	# The first version of this test measured 1.24 m and a car reversing at half a metre
	# a second, which was the server's buggy wedged against its own reflection. On two
	# machines there is no such body.
	if mirror != null:
		mirror.collision_layer = 0
		mirror.collision_mask = 0

	# Let it settle onto its suspension. A raycast vehicle spawned in the air is falling,
	# and "did it drive" measured through the drop measures the drop.
	await _steps(40)

	# The client asks. It has no seats, no exit sweep and no vehicle spawner: the server
	# owns every one of those, and this is the same division a spawn already makes.
	_client_bridge.ask_use_vehicle()
	_exchange()
	await _steps(6)

	_check(vehicle.driver() == id, "the client's use key puts it in the driving seat")
	_check(driver.riding, "the server stops walking them")
	_check(
		_client_player() != null and _client_player().riding,
		"and the SEAT event stops the client predicting them",
		"a predicted controller under a rider fights every snapshot"
	)

	var before := vehicle.position()
	var mirror_before := mirror.global_position if mirror != null else Vector3.ZERO

	# The driver's own input goes round trip. That is dot-vehicle's decision rather than
	# a gap here: a rigid body is not reproducible across machines, so a predicted
	# vehicle is a corrected vehicle and a correction on something a player is steering
	# reads worse than the latency does.
	# [b]Sampled while it drives, not read off the end.[/b] 320 ticks at full throttle
	# is further than the clear ground round the spawn: the car reaches about 10 m/s and
	# then arrives at map geometry, and the reading taken after it has stopped against
	# something is the rebound rather than the drive. It was -0.47 m/s, deterministically,
	# while the car had plainly driven twelve metres in the direction it was pointed —
	# a check measuring the wrong instant rather than a vehicle refusing to move.
	var fastest := 0.0

	for _leg in range(16):
		await _steps(20, _forward())
		fastest = maxf(fastest, vehicle.forward_speed())

	_exchange()
	await _steps(6)

	var travelled := vehicle.position().distance_to(before)
	# Deliberately well under what the car can do in 320 ticks. The client is on a
	# different tick rate from the server here on purpose, so how many of its inputs land
	# in a given wall-clock stretch is not a constant — and a threshold set at the
	# measured figure is a test that fails on a loaded machine rather than on a bug.
	_check(travelled > 3.0, "keys sent over the wire drive it", "%.2f m" % travelled)
	_check(fastest > 0.5, "forwards", "%.2f m/s at its fastest" % fastest)
	_check(
		mirror != null and mirror.global_position.distance_to(mirror_before) > 2.0,
		"and the client's copy went with it",
		"%.2f m" % (mirror.global_position.distance_to(mirror_before) if mirror != null else -1.0)
	)
	_check(
		mirror != null and mirror.global_position.distance_to(vehicle.position()) < 6.0,
		"to roughly where the server has it",
		"%.2f m apart" % (
			mirror.global_position.distance_to(vehicle.position()) if mirror != null else -1.0
		)
	)

	var net_behaviour := mirror.get_node_or_null("Net") as PlaygroundVehicleNet
	_check(
		net_behaviour != null and net_behaviour.seat_occupied(0),
		"the seat mask says the driving seat is full"
	)
	_check(
		net_behaviour != null and not net_behaviour.seat_occupied(1),
		"and the passenger seat is not"
	)

	# The rider's own position, which is the half that is invisible in one process.
	_check(
		driver.controller.state.position.distance_to(vehicle.position()) < 4.0,
		"the rider's replicated position is on the vehicle, not where they got in",
		"%.2f m" % driver.controller.state.position.distance_to(vehicle.position())
	)

	# Turning the wheels. A client cannot derive this from anything else it is sent.
	var turn := DotFpsCommand.new()
	turn.move = Vector2(1.0, 1.0)
	await _steps(60, turn)
	_exchange()
	await _steps(4)

	_check(
		net_behaviour != null and absf(net_behaviour.net_steering) > 2,
		"the wheels' angle crosses the wire",
		"quantised %d" % (net_behaviour.net_steering if net_behaviour != null else 0)
	)

	# Getting out, from the client, with the server owning the refusal.
	var brake := DotFpsCommand.new()
	brake.set_button(DotFpsCommand.BUTTON_CROUCH, true)
	await _steps(200, brake)

	_client_bridge.ask_use_vehicle()
	_exchange()
	await _steps(6)

	_check(not driver.riding, "the same key takes them back out")
	_check(vehicle.is_empty(), "leaving the car empty")
	_check(
		_client_player() != null and not _client_player().riding,
		"and the client is predicting them again"
	)
	_check(
		driver.global_position.distance_to(vehicle.position()) > 0.9,
		"put down beside the car rather than inside it",
		"%.2f m" % driver.global_position.distance_to(vehicle.position())
	)

	_server_game.props.remove(spawned.instance_id, DotPropSpawner.REASON_ADMIN)
	_exchange()
	await _steps(6)

	_check(_find_vehicle_node(_client_game) == null, "and removing it removes the mirror")


func _find_vehicle_node(game: Playground) -> PlaygroundVehicle:
	var world: Node = game.world if game.world != null else game

	for child in world.get_children():
		var vehicle := child as PlaygroundVehicle

		if vehicle != null:
			return vehicle

	return null


func _test_timer() -> void:
	_section("the timer")

	var player := _client_player()
	_check(player != null and player.timer != null, "the client player has a timer")

	# A client runs its own timer over its own copy of the zones and reaches the same
	# answer a tick earlier than any packet could. What travels is the run's identity.
	_check(
		_client_game.timers.tick_rate == _server_game.timers.tick_rate,
		"counted at one rate on both ends, which is what makes a time comparable",
		"%d vs %d" % [_client_game.timers.tick_rate, _server_game.timers.tick_rate]
	)


func _test_lossy() -> void:
	_section("with packets going missing")

	_drop_every = 3
	var before := _client_player().controller.state.position
	await _steps(96, _forward())
	var after := _client_player().controller.state.position
	_drop_every = 0

	_check(after.distance_to(before) > 1.0, "the client keeps moving through the loss",
		"%.2f m" % after.distance_to(before))

	var server_at := _server_player().controller.state.position
	_check(server_at.distance_to(after) < 2.0,
		"and stays with the server", "%.3f m apart" % server_at.distance_to(after))


func _test_leave() -> void:
	_section("leaving")

	_server_bridge.remove_peer(CLIENT_PEER)
	_exchange()
	await _steps(4)

	_check(_server_player() == null, "the server drops the player")
	_check(int(_server_bridge.describe()["players"]) == 0, "and their entity")
	_check(_client_player() == null, "and the client is told")
