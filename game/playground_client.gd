class_name PlaygroundClient
extends Node

## Boots a playable playground: one local player, a camera, a HUD, a spawn menu and
## the keys.
##
## [b]Separate from [Playground] on purpose.[/b] The playground is the simulation and
## runs headless — that is what `examples/headless_playground.tscn` drives, and it has
## no camera, no HUD and no input. This is everything a person needs on top of it, and
## a dedicated server simply never loads it.
##
## [b]The bindings are the sandbox ones[/b], because that is the game this one is asking
## to be compared with and a sandbox with its own scheme is a sandbox nobody can pick
## up. Two mouse buttons that mean different things depending on what is in your
## hands, a menu you hold open, and a spawn that happens the moment you click a prop:
##
## [codeblock]
## Q (hold)     the spawn menu. Release to close; tap to pin it open
## Mouse 1      the tool's primary: grab and hold, or punt
## Mouse 2      the tool's secondary: freeze what is held, or pull and carry
## Wheel        how far out the physics gun holds a prop
## Shift+mouse  turn the prop the physics gun is holding
## E            spawn the prop the menu last armed, again
## R            unfreeze everything you have frozen
## Z            undo your last spawn
## 1 / 2 / 3    physics gun / gravity gun / cycle the weapons you have
## T            switch track: the sandbox, or the course in the corner
## Tab          cycle style      M   next map
## C V X B      practice checkpoints: save, go to, cycle, forget
## [/codeblock]

const CHANNEL := "playground.client"

## Ids the tools are addressed by, here and in [PlaygroundSpawnMenu].
const TOOL_PHYS := &"phys"
const TOOL_GRAV := &"grav"

## How long Q may be held before releasing it closes the menu.
##
## [b]A tap pins, a hold does not.[/b] Both are wanted and they are the same key in
## in those sandboxes: holding it is how you glance at the menu without losing your place,
## and tapping it is how you leave it up while you build. A quarter of a second is
## comfortably longer than a click and comfortably shorter than a look.
const MENU_TAP_SECONDS := 0.25

## Where a spawned prop appears, in metres in front of the eye.
const SPAWN_REACH := 3.0

## The map to open on if the configuration names none. A client has to be somewhere.
const FALLBACK_MAP := &"pg_lobby"

@export var player_id: StringName = &"local"
@export var display_name: String = "Player"

## Configuration handed to the [Playground] this builds, or null for the defaults.
##
## [b]Forwarded rather than set afterwards.[/b] `Playground._ready` layers the config
## and loads `initial_map` from it, and both happen inside `add_child` — so anything
## assigned after that is assigned to a game that has already booted on the old
## values. It is also the only way a test can boot a real client without it writing
## records into the user's data directory.
@export var config: PlaygroundConfig = null

## A JSON file to layer over [member config]. Passed straight through.
@export var config_file: String = ""

## The dedicated server's client link, when this client is on a server.
##
## [b]Set before this node enters the tree, and it is what decides which client this
## is.[/b] With it, the playground is a mirror: it is not authoritative, it adds no
## player of its own, and every action goes to the server as intent. Without it, this
## is the local sandbox it has always been, which is what `headless_playground` drives.
@export var link: Node = null

var playground: Playground = null
var net: DotNetManager = null
var bridge: PlaygroundNetBridge = null
var player: PlaygroundPlayer = null
var hud: PlaygroundHud = null

## The client half of chat: the channels, the history, the unread counts and the gap
## detection. It decides nothing — every rule is the server's.
var chat: DotChatClient = null

## The client half of voice. Every call on it is guarded, because "there is no microphone"
## is a legitimate machine rather than an error.
var voice: PlaygroundVoice = null

## What this client is on: health, armour, and the match clock. Drawn, never decided.
var health: int = 100
var armour: int = 0
var match_label: String = ""
var match_seconds: float = 0.0
var camera: Camera3D = null

var screens: DotScreenStack = null
var menu: PlaygroundSpawnMenu = null

## The server list, on the same stack as the spawn menu.
var browser: PlaygroundBrowser = null

## Somebody picked a server in the browser. What a launcher connects to.
signal server_chosen(address: String)

## Which prop the spawn key places. Armed by the menu.
var selected_prop: StringName = &"crate"

## Which tool is in hand: [constant TOOL_PHYS], [constant TOOL_GRAV], or a weapon id.
var tool: StringName = TOOL_PHYS

## The weapon in hand, when [member tool] is neither of the two built-in guns.
##
## [b]Instantiated per equip, not held as a pool.[/b] A weapon is a script with state —
## a charge, a cooldown, what it is holding — and a shared instance would carry one
## player's cooldown into another's hands the moment this becomes a server.
var weapon: PlaygroundWeapon = null

## Where the style key is in the list.
var _style_index: int = 0

## Whether the physics gun's button is down.
var _holding: bool = false

## Whether the gravity gun is pulling.
var _pulling: bool = false

## Whether Shift is down, which turns mouse motion into prop rotation.
var _rotating: bool = false

## When Q went down, so a release can tell a tap from a hold.
var _menu_down_at: float = 0.0

## Whether the menu is up because it was tapped rather than because Q is still down.
var _menu_pinned: bool = false

## Input sampling, on a networked client only. A local player samples through their own
## [DotFpsSampler]; a networked one is handed a command by this loop instead, because
## the command has to be stamped for a tick and kept for reconciliation.
var _sampler: DotFpsSampler = null

## The tool triggers, as command buttons. Held rather than edge-triggered: the server
## decides what a press and a hold each mean (see PlaygroundNetBridge._drive_tools), and
## a client that sent only the edges would drop one to packet loss and leave a player
## holding a crate they have let go of.
var _net_buttons: int = 0


func _ready() -> void:
	playground = Playground.new()
	playground.name = "Playground"

	# [b]A networked client is not authoritative, and this is where that is decided.[/b]
	# Set afterwards it would be assigned to a game that had already booted:
	# `Playground._ready` layers the config and loads the first map inside `add_child`,
	# so a game told at that point that it is a mirror has already spent a map load
	# believing it owned the world.
	if config == null:
		config = PlaygroundConfig.new()
	if link != null:
		config.authoritative = false

	playground.config = config
	playground.config_file = config_file
	add_child(playground)

	# The playground loads its own first map and this waits for it, rather than
	# loading one here.
	#
	# [b]Two reasons, and the second is the one that bites.[/b] `initial_map` is
	# layered configuration, so a client that picked its own would ignore `--pg-map`
	# and every server-side default with it. And loading it twice builds the whole
	# map twice — the second change tears the first down, which frees the geometry
	# anything already placed on it is standing on.
	#
	# By this line `Playground._ready` has run as far as its own `await`, so the
	# config is layered and final while the map is not up yet: waiting on the signal
	# cannot miss it.
	#
	# `booted` is checked BEFORE the await, and that is not defensive. `change_map`
	# can complete without ever suspending — a built-in map is a scene already in the
	# build — in which case the playground finishes booting inside `add_child` above
	# and `ready_for_players` has already been emitted by the time this line runs.
	# Awaiting it then waits for ever, and the symptom is a black screen with no
	# error at all: no camera, no HUD, no player. It is the family's own fan-out trap
	# in its smallest form, and this file had it for exactly one screenshot.
	if not playground.booted:
		await playground.ready_for_players

	if playground.maps.current == null:
		var loaded: DotResult = await playground.change_map(FALLBACK_MAP)

		if not loaded.ok:
			DotLog.error(CHANNEL, "could not load the first map", {
				"why": loaded.error.message
			})
			return

	if link != null:
		# The server creates the player and JOIN is what tells this client about it, so
		# there is nobody to adopt yet. Everything below that needs one checks.
		var netcode := _build_netcode()

		if not netcode.ok:
			DotLog.error(CHANNEL, "the netcode would not start", {
				"why": netcode.error.message
			})
			return

		# [b]The view is NOT built here on a networked client, and that is the whole
		# ordering.[/b] The camera is parented to the player, and on a server the player
		# does not exist yet: HELLO names you and JOIN creates you, both of them packets
		# that have not arrived. Building it now calls `add_child` on null, the camera is
		# never in the tree, and `_process` then writes a global transform to a node that
		# has no parent — once a frame, for ever.
		#
		# On desktop that is a red line per frame and a black screen. In a WASM build it
		# is a hard `RuntimeError: null function` with no GDScript trace at all, which is
		# what this cost to find. [method _adopt] builds it the moment JOIN lands.
	else:

		player = playground.add_player(player_id, display_name)
		player.samples_input = true

		# The sampler is built in the player's _ready, which has already run — so it is
		# built here instead. Setting the flag alone would leave a player who is
		# supposed to be driving and never samples anything, which reads as the input
		# being broken.
		player.sampler = DotFpsSampler.new(player.controller.tunables)
		DotFpsSampler.register_default_actions(player.sampler)

		_build_view()

	hud = PlaygroundHud.new()
	hud.name = "Hud"
	add_child(hud)
	if link == null:
		hud.bind(playground, player_id)
	_sync_hud()

	# After the HUD, because for a CanvasItem tree order is draw order and a menu
	# that renders under the speedometer is one whose bottom row cannot be clicked.
	_build_client_services()
	_build_screens()

	set_process(true)


## Brings up the netcode and points it at the server's link.
##
## Mirrors [G2GClient]'s, because that is the one in this family proven against a real
## dedicated server over a real socket.
func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	net.config_file = ""

	var net_config := DotNetConfig.new()
	net_config.tick_rate = playground.tick_rate
	net_config.snapshot_rate = 32
	net_config.enable_prediction = true
	net_config.enable_lag_compensation = false
	net_config.max_entities_per_snapshot = 64
	net_config.world_extent = 512.0
	net.config = net_config
	add_child(net)

	var ready_result := net.setup()

	if not ready_result.ok:
		return ready_result

	bridge = PlaygroundNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(playground, net, link)

	if not attached.ok:
		return attached

	net.messages.seal()

	bridge.hello_received.connect(_on_hello)
	bridge.roster_changed.connect(_on_roster_changed)
	bridge.weapon_changed.connect(_on_weapon_changed)
	# [b]dot-server's own `chat_received` is deliberately NOT connected.[/b] The server
	# cancels that path and routes every line through [DotChatRouter] onto this game's own
	# wire instead; connecting both would draw a line twice on a server running the old
	# path and once on one running the new.
	bridge.chat_received.connect(_on_chat_wire)
	bridge.combat_received.connect(_on_combat)
	bridge.match_received.connect(_on_match)
	bridge.progress_received.connect(_on_progress)
	bridge.notice_received.connect(func(_pid: int, text: String) -> void:
		if hud != null:
			hud.notice(text)
	)
	bridge.finish_received.connect(func(pid: int, time: float, rank: int) -> void:
		if hud != null and pid == bridge.local_player_id:
			hud.notice("%s%s" % [
				DotTimerRun.format_time(time),
				" — rank %d" % rank if rank > 0 else ""
			])
	)

	# Stock tunables until there is a player to ask. The sampler turns the view at the
	# rate the player's style says, and at this point the server has not told us who we
	# are — _adopt swaps them in the moment JOIN does.
	_sampler = DotFpsSampler.new(DotFpsTunables.new())
	DotFpsSampler.register_default_actions(_sampler)

	# [b]Nothing may be sent to a peer before it says it can receive.[/b] dot-server's
	# signon finishes and THEN the client builds its scene, so everything sent in
	# between lands on a node that does not exist and is lost — one "Node not found"
	# per call, and a client that never joins.
	if link.has_method("is_playing") and bool(link.call("is_playing")):
		bridge.ask_ready()
	elif link.has_signal("spawned"):
		link.connect("spawned", bridge.ask_ready, CONNECT_ONE_SHOT)

	# Nothing in dot-net writes an RTT sample: it never touches a transport. A client
	# that feeds none has a clock that believes the link is instant, and every command
	# it stamps arrives after its tick has already been simulated.
	if link.has_method("ping_ms"):
		bridge.rtt_source = func() -> float:
			return float(maxi(0, int(link.call("ping_ms"))))

	return net.start()


func _on_hello(id: int) -> void:
	player_id = StringName("u%d" % id)

	if hud != null:
		hud.bind(playground, player_id)

	_adopt()


## [b]HELLO names you and JOIN creates you, in that order.[/b] Looking the player up on
## HELLO alone gets null and never tries again — which is how g2gfast shipped a browser
## client that connected, drew, showed a live HUD and walked around with a dead mouse
## and a dead keyboard, because everything below the `player == null` guard in its input
## handler never ran.
func _on_roster_changed(_id: int) -> void:
	_adopt()


func _adopt() -> void:
	if player != null or bridge == null or bridge.local_player_id == 0:
		return

	var mine: PlaygroundPlayer = playground.players.get(player_id)

	if mine == null:
		return

	player = mine

	# Now, and not before: this is the first moment there is a node to parent a camera
	# to. See the note in _ready.
	_build_view()

	if _sampler != null:
		_sampler.tunables = player.controller.tunables

	_sync_hud()


## The client's tick, driven by the netcode clock rather than by the engine's frame.
##
## The clock is asked how many ticks this frame is worth, because the engine's rate and
## the server's need not agree — though the bridge adopts the server's on HELLO, which
## is the only reason the two ever do.
func _net_physics(delta: float) -> void:
	if net == null or bridge == null or not net.is_running():
		return

	var ticks := net.clock.advance(delta)

	var sampler := active_sampler()

	if sampler == null:
		return

	for _i in range(ticks):
		if net.clock.is_synced():
			var command := sampler.sample(delta)
			command.buttons |= _net_buttons
			bridge.client_tick(net.clock.input_tick(), command)


func _build_view() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 100.0
	camera.current = true
	player.add_child(camera)

	var view := DotFpsView.new()
	view.name = "View"
	player.add_child(view)

	player.view = view


## Chat and voice, once the bridge exists.
func _build_client_services() -> void:
	chat = DotChatClient.new()
	chat.name = "Chat"
	# The same channel definitions the server routes with — shared rather than sent, for
	# the reason every constant in this family is shared: a client holding a different set
	# would show a line on a channel it has no colour or prefix for.
	chat.channels = PlaygroundServices.chat_channels()
	chat.rules = PlaygroundServices.chat_rules()
	chat.history_limit = 400
	# Two clients in one process would otherwise collide on the registry name and one of
	# them would be invisible to whatever asked.
	chat.register_as = &""
	add_child(chat)
	chat.start()
	chat.message_received.connect(_on_chat_message)

	if bridge == null:
		return

	voice = PlaygroundVoice.new()
	voice.name = "Voice"
	voice.send_fn = func(bytes: PackedByteArray) -> void:
		if bridge != null and bridge.link != null:
			# Passed as 1 rather than 0: the peer is ignored on a client, and in this
			# family zero has meant "everybody" often enough to be worth never writing by
			# accident.
			bridge.link.send_voice(1, bytes)
	add_child(voice)

	voice.setup(not DotPlatform.is_headless())
	bridge.voice_arrived.connect(voice.receive)


## A routed line off this game's own wire, filed by [DotChatClient] — which drops a
## duplicate and reports a gap.
func _on_chat_wire(wire: Dictionary) -> void:
	if chat != null:
		chat.receive(wire)


## A line [DotChatClient] accepted: in sequence, not a duplicate, on a known channel.
##
## [b]The channel decides how it is drawn, and the channel is a document.[/b] Its prefix
## and colour come off the [DotChatChannel] both ends share, so adding a channel is adding
## a definition rather than a branch somebody has to remember to extend.
func _on_chat_message(message: DotChatMessage, channel_id: StringName) -> void:
	if hud == null:
		return

	var chan := chat.channel(channel_id)
	var prefix := "%s " % chan.prefix if chan != null and chan.prefix != "" else ""

	if message.is_from_server() or message.sender_name == "":
		hud.notice("%s%s" % [prefix, message.text])
		return

	hud.notice("%s%s: %s" % [prefix, message.sender_name, message.text])


## Somebody's health changed, or they died. Drawn, never decided.
func _on_combat(state: Dictionary) -> void:
	if int(state["player_id"]) != bridge.local_player_id:
		return

	health = int(state["health"])
	armour = int(state["armour"])

	if bool(state["died"]) and hud != null:
		hud.notice("You were killed.")


## The match clock.
##
## [b]Taken from the wire rather than from a local [DotMatch].[/b] Nothing ticks a
## mirroring client's, so `seconds_remaining()` is derived from a tick that is still zero —
## not a stale value, a value nothing had ever written. game-arena shipped a client that
## showed `IDLE` for ever while the server was playing a round.
func _on_match(state: Dictionary) -> void:
	match_label = str(state["label"])
	match_seconds = float(state["seconds_left"])


## Somebody picked a server in the browser.
##
## [b]Connecting is the host application's, not this scene's.[/b] A client scene that
## reached into its own link and reconnected would be a scene that decides where a person
## plays — and the same scene is instantiated by a shell that already knows. So this
## announces, and a launcher acts; offline it says so rather than pretending.
func _on_server_chosen(address: String) -> void:
	server_chosen.emit(address)

	if hud != null:
		hud.notice("Chosen: %s" % address)


func _on_progress(state: Dictionary) -> void:
	if hud == null:
		return

	var mine := int(state["player_id"]) == bridge.local_player_id

	hud.notice("%s %s (%d)" % [
		"You earned" if mine else "Somebody earned",
		str(state["title"]),
		int(state["value"]),
	])


func _build_screens() -> void:
	screens = DotScreenStack.new()
	screens.name = "Screens"
	# Captured whenever nothing is open, which is what puts the mouse back on the
	# view the instant the menu closes. Doing it by hand in the close path means
	# every future screen has to remember to.
	screens.idle_mouse_mode = DotScreen.Mouse.CAPTURED
	add_child(screens)

	var ready := screens.setup()

	if not ready.ok:
		DotLog.error(CHANNEL, "the screen stack could not be set up", {
			"why": ready.error.message
		})
		return

	menu = PlaygroundSpawnMenu.new()
	menu.name = "SpawnMenu"
	menu.catalogue = playground.props.catalogue
	menu.weapons = playground.weapons
	menu.selected = selected_prop
	menu.tool = tool
	menu.prop_chosen.connect(_on_prop_chosen)
	menu.weapon_chosen.connect(_on_weapon_chosen)
	menu.tool_chosen.connect(_on_tool_chosen)
	menu.action_requested.connect(_on_menu_action)

	var registered := screens.register(menu)
	DotLog.result(CHANNEL, "registering the spawn menu", registered)

	# The server list. [b]Registered even offline[/b], because a person running this
	# locally is exactly the person who wants to find somewhere to play — and a screen that
	# only existed on a connected client would be one nobody could reach from the menu.
	browser = PlaygroundBrowser.new()
	browser.name = "Servers"
	browser.joined.connect(_on_server_chosen)
	DotLog.result(
		CHANNEL, "registering the server browser", screens.register(browser)
	)


func _process(_delta: float) -> void:
	# [b]Once a frame, not once a tick.[/b] The interpolator blends two snapshots
	# perfectly and is then useless if it is only ever asked at a tick boundary: remote
	# players and every replicated prop would step at the snapshot rate however smoothly
	# they were interpolated. dot-net shipped exactly that.
	if net != null and net.is_running():
		net.interpolate_frame()

	# `is_inside_tree`, not just null. A camera whose parent was freed — a player who
	# left, a map change — is a live object that is not in the scene, and writing a
	# global transform to one is an engine error every frame rather than a crash that
	# points anywhere.
	if player == null or camera == null or not camera.is_inside_tree():
		return

	if not player.is_inside_tree():
		return

	# The camera follows the SIMULATED eye position rather than being parented to
	# something the movement drives. Parenting works and hides a real difference: the
	# simulation runs at a fixed tick and the camera is drawn every frame, so a
	# parented camera steps once per tick and judders between them.
	camera.global_position = player.eye_position()
	camera.global_rotation = Vector3(
		deg_to_rad(player.controller.state.pitch),
		deg_to_rad(player.controller.state.yaw),
		0.0
	)


## Tells the HUD what is in the player's hands.
##
## Pushed rather than polled: the HUD is bound to the simulation and a spectator or a
## replay has no client holding anything, so it cannot go and look.
func _sync_hud() -> void:
	if hud != null:
		hud.set_tool(_tool_name(), selected_prop)


## Whether a menu is up, in which case the mouse belongs to it.
func _menu_is_open() -> bool:
	return screens != null and screens.any_open()


# --- Input -----------------------------------------------------------------

## The sampler the next simulated tick will actually read.
##
## [b]There are two of them and which one drives is a property of the deployment.[/b] A
## networked client builds its command from `_sampler` in [method _net_physics], because
## a command has to be stamped for a tick and kept for reconciliation. A local player
## samples through its own `player.sampler` in `PlaygroundPlayer.simulate`, because there
## is no tick to stamp it for.
##
## [b]This exists so the mouse and the tick cannot disagree about which one that is.[/b]
## They did: `_on_mouse_motion` fed `player.sampler` unconditionally, and a networked
## player is not built with a sampler of its own, so every mouse event was dropped by a
## null guard while `_sampler` — the one being sampled — never saw one. Nothing errored
## and nothing else broke, because `DotFpsSampler.sample` polls the `InputMap` rather
## than reading events: the player walked, shot and spawned props with a dead mouse.
## `game-g2gfast` had the right form already; this file was the outlier.
## Set by a headless suite to answer [method mouse_drives_view] without a display
## server. Left null in play, where the real mouse mode is the only honest answer.
var mouse_capture_override: Variant = null


## Whether the pointer is currently a look input rather than a pointer.
##
## [b]A released cursor is not a look input, and [method _menu_is_open] does not answer
## that.[/b] KEY_ESCAPE toggles the capture with no screen open, so after one press the
## cursor is free, the menu check is false, and every motion of a pointer the player is
## using as a pointer was still spent turning the view or twisting the prop in the gun.
## `game-arena` has always guarded on the mode here; this file and `game-g2gfast` did
## not, and it is the second half of the same "the mouse and the tick disagree" bug that
## [method active_sampler] fixed the first half of.
##
## [b]A method with an override rather than a read of `Input.mouse_mode` at the call
## site, because that read cannot be tested here.[/b] The dummy display server pins the
## mode to `MOUSE_MODE_VISIBLE` and drops every write to it without erroring, so a suite
## can neither put a client into the state a player plays in nor out of it — which is
## why arena's identical guard has never been exercised by anything, and why this one
## would not have been either.
func mouse_drives_view() -> bool:
	if mouse_capture_override != null:
		return bool(mouse_capture_override)

	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func active_sampler() -> DotFpsSampler:
	if link != null:
		return _sampler

	return player.sampler if player != null else null


func _unhandled_input(event: InputEvent) -> void:
	# [b]Voice first, and before the player check.[/b] Somebody with no player yet — mid
	# signon, or spectating — should still be able to talk, and a release swallowed by an
	# early return is a microphone left open. `handle_event` sees both edges, which every
	# branch below this deliberately does not.
	if voice != null and voice.handle_event(event):
		get_viewport().set_input_as_handled()
		return

	if player == null:
		return

	if event is InputEventMouseMotion:
		_on_mouse_motion(event as InputEventMouseMotion)
		return

	# Everything below moves the world. A menu is up, the mouse is a cursor, and a
	# click on a prop button must not also punt whatever is behind it.
	#
	# Checked here rather than relying on the screen consuming the event: the stack
	# blocks what reaches the GUI, and a click that lands on the menu's own
	# background is unhandled by design and would arrive here.
	if _menu_is_open() and not _is_menu_key(event):
		return

	if event is InputEventMouseButton:
		_on_mouse_button(event as InputEventMouseButton)
		return

	if not (event is InputEventKey):
		return

	var key := event as InputEventKey

	if key.physical_keycode == KEY_SHIFT:
		# Held, not toggled, and read on both edges: a rotate that stayed on after
		# the key came up would turn the prop every time the player looked around.
		_rotating = key.pressed
		return

	if key.physical_keycode == KEY_Q:
		_on_menu_key(key)
		return

	if not key.is_pressed() or key.is_echo():
		return

	match key.physical_keycode:
		KEY_E:
			_spawn()
		KEY_Z:
			if bridge != null:
				bridge.ask_undo()
			else:
				playground.props.undo(player_id)
		KEY_F:
			_use_vehicle()
		KEY_R:
			_unfreeze_all()
		KEY_1:
			_set_tool(TOOL_PHYS)
		KEY_2:
			_set_tool(TOOL_GRAV)
		KEY_3:
			_cycle_weapon()
		KEY_T:
			_cycle_track()
		KEY_TAB:
			_cycle_style()
		KEY_M:
			_next_map()
		KEY_C:
			_save_checkpoint()
		KEY_V:
			_load_checkpoint()
		KEY_X:
			_cycle_checkpoint()
		KEY_B:
			_clear_checkpoints()
		KEY_ESCAPE:
			# Only when no screen is up. The stack's own back handling pops the menu,
			# and a second handler here would pop it and release the mouse in one
			# press.
			if not _menu_is_open():
				Input.mouse_mode = (
					Input.MOUSE_MODE_VISIBLE
					if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
					else Input.MOUSE_MODE_CAPTURED
				)


## Q is the one key that still means something while the menu is open.
func _is_menu_key(event: InputEvent) -> bool:
	return event is InputEventKey and (
		(event as InputEventKey).physical_keycode == KEY_Q
	)


func _on_mouse_motion(event: InputEventMouseMotion) -> void:
	if _menu_is_open():
		return

	if not mouse_drives_view():
		return

	if _rotating and _holding:
		# Turning the prop instead of the view, which is what makes the physics gun
		# a building tool. `DotPhysGun` stores the orientation relative to the view,
		# so this composes with looking around rather than fighting it.
		player.phys_gun.rotate_held(-event.relative.x * 0.4, -event.relative.y * 0.4)
		return

	var sampler := active_sampler()

	if sampler == null:
		return

	# Handed to the sampler, which accumulates it and spends it on the next
	# simulated tick. Applying it to the view here would make the look a function of
	# how many mouse events happened to land in a frame.
	sampler.handle_event(event)


func _on_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_LEFT:
			if event.pressed:
				_primary_down()
			else:
				_primary_up()
		MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_secondary_down()
			else:
				_secondary_up()
		MOUSE_BUTTON_WHEEL_UP:
			if _holding:
				player.phys_gun.push(1.0, 0.1)
		MOUSE_BUTTON_WHEEL_DOWN:
			if _holding:
				player.phys_gun.push(-1.0, 0.1)


## Q down opens the menu; Q up closes it unless the press was a tap.
##
## [b]One key, two behaviours, and they are not a toggle.[/b] Holding shows the menu
## for as long as you hold it — a glance, with your place kept. Tapping leaves it up,
## which is what you want while building; tapping again puts it away. A plain toggle
## loses the glance, and a plain hold means you cannot let go of the mouse.
func _on_menu_key(key: InputEventKey) -> void:
	if screens == null or menu == null or key.is_echo():
		return

	var id := menu.screen_id()

	if key.pressed:
		_menu_down_at = _now()

		if not screens.is_open(id):
			# Whatever the tools were doing, they stop: the mouse is about to become
			# a cursor, and a physics gun still holding a crate would drag it round
			# the world following a pointer the player is aiming at buttons with.
			_primary_up()
			_secondary_up()
			_rotating = false

			menu.selected = selected_prop
			menu.tool = tool
			screens.push(id)
			_menu_pinned = false

		return

	if _now() - _menu_down_at >= MENU_TAP_SECONDS:
		screens.pop(id)
		_menu_pinned = false
		return

	if _menu_pinned:
		screens.pop(id)
		_menu_pinned = false
		return

	_menu_pinned = true


## Wall-clock seconds. Presentation only — nothing here is timed, compared or ranked,
## which is why this is not the simulated clock the timer counts in.
func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


# --- The tools -------------------------------------------------------------

func _space() -> PhysicsDirectSpaceState3D:
	return player.get_world_3d().direct_space_state


func _view_basis() -> Basis:
	return Basis(Quaternion.from_euler(Vector3(
		0.0, deg_to_rad(player.controller.state.yaw), 0.0
	)))


func _set_tool(id: StringName) -> void:
	if tool == id:
		return

	# Everything is let go of on the way out. A gravity gun that kept carrying a
	# crate after the player switched to the physics gun would have two tools
	# holding one prop, which `DotPropInstance.held_by` refuses — so the physics gun
	# would simply do nothing and there would be nothing on screen to say why.
	_primary_up()
	_secondary_up()

	if weapon != null:
		weapon.holster()
		weapon = null

	tool = id

	# The server holds its own copy, because the server is what actuates a tool against
	# somebody else's prop. A client saying which tool it holds is a request, not a fact.
	#
	# [b]A weapon is asked for too, and for a second reason.[/b] `pg_shop` prices every
	# weapon, and `_give_weapon` is the only thing that charges for one — so a client
	# that armed itself and told nobody got every weapon in the catalogue free, and
	# nobody else was told what it was holding either. The request goes for a tool AND
	# for a weapon; only the id differs.
	if bridge != null:
		if id == TOOL_PHYS or id == TOOL_GRAV:
			bridge.ask_tool(id)
		else:
			bridge.ask_weapon(id)

	if id != TOOL_PHYS and id != TOOL_GRAV:
		# A weapon. Built from its definition, which loads its script by path — see
		# PlaygroundWeapons for why a path and not a class.
		var def := playground.weapon_def(id)
		weapon = PlaygroundWeapons.make(def)

		if weapon == null:
			# The reason is already in the log, in more detail than a notice can
			# carry. Falling back to the physics gun rather than leaving the player
			# holding nothing whose buttons silently do nothing.
			tool = TOOL_PHYS

			if hud != null:
				hud.notice("That weapon could not be loaded.")
		else:
			weapon.equip(playground, def)
			weapon.wielder = player_id
			weapon.armed = selected_prop

	if menu != null:
		menu.tool = tool

	_sync_hud()

	if hud != null:
		hud.notice(_tool_name().capitalize())


## What is in hand, in words. A weapon's own name, or one of the two guns'.
func _tool_name() -> String:
	if weapon != null and weapon.def != null:
		return weapon.def.name_or_id()

	return PlaygroundSpawnMenu.name_of_tool(tool)


## Steps through the weapons this server offers, and back to the physics gun.
##
## [b]Round-trips through the physics gun rather than cycling weapons only.[/b] The
## physics gun is the tool a sandbox is actually played with; a cycle that could not
## reach it would leave a player who pressed 3 twice holding a remover with no
## obvious way back.
func _cycle_weapon() -> void:
	if playground.weapons.is_empty():
		if hud != null:
			hud.notice("This server has no weapons.")
		return

	var index := -1

	for i in range(playground.weapons.size()):
		if playground.weapons[i].id == tool:
			index = i
			break

	if index + 1 >= playground.weapons.size():
		_set_tool(TOOL_PHYS)
		return

	_set_tool(playground.weapons[index + 1].id)


func _primary_down() -> void:
	if bridge != null:
		_net_buttons |= DotFpsCommand.BUTTON_USER_0
		return

	if weapon != null:
		_report(weapon.primary(
			_space(), player.eye_position(), player.aim_direction()
		))
		return

	match tool:
		TOOL_PHYS:
			_grab()
		TOOL_GRAV:
			_punt()


func _primary_up() -> void:
	if bridge != null:
		_net_buttons &= ~DotFpsCommand.BUTTON_USER_0
		return

	if tool == TOOL_PHYS and _holding:
		player.phys_gun.release()
		_holding = false


func _secondary_down() -> void:
	if bridge != null:
		_net_buttons |= DotFpsCommand.BUTTON_USER_1
		return

	if weapon != null:
		_report(weapon.secondary(
			_space(), player.eye_position(), player.aim_direction()
		))
		return

	match tool:
		TOOL_PHYS:
			# Freezing is the physics gun's right-click everywhere it exists, and it lets
			# go of what it froze — which is what makes building one-handed.
			if _holding:
				var frozen := player.phys_gun.freeze_held()
				_holding = false

				if not frozen.ok and hud != null:
					hud.notice(frozen.error.message)
		TOOL_GRAV:
			var pulled := player.grav_gun.pull(
				_space(), player.eye_position(), player.aim_direction(),
				playground.may_touch_others()
			)
			_pulling = pulled.ok

			if not pulled.ok and hud != null:
				hud.notice(pulled.error.message)


func _secondary_up() -> void:
	if bridge != null:
		_net_buttons &= ~DotFpsCommand.BUTTON_USER_1
		return

	if tool == TOOL_GRAV and _pulling:
		player.grav_gun.drop()
		_pulling = false


## Puts a refusal on the HUD, and says nothing about a success.
##
## An empty message is a refusal the player has already been told about through
## another route — `DotPropSpawner.refused`, which the HUD is listening to — and
## printing it again would put the same line on screen twice.
func _report(result: DotResult) -> void:
	if result.ok or hud == null or result.error.message == "":
		return

	hud.notice(result.error.message)


func _grab() -> void:
	var grabbed := player.phys_gun.grab(
		_space(), player.eye_position(), player.aim_direction(), _view_basis(),
		playground.may_touch_others()
	)

	_holding = grabbed.ok

	if not grabbed.ok and hud != null:
		hud.notice(grabbed.error.message)


func _punt() -> void:
	player.grav_gun.punt(
		_space(), player.eye_position(), player.aim_direction(),
		playground.may_touch_others()
	)
	_pulling = false


func _physics_process(delta: float) -> void:
	# On a server the tools are actuated by the SERVER from the buttons this client
	# sends — see PlaygroundNetBridge._drive_tools. Running them here as well would be a
	# second, disagreeing simulation of somebody else's rigid body, on a copy that is
	# frozen and drawn from snapshots and could not move anyway.
	if link != null:
		_net_physics(delta)
		return

	if player == null:
		return

	# Held from the physics loop, because the spring writes a velocity the solver
	# consumes on this step. Doing it in _process writes a velocity that a variable
	# number of physics steps then apply, and the prop jitters at exactly the rate
	# the frame time varies.
	if _holding:
		player.phys_gun.hold(
			player.eye_position(), player.aim_direction(), _view_basis(), delta
		)

	if _pulling:
		player.grav_gun.carry(
			player.eye_position(), player.aim_direction(), delta
		)

	# A weapon gets a tick whether or not a button is down: a charge, a cooldown and
	# a beam are all things that have to run between clicks, and a weapon that were
	# only ticked while firing could not have any of them.
	if weapon != null:
		weapon.tick(
			_space(), player.eye_position(), player.aim_direction(), delta
		)


# --- Props -----------------------------------------------------------------

func _spawn() -> void:
	if selected_prop == &"":
		if hud != null:
			hud.notice("Nothing armed. Hold Q and pick something.")
		return

	# On a server the client asks and the server decides. The budget, the cooldown and
	# the undo stack are the spawner's, and a second copy of those rules here is the bug
	# this family has now shipped three times.
	if bridge != null:
		bridge.ask_spawn_prop(selected_prop)
		return

	var at := player.eye_position() + player.aim_direction() * SPAWN_REACH
	playground.props.spawn(selected_prop, player_id, at)


func _on_prop_chosen(prop_id: StringName) -> void:
	selected_prop = prop_id

	# The weapon follows what the menu armed, which is what makes the launcher fire
	# a beach ball or a boulder without a second list of ammunition.
	if weapon != null:
		weapon.armed = prop_id

	_sync_hud()
	_spawn()


## What the server says we are holding, which is the only answer that counts.
##
## [b]A refused purchase has to take the weapon back.[/b] `_set_tool` arms locally so a
## weapon switch is not a round trip, which is prediction — and prediction that is never
## corrected is just a client disagreeing with the server. `pg_shop` refuses a weapon a
## player cannot afford, and without this the player kept it: the notice said no and the
## thing was in their hands.
##
## Somebody else's weapon is not applied here. This client draws no first-person weapon
## for a remote player, so there is nothing to apply it to yet — but the id now arrives,
## which is what a third-person model would need.
func _on_weapon_changed(pid: int, weapon_id: StringName) -> void:
	if bridge == null or pid != bridge.local_player_id:
		return
	if weapon_id == tool:
		return

	# Not _set_tool: that would ask the server again, and the server is what just spoke.
	_apply_server_tool(weapon_id)


## Adopt a tool without asking for it. The half of [method _set_tool] that is local.
func _apply_server_tool(id: StringName) -> void:
	_primary_up()
	_secondary_up()

	if weapon != null:
		weapon.holster()
		weapon = null

	tool = id

	if id != TOOL_PHYS and id != TOOL_GRAV:
		var def := playground.weapon_def(id)
		weapon = PlaygroundWeapons.make(def)

		if weapon == null:
			tool = TOOL_PHYS
		else:
			weapon.equip(playground, def)
			weapon.wielder = player_id
			weapon.armed = selected_prop

	_sync_hud()


func _on_weapon_chosen(weapon_id: StringName) -> void:
	_set_tool(weapon_id)


func _on_tool_chosen(tool_id: StringName) -> void:
	_set_tool(tool_id)


func _on_menu_action(action: StringName) -> void:
	match action:
		&"undo":
			if bridge != null:
				bridge.ask_undo()
			elif not playground.props.undo(player_id) and hud != null:
				hud.notice("Nothing to undo.")
		&"unfreeze":
			_unfreeze_all()
		&"clear":
			if bridge != null:
				bridge.ask_clear_mine()
				return

			var removed := playground.props.clear_player(
				player_id, DotPropSpawner.REASON_PLAYER
			)

			if hud != null:
				hud.notice("Removed %d prop%s." % [
					removed, "" if removed == 1 else "s"
				])


## Thaws every prop this player has frozen.
##
## [b]Never refused, deliberately.[/b] `DotPropSpawner.may_freeze` gates freezing
## against `per_player_frozen`, and the reverse has no limit to check — a cap that
## stopped somebody tidying up would be a limit fighting its own purpose.
## Gets in, or gets out. One key for both.
##
## [b]F rather than E, because E already spawns here.[/b] Worth saying out loud: the
## sandboxes this copies bind "use" to E, and a player arriving from one of those will
## press it — so the day this game gains a use verb of its own, these two want swapping
## together rather than one at a time.
##
## [b]The client never decides the answer.[/b] It asks; the server owns the seats, the
## exit sweep and the refusal, exactly as it owns a spawn. On a client with no bridge —
## single player, and the suite — the same call goes straight to the simulation, which is
## the same division every other verb in this file makes.
func _use_vehicle() -> void:
	if bridge != null:
		bridge.ask_use_vehicle()
		return

	var used := playground.use_vehicle(player_id)

	if not used.ok:
		_report(used)


func _unfreeze_all() -> void:
	var thawed := 0

	for prop in playground.props.props_of(player_id):
		if not prop.frozen:
			continue

		DotPhysGun.set_frozen(prop, false)
		thawed += 1

	if hud != null:
		hud.notice("Unfroze %d prop%s." % [thawed, "" if thawed == 1 else "s"])


# --- Practice ---------------------------------------------------------------
#
# Saving is free; teleporting is what costs the run. That asymmetry is the whole of
# practice mode, and it is why the two are separate keys rather than one toggle.

func _checkpoints() -> DotTimerCheckpoints:
	return playground.timers.checkpoints_for(player_id)


func _save_checkpoint() -> void:
	var state := player.controller.state
	var saved := _checkpoints().save(
		state.position, state.velocity, state.yaw, state.pitch,
		state.is_grounded(), state.is_crouched()
	)

	if hud == null:
		return

	if not saved.ok:
		hud.notice(saved.error.message)
		return

	hud.notice("Checkpoint %d saved" % _checkpoints().count())


func _load_checkpoint() -> void:
	var checkpoints := _checkpoints()
	var checkpoint := checkpoints.load_current()

	if checkpoint == null:
		if hud != null:
			hud.notice("No checkpoints. C saves one.")
		return

	# Restored through the player's own teleport, which abandons the run — a
	# teleport that kept the clock running is the simplest possible cheat on any
	# timed map, and a checkpoint restore is a teleport.
	player.teleport(checkpoint.position, checkpoint.yaw)
	player.controller.state.velocity = checkpoint.velocity
	player.controller.state.pitch = checkpoint.pitch

	if hud != null:
		hud.notice("Checkpoint %d of %d" % [
			checkpoints.index + 1, checkpoints.count()
		])


func _cycle_checkpoint() -> void:
	var checkpoints := _checkpoints()

	if checkpoints.next() == null:
		return

	if hud != null:
		hud.notice("Checkpoint %d of %d" % [
			checkpoints.index + 1, checkpoints.count()
		])


func _clear_checkpoints() -> void:
	_checkpoints().clear()

	if hud != null:
		# Said explicitly, because it is the thing a player will assume it does:
		# clearing the set does not launder a run that already used one.
		hud.notice("Checkpoints cleared. The current run is still flagged.")


# --- Styles, tracks and maps -----------------------------------------------

func _cycle_style() -> void:
	var styles := playground.timers.styles_in_order()

	if styles.is_empty():
		return

	_style_index = (_style_index + 1) % styles.size()

	var chosen := styles[_style_index]

	if bridge != null:
		# The server owns which style a player is on: it decides what the movement IS,
		# and both ends have to derive the same tunables or prediction diverges.
		bridge.ask_style(chosen.id)
		return

	if playground.set_player_style(player_id, chosen.id) and hud != null:
		hud.notice("Style: %s" % chosen.display_name)


## Switches between the sandbox and whatever courses this map has.
##
## [b]The key that makes the minigame reachable at all.[/b] `pg_lobby` is a sandbox
## on the main track and a jump course on bonus 1, which is what lets one map be both
## without a timer running over somebody who is building — and without this the bonus
## track would be a zone set nothing could ever enter.
func _cycle_track() -> void:
	if player.timer == null:
		return

	var tracks := playground.tracks_on_this_map()

	if tracks.size() < 2:
		if hud != null:
			hud.notice("This map has one track.")
		return

	var index := tracks.find(player.timer.track)
	var next := tracks[(index + 1) % tracks.size()]

	if not player.timer.set_track(next):
		return

	# Moved to the new track's spawn. Staying put would leave a player standing in
	# the sandbox with a course timer that can never start, which looks exactly like
	# a timer that is broken.
	playground.spawn_player(player_id)

	if hud != null:
		hud.notice("Track: %s" % DotTimerTrack.name_of(next))


func _next_map() -> void:
	# A client does not change the map; it rocks the vote and the server decides. One
	# client loading a different world from everybody else is not a map change, it is a
	# client playing alone in a world nobody else is in.
	if bridge != null:
		bridge.ask_rtv()
		return

	var next := playground.maps.rotation.choose(playground.players.size())

	if next == null:
		return

	await playground.change_map(next.id)
