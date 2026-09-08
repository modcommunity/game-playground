class_name PlaygroundNetBridge
extends Node

## Joins a [Playground] to a [DotNetManager]. The netcode seam, and the only file in
## this project that names both.
##
## [b]The ordering is the whole file.[/b] dot-net drives simulation per entity, and this
## game's tick is a whole-game property: every NPC moves, then every player, then every
## timer is fed the position its move produced. [method ensure_game_ticked] reconciles
## the two — the first behaviour through on a tick runs the whole game, the rest find it
## done.
##
## [codeblock]
## # server
## bridge.attach(game, net, server)      # `server` is the node the link mirrors
## bridge.add_player(peer_id, session_id, "Ada")
## bridge.server_tick(tick)              # instead of the game's own loop
##
## # client
## bridge.attach(game, net, client_link)
## bridge.ask_ready()
## bridge.client_tick(tick, command)
## [/codeblock]
##
## [b]What is predicted and what is not.[/b] A player's own movement is predicted, like
## every other first-person game in this family. Props, NPCs and everything the physics
## gun touches are server-authoritative and NOT predicted, because Godot's rigid-body
## solver is not reproducible across machines — see [PlaygroundPropNet]. That division
## is why the spawn menu emits rather than spawning and the tools send intent: the
## client half was built for this bridge before the bridge existed.

const CHANNEL := "pg.net"
const ACK_BYTES := 4

## The client has been told who it is. [param player_id] is the session id.
signal hello_received(player_id: int)
signal roster_changed(player_id: int)
## A prop or entity appeared or went away, on a client. For the HUD's counter.
signal props_changed()
signal finish_received(player_id: int, time: float, rank: int)
signal notice_received(player_id: int, text: String)

var game: Playground = null
var net: DotNetManager = null
var link: PlaygroundNetLink = null

## Which session this process is. Zero on a server.
var local_player_id: int = 0

## Where the clock learns how long the link is, in milliseconds. dot-net never touches a
## transport and cannot measure it; dot-server's heartbeat already does
## ([method DotClientLink.ping_ms]), and a client that feeds nothing has a clock that
## assumes an instant connection and stamps every command for a tick the server has
## already simulated. Read on every snapshot.
##
## Nothing in dot-net writes a sample. It was shipped without one in two games before
## anybody noticed the clock was reading a median of an empty set.
var rtt_source: Callable = Callable()

var _entities: Node = null
var _behaviours: Dictionary = {}
var _prop_nets: Dictionary = {}

## session_id -> which tool that player is holding. The server's copy, because the
## server is what acts: a client saying "I am holding the gravity gun" is a claim, and
## the tool decides what a trigger DOES to somebody else's prop.
var _tool_of: Dictionary = {}

## session_id -> the buttons that player's previous command carried, so a press can be
## told from a hold. A physics gun grabs on the press and holds every tick after it;
## grabbing every tick instead would re-target continuously and drag whatever the
## crosshair crossed.
var _prev_buttons: Dictionary = {}
var _player_of_peer: Dictionary = {}
var _peer_of_player: Dictionary = {}
var _ready_peers: Dictionary = {}
var _tick: int = 0
var _game_ticked_for: int = -1
var _client_ticked_for: int = -1

## A style index -> id table both ends build identically, so a style travels as one
## byte rather than as a string on every join.
var _style_ids: Array[StringName] = []


# --- Wiring ----------------------------------------------------------------

func attach(p_game: Playground, p_net: DotNetManager, link_parent: Node) -> DotResult:
	if p_game == null or p_net == null or link_parent == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs all three.")

	if p_game.authoritative != p_net.is_server:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The game and the manager disagree about who is authoritative.",
			"game=%s net.is_server=%s" % [p_game.authoritative, p_net.is_server]
		)

	game = p_game
	net = p_net

	_entities = Node.new()
	_entities.name = "Entities"
	add_child(_entities)

	# [b]dot-timer's declared ordering, NOT a sort of the ids.[/b] The first draft
	# collected `game.movement_styles`' keys and called `Array.sort()` on them — and
	# Godot compares StringNames by their INTERNED POINTER, not lexicographically. Two
	# peers therefore build two different tables, and a style index means a different
	# style on each end: this client joined a server that said index 0 and put itself on
	# "Sideways". It is the same bug that gave two peers two different wire ids for one
	# message type in dot-net, and it is invisible in any one-process test, because one
	# process has one intern table and both ends agree by construction.
	#
	# `styles_in_order` sorts on a declared integer, which is the same on every machine.
	for style in game.timers.styles_in_order():
		_style_ids.append(style.id)

	net.send_fn = _send

	var event := net.messages.register(
		PlaygroundEvent.NAME, PlaygroundEvent,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT
	)
	if not event.ok:
		return event
	var request := net.messages.register(
		PlaygroundRequest.NAME, PlaygroundRequest,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_SERVER
	)
	if not request.ok:
		return request

	net.messages.on(PlaygroundEvent.NAME, _on_event)
	net.messages.on(PlaygroundRequest.NAME, _on_request)

	link = PlaygroundNetLink.attached_to(link_parent, self, net.is_server)

	# Both ends: the server's tick is server_tick, and the client's is client_tick,
	# which simulates what it predicts and leaves the rest to interpolation. A client
	# game still running its own loop would simulate the local player twice a tick and
	# dead-reckon every remote one from stale state.
	game.external_tick = true

	if net.is_server:
		game.player_added.connect(_on_player_added)
		game.player_removed.connect(_on_player_removed)
		game.props.spawned.connect(_on_prop_spawned)
		game.props.removed.connect(_on_prop_removed)
		game.props.refused.connect(_on_prop_refused)
		game.map_ready.connect(_on_map_ready)
		game.timers.player_started.connect(_on_run_changed)
		game.timers.player_stopped.connect(_on_run_stopped)
		game.run_filed.connect(_on_run_filed)

	return DotResult.success(true)


## How every dot-net message reaches a peer.
##
## [b]Routed by DELIVERY, not by kind.[/b] Snapshots are unreliable and go on the
## snapshot call; everything else is reliable, and which reliable call it is depends on
## which end is sending — the server has events, the client has requests. Sending them
## all as events works on a server and silently drops every client request, which is a
## client that connects, draws, and can never ask for anything.
func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return
	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		link.send_request(payload)


# --- Identity helpers ------------------------------------------------------

static func _player_key(session_id: int) -> StringName:
	return StringName("u%d" % session_id)


static func session_of(id: StringName) -> int:
	return String(id).trim_prefix("u").to_int()


func peer_for_player(session_id: int) -> int:
	return int(_peer_of_player.get(session_id, 0))


func player_for_peer(peer_id: int) -> int:
	return int(_player_of_peer.get(peer_id, 0))


func _style_index(style_id: StringName) -> int:
	var at := _style_ids.find(style_id)
	return at if at >= 0 else 0


func _style_id(index: int) -> StringName:
	if index < 0 or index >= _style_ids.size():
		return &"normal"
	return _style_ids[index]


# --- Server: players -------------------------------------------------------

func add_player(peer_id: int, session_id: int, display_name: String) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	var id := _player_key(session_id)

	if peer_id > 0:
		_player_of_peer[peer_id] = session_id
		_peer_of_player[session_id] = peer_id

	# add_player emits player_added, which _on_player_added answers by building the
	# entity and announcing the JOIN. The peer mapping is set FIRST so that handler
	# can find the peer this player belongs to.
	var player := game.add_player(id, display_name)

	if player == null:
		_player_of_peer.erase(peer_id)
		_peer_of_player.erase(session_id)
		return DotResult.fail(DotError.CODE_STATE, "The game refused the player.")

	return DotResult.success(player)


func remove_peer(peer_id: int) -> void:
	if _player_of_peer.has(peer_id):
		remove_player(int(_player_of_peer[peer_id]))


## Removes a player whether or not a peer is behind it — a bot has none.
func remove_player(session_id: int) -> void:
	if not _behaviours.has(session_id):
		return

	var peer_id := peer_for_player(session_id)
	var was_ready := _ready_peers.has(peer_id)
	_player_of_peer.erase(peer_id)
	_peer_of_player.erase(session_id)
	_ready_peers.erase(peer_id)
	_tool_of.erase(session_id)
	_prev_buttons.erase(session_id)

	# Released BEFORE the game is told: game.remove_player emits player_removed, which
	# _on_player_removed answers by releasing the entity and broadcasting LEAVE.
	# Releasing first empties _behaviours, so that handler finds nothing and this
	# function stays the one place a leaving player is announced.
	_release_entity(session_id)
	game.remove_player(_player_key(session_id))

	if net != null and peer_id > 0:
		if was_ready:
			net.remove_peer(peer_id)
		if net.interest != null:
			net.interest.forget_peer(peer_id)

	_broadcast(PlaygroundEvents.Kind.LEAVE, PlaygroundEvents.write_player(session_id))
	roster_changed.emit(session_id)


## A player the game made itself — a bot, a test — gets an entity exactly like one a
## peer asked for. Its peer id is zero, and that is not the broadcast address by
## accident: [method _tell] refuses zero, because `net.send(msg, 0)` IS a broadcast and
## game-hungario once sent every player's private message to everybody through exactly
## this hole.
func _on_player_added(id: StringName) -> void:
	if net == null or not net.is_server:
		return

	var session_id := session_of(id)

	if _behaviours.has(session_id):
		return

	var player: PlaygroundPlayer = game.players.get(id)
	if player == null:
		return

	var identity := _build_entity(player, peer_for_player(session_id))
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a player", {"error": str(registered.error)})
		return

	_broadcast(PlaygroundEvents.Kind.JOIN, _join_body(session_id))
	roster_changed.emit(session_id)


func _on_player_removed(id: StringName) -> void:
	var session_id := session_of(id)
	if _behaviours.has(session_id):
		# The game removed it itself; the entity and the LEAVE are still ours.
		_release_entity(session_id)
		_broadcast(PlaygroundEvents.Kind.LEAVE, PlaygroundEvents.write_player(session_id))
		roster_changed.emit(session_id)


func _build_entity(player: PlaygroundPlayer, peer_id: int) -> DotNetIdentity:
	# The behaviour is added BEFORE the identity: DotNetIdentity collects behaviours in
	# _ready by walking the subtree, and one added afterwards would never be found.
	var behaviour := PlaygroundPlayerNet.new()
	behaviour.name = "Net"
	behaviour.player = player
	behaviour.bridge = self
	player.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = peer_id
	# SHARED: the server corrects, the owner predicts. SERVER would put a player's own
	# movement a round trip behind their keys.
	identity.authority = DotNetIdentity.Authority.SHARED
	identity.always_relevant = true
	player.add_child(identity)

	_behaviours[session_of(player.player_id)] = behaviour
	return identity


func _release_entity(session_id: int) -> void:
	var behaviour: PlaygroundPlayerNet = _behaviours.get(session_id)
	_behaviours.erase(session_id)

	if behaviour == null or behaviour.identity == null or net == null:
		return

	net.registry.unregister(behaviour.identity.net_id)


# --- Server: props ---------------------------------------------------------

## Every prop the spawner creates becomes a replicated entity.
##
## [b]Announced reliably AND replicated by snapshot, and it needs both.[/b] The snapshot
## moves it; the event says what it is, because a client cannot build a barrel from a
## position. A spawner factory would have to name a script, and this game's props are
## named by PATH in the catalogue precisely so a dot-cloud pack can deliver them — a
## mounted pack's `class_name` globals are not registered in the host.
func _on_prop_spawned(prop: DotPropInstance) -> void:
	if net == null or not net.is_server or prop == null or prop.node == null:
		return

	var body := prop.node as Node3D
	if body == null:
		return

	var behaviour := PlaygroundPropNet.new()
	behaviour.name = "Net"
	behaviour.prop = body
	body.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	# SERVER, not SHARED: nothing about a rigid body is predicted, so there is no owner
	# to share with. See PlaygroundPropNet for why that is a decision and not a gap.
	identity.authority = DotNetIdentity.Authority.SERVER
	body.add_child(identity)

	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a prop", {"error": str(registered.error)})
		return

	_prop_nets[prop.instance_id] = behaviour
	behaviour.pull()

	_broadcast(PlaygroundEvents.Kind.PROP, PlaygroundEvents.write_prop(
		identity.net_id,
		prop.def.id,
		session_of(prop.owner_id),
		PlaygroundSpawnables.kind_of(prop.def) == PlaygroundSpawnables.Kind.ENTITY,
		body.global_position
	))


func _on_prop_removed(prop: DotPropInstance, reason: StringName) -> void:
	if net == null or not net.is_server or prop == null:
		return

	var behaviour: PlaygroundPropNet = _prop_nets.get(prop.instance_id)
	_prop_nets.erase(prop.instance_id)

	if behaviour == null or behaviour.identity == null:
		return

	var net_id := behaviour.identity.net_id
	net.registry.unregister(net_id)

	_broadcast(PlaygroundEvents.Kind.PROP_GONE, PlaygroundEvents.write_prop_gone(net_id, reason))


## A refusal goes to the one player who asked, not to everybody. A budget message is
## the most common thing this server says and it is nobody else's business.
func _on_prop_refused(player_id: StringName, prop_id: StringName, reason: String) -> void:
	var session_id := session_of(player_id)
	_tell(peer_for_player(session_id), PlaygroundEvents.Kind.NOTICE,
		PlaygroundEvents.write_notice(session_id, "Cannot spawn %s: %s" % [prop_id, reason]))


# --- Server: the tick ------------------------------------------------------

func server_tick(tick: int) -> void:
	_tick = tick
	_game_ticked_for = -1
	if net != null:
		net.server_tick(tick)
	ensure_game_ticked(tick)


func ensure_game_ticked(tick: int) -> void:
	if _game_ticked_for == tick or game == null:
		return
	_game_ticked_for = tick

	for session_id in _behaviours:
		var behaviour: PlaygroundPlayerNet = _behaviours[session_id]
		# Only what a peer sent. A bot has no peer and is driven by something else — a
		# test, an AI — and an empty command applied over the top of that would stand
		# it still.
		if behaviour.player != null and behaviour.identity != null \
				and behaviour.identity.owner_peer_id > 0:
			behaviour.player.controller.apply_command(behaviour.last_move.duplicate_command())

	game.tick_once(tick)

	# The tools, from the buttons the commands carried. After the movement, because a
	# gun is aimed from where the player ENDED the tick.
	for session_id in _behaviours:
		_drive_tools(int(session_id), _behaviours[session_id])

	# After the game moved them, before the snapshot is built. A prop pulled before the
	# physics step would replicate where it was last tick, which is the whole family's
	# "produced correctly and consumed by nothing" one step along: correct data, wrong
	# instant, and nothing errors.
	for instance_id in _prop_nets:
		(_prop_nets[instance_id] as PlaygroundPropNet).pull()


## Runs one player's physics gun or gravity gun from the buttons their command carried.
##
## [b]The triggers are BUTTONS, not requests.[/b] They are per-tick and continuous —
## holding a prop is a thing you do every tick, not an event — so they ride in
## [member DotFpsCommand.buttons] beside jump and crouch. Sending them as reliable
## requests would put every grab a round trip behind the mouse and would reorder against
## the movement they are aimed with.
##
## [b]And the server actuates them, not the client.[/b] The client's own copy of a prop
## is frozen and drawn from snapshots; it could not move one if it tried. That is the
## same decision [PlaygroundPropNet] documents, seen from the input end.
func _drive_tools(session_id: int, behaviour: PlaygroundPlayerNet) -> void:
	if behaviour == null or behaviour.player == null or behaviour.identity == null:
		return
	if behaviour.identity.owner_peer_id <= 0:
		return

	var player := behaviour.player
	var buttons := behaviour.last_move.buttons
	var before := int(_prev_buttons.get(session_id, 0))
	_prev_buttons[session_id] = buttons

	var primary := (buttons & DotFpsCommand.BUTTON_USER_0) != 0
	var secondary := (buttons & DotFpsCommand.BUTTON_USER_1) != 0
	var primary_pressed := primary and (before & DotFpsCommand.BUTTON_USER_0) == 0
	var secondary_pressed := secondary and (before & DotFpsCommand.BUTTON_USER_1) == 0

	var space := player.get_world_3d().direct_space_state if player.is_inside_tree() else null
	var origin := player.eye_position()
	var aim := player.aim_direction()
	var view := Basis()
	var delta := 1.0 / float(maxi(game.tick_rate, 1))
	var may_touch := game.may_touch_others()

	var tool_id: StringName = _tool_of.get(session_id, &"phys")

	if tool_id == &"grav":
		if primary_pressed:
			player.grav_gun.punt(space, origin, aim, may_touch)
		if secondary_pressed:
			player.grav_gun.pull(space, origin, aim, may_touch)
		elif secondary:
			player.grav_gun.carry(origin, aim, delta)
		elif not secondary and player.grav_gun.is_carrying():
			player.grav_gun.drop()
		return

	if primary_pressed:
		player.phys_gun.grab(space, origin, aim, view, may_touch)
	elif primary:
		player.phys_gun.hold(origin, aim, view, delta)
	elif not primary:
		player.phys_gun.release()

	if secondary_pressed:
		player.phys_gun.freeze_held()


# --- The client tick -------------------------------------------------------

func client_tick(tick: int, command: DotFpsCommand) -> void:
	if net == null or net.is_server or game == null:
		return

	_tick = tick

	var packet := PlaygroundNetCommand.new()
	packet.tick = tick
	packet.delta = net.clock.tick_duration()
	packet.move = command if command != null else DotFpsCommand.new()

	# Into the local history BEFORE predicting: reconciliation replays it.
	net.local_inputs().push(packet)

	# The behaviour simulates from last_move, on a fresh tick and on a replayed one
	# alike — the predictor's replay sets it through _net_apply_input, and this is the
	# fresh tick's equivalent.
	var mine: PlaygroundPlayerNet = _behaviours.get(local_player_id)
	if mine != null:
		mine.last_move = packet.move

	if link != null:
		var payload := net.encode_ack()
		var writer := DotNetWriter.new()
		packet.write(writer)
		payload.append_array(writer.to_bytes())
		link.send_input(payload)

	# The client game ticks once: predicted players simulate through their behaviours,
	# and every timer — including remote players' — is fed afterwards. Props are not
	# simulated here at all; they are drawn from snapshots.
	if _client_ticked_for != tick:
		_client_ticked_for = tick
		for identity in net.registry.predicted():
			for behaviour in identity.behaviours:
				behaviour._net_simulate(tick, net.clock.tick_duration())
		game.tick_timers_only(tick)


# --- Receiving -------------------------------------------------------------

func receive_snapshot(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client receives these.")
	if rtt_source.is_valid():
		net.stats.note_rtt(float(rtt_source.call()))
	return net.receive_snapshot(payload)


func receive_input(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server takes input.")
	if not _player_of_peer.has(peer_id):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "That peer has no player.")
	if payload.size() <= ACK_BYTES:
		return DotResult.fail(DotError.CODE_PARSE, "Input packet is too short.")

	net.receive_ack_payload(peer_id, payload.slice(0, ACK_BYTES))

	var packet := PlaygroundNetCommand.new()
	packet.read(DotNetReader.new(payload.slice(ACK_BYTES)))
	return net.input_buffer_for(peer_id).push(packet)


func receive_event(payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")
	return net.receive(payload, 1)


func receive_request(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")
	return net.receive(payload, peer_id)


# --- Server: what a joining peer is told -----------------------------------

func _admit(peer_id: int) -> void:
	if peer_id <= 0 or not _player_of_peer.has(peer_id):
		return

	_ready_peers[peer_id] = true
	if not net.peers().has(peer_id):
		net.add_peer(peer_id)

	var session_id := int(_player_of_peer[peer_id])

	_tell(peer_id, PlaygroundEvents.Kind.HELLO, PlaygroundEvents.write_hello(
		session_id, game.tick_rate, net.clock.tick,
		game.maps.current.id if game.maps.current != null else &""
	))

	for other in _behaviours.keys():
		_tell(peer_id, PlaygroundEvents.Kind.JOIN, _join_body(int(other)))

	# And everything already in the world. A player who joins a sandbox that has been
	# running for an hour has to be told about the hour's worth of props, or they walk
	# into things they cannot see.
	for instance_id in _prop_nets.keys():
		var prop := game.props.get_prop(int(instance_id))
		var behaviour: PlaygroundPropNet = _prop_nets[instance_id]
		if prop == null or behaviour == null or behaviour.identity == null:
			continue
		_tell(peer_id, PlaygroundEvents.Kind.PROP, PlaygroundEvents.write_prop(
			behaviour.identity.net_id,
			prop.def.id,
			session_of(prop.owner_id),
			PlaygroundSpawnables.kind_of(prop.def) == PlaygroundSpawnables.Kind.ENTITY,
			behaviour.net_position
		))


func _join_body(session_id: int) -> PackedByteArray:
	var behaviour: PlaygroundPlayerNet = _behaviours.get(session_id)
	if behaviour == null or behaviour.identity == null or behaviour.player == null:
		return PackedByteArray()

	var player := behaviour.player
	return PlaygroundEvents.write_join(
		session_id,
		behaviour.identity.net_id,
		player.display_name,
		_style_index(player.movement_style.id if player.movement_style != null else &"normal")
	)


func _on_map_ready(map: DotMapDef) -> void:
	_broadcast(PlaygroundEvents.Kind.MAP, PlaygroundEvents.write_map(map.id))
	# Re-announced after a map change: a client rebuilt its world and needs to be told
	# who is in it again. dot-map's own sync replaces the world and nothing else.
	for session_id in _behaviours.keys():
		_broadcast(PlaygroundEvents.Kind.JOIN, _join_body(int(session_id)))


func _on_run_changed(id: StringName, _run: DotTimerRun) -> void:
	_send_timer(session_of(id))


func _on_run_stopped(id: StringName, _run: DotTimerRun, _reason: StringName) -> void:
	_send_timer(session_of(id))


func _send_timer(session_id: int) -> void:
	var player: PlaygroundPlayer = game.players.get(_player_key(session_id))
	if player == null or player.timer == null:
		return

	var run := player.timer.run
	if run == null:
		return

	var style_id := player.timer_style.id if player.timer_style != null else &"normal"
	var state := DotTimerNet.state_of(run, _tick, _style_index(style_id))

	_broadcast(PlaygroundEvents.Kind.TIMER, PlaygroundEvents.write_timer(session_id, state))


func _on_run_filed(id: StringName, run: DotTimerRun, rank: int, reason: String) -> void:
	var session_id := session_of(id)
	if run == null:
		return

	var finish := DotTimerNet.finish_of(run, _style_index(run.style_id), rank)
	_broadcast(PlaygroundEvents.Kind.FINISH,
		PlaygroundEvents.write_finish(session_id, finish))

	if reason != "":
		_tell(peer_for_player(session_id), PlaygroundEvents.Kind.NOTICE,
			PlaygroundEvents.write_notice(session_id, "Not recorded: %s" % reason))


# --- Client: asking --------------------------------------------------------

func ask_ready() -> void:
	_ask(PlaygroundEvents.Ask.READY, PackedByteArray())


func ask_spawn_prop(prop_id: StringName) -> void:
	_ask(PlaygroundEvents.Ask.SPAWN_PROP, PlaygroundEvents.write_id(prop_id))


func ask_weapon(weapon_id: StringName) -> void:
	_ask(PlaygroundEvents.Ask.GIVE_WEAPON, PlaygroundEvents.write_id(weapon_id))


func ask_tool(tool_id: StringName) -> void:
	_ask(PlaygroundEvents.Ask.SELECT_TOOL, PlaygroundEvents.write_id(tool_id))


func ask_undo() -> void:
	_ask(PlaygroundEvents.Ask.UNDO, PackedByteArray())


func ask_clear_mine() -> void:
	_ask(PlaygroundEvents.Ask.CLEAR_MINE, PackedByteArray())


func ask_restart() -> void:
	_ask(PlaygroundEvents.Ask.RESTART, PackedByteArray())


func ask_checkpoint(action: int) -> void:
	_ask(PlaygroundEvents.Ask.CHECKPOINT, PlaygroundEvents.write_index(action))


func ask_rtv() -> void:
	_ask(PlaygroundEvents.Ask.RTV, PackedByteArray())


func ask_style(style_id: StringName) -> void:
	_ask(PlaygroundEvents.Ask.STYLE, PlaygroundEvents.write_index(_style_index(style_id)))


func _ask(kind: int, body: PackedByteArray) -> void:
	if net != null and not net.is_server:
		net.send(PlaygroundRequest.of(kind, body), 1)


# --- Server: answering -----------------------------------------------------

func _on_request(message: DotNetMessage) -> void:
	var ask := message as PlaygroundRequest
	if ask == null or net == null or not net.is_server:
		return

	var peer_id := ask.sender_peer_id
	var session_id := player_for_peer(peer_id)
	if session_id == 0:
		return

	var id := _player_key(session_id)
	var reader := ask.reader()

	match ask.kind:
		PlaygroundEvents.Ask.READY:
			_admit(peer_id)
		PlaygroundEvents.Ask.SPAWN_PROP:
			_spawn_for(id, PlaygroundEvents.read_id(reader))
		PlaygroundEvents.Ask.GIVE_WEAPON:
			_give_weapon(session_id, id, PlaygroundEvents.read_id(reader))
		PlaygroundEvents.Ask.SELECT_TOOL:
			_select_tool(session_id, id, PlaygroundEvents.read_id(reader))
		PlaygroundEvents.Ask.UNDO:
			game.props.undo(id)
		PlaygroundEvents.Ask.CLEAR_MINE:
			game.props.clear_player(id)
		PlaygroundEvents.Ask.RESTART:
			game.spawn_player(id)
		PlaygroundEvents.Ask.CHECKPOINT:
			_checkpoint(id, PlaygroundEvents.read_index(reader))
		PlaygroundEvents.Ask.RTV:
			game.rock_the_vote(id)
		PlaygroundEvents.Ask.STYLE:
			if game.set_player_style(id, _style_id(PlaygroundEvents.read_index(reader))):
				_broadcast(PlaygroundEvents.Kind.JOIN, _join_body(session_id))


## Spawns in front of the player who asked, which is what the menu means by "spawn".
##
## The budget, the cooldown and the undo stack are the SPAWNER's, not this bridge's: a
## refusal comes back through `refused` and is forwarded to that player alone. A bridge
## that checked them itself would be a second copy of a rule, which is the bug this
## family has now shipped three times.
func _spawn_for(id: StringName, prop_id: StringName) -> void:
	var player: PlaygroundPlayer = game.players.get(id)
	if player == null or game.props.catalogue == null:
		return

	var def := game.props.catalogue.get_prop(prop_id)
	if def == null:
		_tell(peer_for_player(session_of(id)), PlaygroundEvents.Kind.NOTICE,
			PlaygroundEvents.write_notice(session_of(id), "No such prop: %s" % prop_id))
		return

	# Three metres in front of the eye, the same distance `pg_prop` uses. A player who
	# spawns a crate expects it where they are looking, not at their feet.
	var at := player.eye_position() + player.aim_direction() * 3.0
	game.props.spawn(def.id, id, at)


func _give_weapon(session_id: int, id: StringName, weapon_id: StringName) -> void:
	var player: PlaygroundPlayer = game.players.get(id)
	if player == null or game.weapon_def(weapon_id) == null:
		return

	_broadcast(PlaygroundEvents.Kind.WEAPON, PlaygroundEvents.write_weapon(session_id, weapon_id))


func _select_tool(session_id: int, id: StringName, tool_id: StringName) -> void:
	if not game.players.has(id):
		return
	if tool_id != &"phys" and tool_id != &"grav":
		return

	# Whatever the old tool was holding is let go. A player who swaps to the gravity gun
	# with a crate on the end of the physics gun would otherwise leave it hanging in the
	# air, owned by a tool they are no longer using and released by nothing.
	var player: PlaygroundPlayer = game.players.get(id)
	if player != null:
		player.phys_gun.release()
		player.grav_gun.drop()

	_tool_of[session_id] = tool_id
	_broadcast(PlaygroundEvents.Kind.WEAPON, PlaygroundEvents.write_weapon(session_id, tool_id))


func _checkpoint(id: StringName, action: int) -> void:
	var player: PlaygroundPlayer = game.players.get(id)
	var checkpoints := game.timers.checkpoints_for(id)
	if player == null or checkpoints == null:
		return

	var s := player.controller.state
	match action:
		0:
			checkpoints.save(
				s.position, s.velocity, s.yaw, s.pitch, s.is_grounded(), s.is_crouched()
			)
		1:
			var cp := checkpoints.load_current()
			if cp != null:
				player.teleport(cp.position, cp.yaw)
				player.controller.state.velocity = cp.velocity
				player.controller.state.pitch = cp.pitch
		2:
			checkpoints.clear()


# --- Client: applying ------------------------------------------------------

func _on_event(message: DotNetMessage) -> void:
	var event := message as PlaygroundEvent
	if event == null or game == null or net == null or net.is_server:
		return

	var reader := event.reader()

	match event.kind:
		PlaygroundEvents.Kind.HELLO:
			_apply_hello(reader)
		PlaygroundEvents.Kind.JOIN:
			_apply_join(reader)
		PlaygroundEvents.Kind.LEAVE:
			var session_id := PlaygroundEvents.read_player(reader)
			_release_entity(session_id)
			game.remove_player(_player_key(session_id))
			roster_changed.emit(session_id)
		PlaygroundEvents.Kind.MAP:
			var map_id := PlaygroundEvents.read_map(reader)
			if game.maps.current == null or game.maps.current.id != map_id:
				game.change_map(map_id)
		PlaygroundEvents.Kind.PROP:
			_apply_prop(reader)
		PlaygroundEvents.Kind.PROP_GONE:
			_apply_prop_gone(reader)
		PlaygroundEvents.Kind.WEAPON:
			pass
		PlaygroundEvents.Kind.TIMER:
			_apply_timer(reader)
		PlaygroundEvents.Kind.FINISH:
			var finish := PlaygroundEvents.read_finish(reader)
			if bool(finish["ok"]):
				var f: DotTimerNet.Finish = finish["finish"]
				finish_received.emit(
					int(finish["player_id"]),
					f.time(1.0 / float(maxi(game.tick_rate, 1))),
					f.rank
				)
		PlaygroundEvents.Kind.NOTICE:
			var notice := PlaygroundEvents.read_notice(reader)
			if bool(notice["ok"]):
				notice_received.emit(int(notice["player_id"]), str(notice["text"]))


func _apply_hello(reader: DotNetReader) -> void:
	var hello := PlaygroundEvents.read_hello(reader)
	if not bool(hello["ok"]):
		return

	local_player_id = int(hello["player_id"])

	# [b]The server's tick rate, before anything is derived from it.[/b] game-g2gfast
	# shipped with HELLO carrying this and nothing reading it: a browser client counted
	# at the 60 its export declared against a server on 128, so the correction rate was
	# 0.96 and every replicated time was out by 128/60. Produced correctly and consumed
	# by nothing, which is this family's most repeated bug — and invisible to a
	# one-process suite, because one process has one engine rate and both ends agree no
	# matter what the wire says.
	#
	# Before sync_from_server, because the clock converts its error and its lead
	# through tick_rate and would otherwise do that arithmetic at the old rate.
	_adopt_tick_rate(int(hello["tick_rate"]))

	var rtt := float(rtt_source.call()) if rtt_source.is_valid() else 0.0
	net.clock.sync_from_server(int(hello["server_tick"]), maxf(0.0, rtt))

	var map_id: StringName = hello["map_id"]
	if map_id != &"" and (game.maps.current == null or game.maps.current.id != map_id):
		game.change_map(map_id)

	hello_received.emit(local_player_id)


## Puts the whole client — game, timers, netcode clock and the ENGINE — on the server's
## tick rate.
##
## Four places hold this number and all four have to move together. `game.tick_rate` is
## the step the simulation and every reconstituted run time use; `net.config.tick_rate`
## is what [method DotNetInput.sanitise] and the interpolator's extrapolation budget
## read; `net.clock.tick_rate` is the live one, built from the config back at `setup()`
## and therefore NOT updated by writing the config alone; and
## `Engine.physics_ticks_per_second` is the one that decides whether it LOOKS right.
##
## That last one is not cosmetic. Measured in g2gfast at 60 against 128: the simulation
## stayed correct, because the clock is asked how many ticks a frame is worth — it just
## ran them in bursts of two and three, and the camera advanced 74 mm on six frames out
## of seven and 112 mm on the seventh. A 47% change in apparent speed, eight times a
## second. Interpolating between ticks does not fix it on its own and neither does this;
## the fraction a renderer interpolates at is a fraction through a PHYSICS frame, which
## is a fraction through a tick only while the two rates agree.
##
## A server never calls this: its rate is `sv_tickrate`, and adopting a peer's would be
## a client telling the server how fast to run.
func _adopt_tick_rate(rate: int) -> void:
	if net == null or net.is_server or game == null or rate <= 0 or rate == game.tick_rate:
		return

	var before := game.tick_rate

	if not game.set_tick_rate(rate):
		return

	net.config.tick_rate = game.tick_rate
	net.clock.tick_rate = game.tick_rate
	Engine.physics_ticks_per_second = game.tick_rate

	DotLog.info(CHANNEL, "adopted the server's tick rate", {
		"was": before, "now": game.tick_rate, "engine": Engine.physics_ticks_per_second,
	})


func _apply_join(reader: DotNetReader) -> void:
	var join := PlaygroundEvents.read_join(reader)
	if not bool(join["ok"]):
		return

	var session_id := int(join["player_id"])
	var id := _player_key(session_id)

	var player: PlaygroundPlayer = game.players.get(id)

	if player == null:
		player = game.add_player(id, str(join["name"]))
		if player == null:
			return
		# A client never samples: the client loop hands it commands.
		player.sampler = null
		player.samples_input = false

		var identity := _build_entity(player, 0)
		var registered := net.registry.register(
			identity, int(join["net_id"]), net.clock.tick, net.config
		)
		if not registered.ok:
			DotLog.warn(CHANNEL, "could not mirror a player", {"error": str(registered.error)})
			game.remove_player(id)
			return
	else:
		player.display_name = str(join["name"])

	game.set_player_style(id, _style_id(int(join["style_index"])))
	roster_changed.emit(session_id)


## Builds the client's copy of a prop and mirrors the net id it was given.
##
## [b]Adopted, never allocated.[/b] A receiving peer has to take the id it was sent —
## dot-2d's scatter had exactly this bug and could not be mirrored at all until it grew
## an `adopt()`. Registering with 0 here would give the prop a different id on every
## client and every snapshot for it would land on nothing.
func _apply_prop(reader: DotNetReader) -> void:
	var info := PlaygroundEvents.read_prop(reader)
	if not bool(info["ok"]):
		return

	var net_id := int(info["net_id"])

	if _prop_nets.has(net_id):
		return

	if game.props.catalogue == null:
		return

	var def := game.props.catalogue.get_prop(info["kind_id"])
	if def == null:
		# Not an error: a server may run a catalogue this build does not have, and the
		# honest answer is to draw nothing rather than to guess.
		DotLog.debug(CHANNEL, "a prop this build does not have", {"id": str(info["kind_id"])})
		return

	var scene: PackedScene = load(def.scene_path) if def.scene_path != "" else null
	if scene == null:
		DotLog.warn(CHANNEL, "a prop's scene would not load", {"path": def.scene_path})
		return

	var body := scene.instantiate() as Node3D
	if body == null:
		return

	var world := game.world if game.world != null else game
	world.add_child(body)
	body.global_position = info["position"]

	var as_prop := body as PlaygroundProp
	if as_prop != null:
		as_prop.configure(def)

	# An NPC's script is attached on the server and its behaviour runs there. A client
	# copy is a body being drawn where the server says it is, so the script is
	# deliberately NOT attached here: it would run a second, disagreeing AI.

	var behaviour := PlaygroundPropNet.new()
	behaviour.name = "Net"
	behaviour.prop = body
	body.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	body.add_child(identity)

	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)
	if not registered.ok:
		DotLog.warn(CHANNEL, "could not mirror a prop", {"error": str(registered.error)})
		body.queue_free()
		return

	_prop_nets[net_id] = behaviour
	props_changed.emit()


func _apply_prop_gone(reader: DotNetReader) -> void:
	var info := PlaygroundEvents.read_prop_gone(reader)
	if not bool(info["ok"]):
		return

	var net_id := int(info["net_id"])

	var behaviour: PlaygroundPropNet = _prop_nets.get(net_id)
	_prop_nets.erase(net_id)

	if behaviour == null:
		return

	if net != null:
		net.registry.unregister(net_id)

	if behaviour.prop != null and is_instance_valid(behaviour.prop):
		behaviour.prop.queue_free()

	props_changed.emit()


func _apply_timer(reader: DotNetReader) -> void:
	var info := PlaygroundEvents.read_timer(reader)
	if not bool(info["ok"]):
		return

	var player: PlaygroundPlayer = game.players.get(_player_key(int(info["player_id"])))
	if player == null or player.timer == null:
		return

	var state: DotTimerNet.RunState = info["state"]

	# Against the ESTIMATED server tick, not the local one: the local tick runs a lead
	# ahead so commands arrive in time, and a HUD counting from it would show every run
	# a flight time longer than the server will file it.
	player.timer.run = DotTimerNet.run_from_state(
		state,
		net.clock.server_tick(),
		1.0 / float(maxi(game.tick_rate, 1)),
		_style_id(state.style_index)
	)


# --- Sending ---------------------------------------------------------------

func _broadcast(kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server or body.is_empty():
		return
	net.send(PlaygroundEvent.of(kind, body), 0)


## To one peer, and never to peer 0.
##
## [b]Zero is the broadcast address.[/b] game-hungario gave a bot peer id 0, and every
## private per-player message sent to that bot went to every client on the server. A
## player with no peer — a bot, a test — simply is not told, which is correct: there is
## nobody there to tell.
func _tell(peer_id: int, kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server or peer_id <= 0 or body.is_empty():
		return
	net.send(PlaygroundEvent.of(kind, body), peer_id)


## The ordered style table, for a test that has to check how it was BUILT rather than
## what it contains — see the note in `attach`.
func style_table() -> Array[StringName]:
	return _style_ids.duplicate()


func describe() -> Dictionary:
	return {
		"server": net.is_server if net != null else false,
		"players": _behaviours.size(),
		"props": _prop_nets.size(),
		"ready_peers": _ready_peers.size(),
		"local": local_player_id,
		"tick": _tick,
		"link": link.describe() if link != null else {},
	}
