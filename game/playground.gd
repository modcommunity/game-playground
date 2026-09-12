class_name Playground
extends Node3D

## The playground: a sandbox with a surf map, a bhop map and a lobby, timed and
## ranked, with props you can spawn and a physics gun to move them with.
##
## [b]This is the only place every addon in the movement half of the family runs
## together[/b] — dot-player-controller, dot-timer, dot-map, dot-props and
## dot-leaderboard, over dot-core — and, by the family's own repeated lesson, the
## seams between them are where the bugs are. Each addon's own suite runs it with the
## others absent; `examples/headless_playground.tscn` is the only thing that runs the
## joins.
##
## [codeblock]
## godot --headless --path . res://examples/headless_playground.tscn
## [/codeblock]
##
## [b]It is a server and a client in one process.[/b] Nothing here is networked yet —
## dot-net's bridge is the next piece, and the shape is deliberately ready for it:
## the timer is authoritative in one place, the prop spawner in the same place, and
## the player's own copy of both would be non-authoritative.

const CHANNEL := "playground"

## The name this registers itself under, so a dot-server module can find it.
##
## A registry name rather than being handed in, because a module is loaded by PATH —
## [code]server.modules.load_module("res://game/playground_module.gd")[/code] — and a
## path cannot carry an instance.
const SERVICE := &"playground"

## The map changed and everything has been rebuilt against it.
signal map_ready(map: DotMapDef)

## The playground has finished booting: the first map, if any, is up.
##
## [b]Paired with [member booted], and a caller must check that first.[/b]
## [method change_map] may complete without ever suspending — a built-in map is a
## scene already in the build — in which case this has been emitted before the caller
## reaches its `await` and the `await` never returns. That is the family's own
## fan-out trap in its smallest form: a signal is not a state, and code that waits on
## one has to be able to see that it has already happened.
signal ready_for_players()

## A player now exists in [member players]. The net bridge answers this by building the
## entity that replicates them, so a player the GAME made itself — a bot, a test — is
## replicated exactly like one a peer asked for.
signal player_added(id: StringName)

## A player is about to stop existing. Emitted BEFORE the teardown, so a listener can
## still read what they were.
signal player_removed(id: StringName)

## Somebody finished a run. [param rank] is 0 when it was not filed.
signal run_filed(
	player_id: StringName, run: DotTimerRun, rank: int, reason: String
)

@export_group("Content")

## Layered configuration. One is created with the defaults if this is left empty.
##
## [b]A config rather than a wall of exports on this node[/b], because a dedicated
## server is configured by somebody who is not opening the editor. See
## [PlaygroundConfig].
@export var config: PlaygroundConfig = null

## A JSON file to layer over [member config]'s defaults, or empty for none.
@export var config_file: String = ""

@export_group("Role")

## Simulation ticks per second.
##
## [b]Read from the engine, not from here, whenever the engine has been told.[/b]
## dot-server writes [member Engine.physics_ticks_per_second] from its own
## [code]sv_tickrate[/code] cvar, so on a real server this ends up being whatever the
## operator put in [code]server.cfg[/code] — see [method _resolve_tick_rate]. The
## export is the fallback for a client or a test with no server to ask.
##
## It is also what every [DotTimerRecord] this instance files is stamped with, which
## is what lets a disputed time be checked afterwards.
@export_range(1, 240, 1) var tick_rate: int = 128

## Registry scope, so a server game and a client game can share one process — the shape
## every headless netcode test in this family takes.
##
## Without it both halves register under the same name and the second one wins, so a
## component resolving `playground` reaches whichever game happened to boot last. There
## is no error: the lookup succeeds, at the wrong game.
@export var service_scope: StringName = &""

## Whether this instance is the authority: it times, it ranks, it spawns props.
##
## Derived from [member PlaygroundConfig.authoritative] on ready rather than exported
## beside it, so there is one place to set it and no way for the two to disagree. A
## client leaves it false, runs its own timer for its HUD, and files nothing.
var authoritative: bool = true

## Whether [signal ready_for_players] has been emitted. See that signal.
var booted: bool = false

var maps: DotMapSession = null
var timers: DotTimerManager = null
var props: DotPropSpawner = null

## The vehicles. Every one of them is also a [DotPropInstance] in [member props] — see
## [PlaygroundVehicles] for why both, and [PlaygroundSpawnables.Kind.VEHICLE] for the
## one field of `meta` that joins them.
var vehicles: DotVehicleSpawner = null
var boards: DotLeaderboardManager = null

## The scripted spawnables in the world, ticked every simulated tick.
##
## A list beside the spawner's rather than a walk over it every tick: a sandbox with a
## thousand crates and four NPCs would otherwise ask a thousand props whether they are
## an NPC, a hundred and twenty-eight times a second.
var entities: Array[PlaygroundEntity] = []

## What the entities can perceive, shared by all of them.
##
## [b]dot-npc's, rather than "the nearest player" recomputed every tick.[/b] The chaser
## used to ask [method PlaygroundEntity.nearest_player] on every one of the hundred and
## twenty-eight ticks a second this game runs at, which is the classic broken NPC: two
## players standing a metre apart make it turn back and forth for ever, and one who steps
## behind a pillar makes it forget instantly and walk away mid-swing.
## [DotNpcSenses] acquires at one threshold and drops at a weaker one, with a grace
## measured from the last sighting.
##
## One object for the whole world, because its tuning is the world's rather than an
## NPC's: how far a particular thing can see belongs on its catalogue entry, and that is
## where it is.
var npc_senses: DotNpcSenses = null

## The players as [DotNpcSenses.Candidate]s, rebuilt once per simulated tick.
##
## Once per tick and not once per entity: twenty NPCs each building their own list of
## eight players is a hundred and sixty allocations a tick for one list that does not
## differ between them.
var npc_candidates: Array = []

## What a player may hold. See [PlaygroundWeapons].
var weapons: Array[PlaygroundWeaponDef] = []

## The node loaded maps and spawned props are put under.
var world: Node3D = null

## Who is in the session, which side, what class, where they start, and the physics.
##
## [b]Built last and binds to everything else.[/b] It adds no authority: the props are
## still the spawner's and the course is still dot-timer's. What it does is keep one set
## of records in step, so a scoreboard, a spectator seat and a start selector read the
## same thing. See [PlaygroundPlayerStack].
var player_stack: PlaygroundPlayerStack = null

## The players in this instance, by id.
var players: Dictionary = {}

## The movement half of each style, by id. The ranking half lives on the manager.
var movement_styles: Dictionary = {}

## Reused per player so a tick allocates nothing.
var _samples: Dictionary = {}

## Simulation ticks run. The tick number every player and every timer is stamped with.
var _tick: int = 0

## Frame time not yet spent on a simulation tick.
var _accumulator: float = 0.0

## Whether something else drives the tick — a net bridge, whose tick has to happen
## between dot-net applying inputs and building the snapshot. See [PlaygroundNetBridge].
var external_tick: bool = false


func _ready() -> void:
	if config == null:
		config = PlaygroundConfig.new()

	# Layered before anything reads it: a file, then the environment, then argv.
	var loaded := config.load_layered(config_file)

	if not loaded.ok:
		DotLog.error(CHANNEL, "the playground configuration is not usable", {
			"why": loaded.error.message
		})

	authoritative = config.authoritative
	tick_rate = _resolve_tick_rate()

	DotLog.info(CHANNEL, "playground starting", {
		"config": config.describe_summary(),
		"tick_rate": tick_rate,
		"authoritative": authoritative,
	})

	DotRegistry.register(DotRegistry.scoped_name(SERVICE, service_scope), self)

	world = Node3D.new()
	world.name = "World"
	add_child(world)

	weapons = PlaygroundWeapons.built_in()

	_build_styles()
	_build_leaderboards()
	_build_timers()
	_build_props()
	_build_vehicles()
	_build_npc_senses()
	_build_maps()
	_build_player_stack()

	# Physics ticks drive everything. Not _process: a timer sampled per frame counts
	# a different number of ticks on a 144 Hz monitor than on a 60 Hz one, and the
	# player's time then depends on their hardware.
	set_physics_process(true)

	if config.initial_map != &"":
		var started: DotResult = await change_map(config.initial_map)
		DotLog.result(CHANNEL, "loading the first map", started)

	booted = true
	ready_for_players.emit()


## Stands up the player-facing addons and binds them to this game.
##
## After the maps, because it reads the start points the map session loads — and a
## stack built before them binds to nothing and reports success.
func _build_player_stack() -> void:
	player_stack = PlaygroundPlayerStack.new()
	player_stack.name = "PlayerStack"
	# A client mirrors the server's physics; re-applying a sandbox profile there would
	# have its props settle on a different schedule from the server's, which in a
	# server-authoritative sandbox is visible as props that snap.
	player_stack.apply_physics = authoritative
	add_child(player_stack)

	var res := player_stack.setup(self)

	if not res.ok:
		DotLog.warn(CHANNEL, "the player stack is off", {"why": res.error.message})
		remove_child(player_stack)
		player_stack.queue_free()
		player_stack = null


## The rate everything counts in.
##
## [b]The engine's, when a server has set it.[/b] The chain is: an operator writes
## `sv_tickrate 128` in `server.cfg`; dot-server's `_apply_tickrate` writes
## `Engine.physics_ticks_per_second`; this reads it; `DotTimerManager` adopts it; and
## it lands on every record filed. Without that, the timer's rate would be an export
## on a node nobody would think to change, and a server retuned from 64 to 128 would
## go on producing times computed against 64 — twice their real length, on a
## leaderboard shared with servers that got it right, with no error anywhere.
##
## The exported value is the fallback for a client or a test, where the engine's rate
## is a rendering default rather than a decision anybody made.
func _resolve_tick_rate() -> int:
	var engine_rate := Engine.physics_ticks_per_second

	if engine_rate > 0:
		return engine_rate

	return tick_rate


## The simulation loop.
##
## [b]A fixed step accumulated from the frame time, not the frame's own delta.[/b]
## Delta is an input to the movement, so a variable one makes the same play produce
## different results on different machines — and it makes a run's time depend on the
## frame rate, which on a leaderboard is disqualifying. The bound on the budget is
## there so a frame spike does not spend the next frame simulating a hundred ticks and
## make the stall worse.
func _physics_process(delta: float) -> void:
	if external_tick:
		return

	var step := 1.0 / float(maxi(tick_rate, 1))

	_accumulator += delta

	var budget := 8

	while _accumulator >= step and budget > 0:
		_accumulator -= step
		budget -= 1
		_tick += 1
		_simulate_tick(step)

	if _accumulator >= step:
		DotLog.debug(CHANNEL, "tick budget exhausted; dropping simulation time", {
			"dropped": "%.3f s" % _accumulator
		})
		_accumulator = 0.0


## One simulated tick for everything.
##
## The order is the point, and it is the same order a dedicated server uses:
## move every player, then time the tick with the position the move produced. Timing
## first shifts every run by exactly one tick — and by a DIFFERENT amount at each
## tickrate, which is the tickrate dependence dot-timer's sub-tick fractions exist to
## remove.
func _simulate_tick(step: float) -> void:
	props.advance(step)
	maps.advance(step)

	# The drivers' intent, then the chassis. Before the players move, because a rider's
	# own move is skipped entirely and what a driver's keys mean this tick is engine
	# force rather than acceleration.
	_drive_vehicles()
	vehicles.tick(step)

	# What the entities can see, rebuilt before any of them thinks about it.
	#
	# Before, not after: a candidate list built at the end of a tick is a list of where
	# everybody was, and a chaser steering at last tick's position lags its target by
	# exactly one tick — which is the thing the ordering below already exists to avoid.
	_rebuild_npc_candidates()

	# Entities before players, for the same reason the timer runs after them: an NPC
	# that moved after the player was moved would be a tick behind everything that
	# collided with it, and a chaser would visibly lag its target at exactly the rate
	# the server ticks.
	#
	# Iterated over a copy because an entity may remove itself — walking into a pit,
	# or being cleaned up by a script — and `_on_prop_removed` erases from this list.
	for entity in entities.duplicate():
		if is_instance_valid(entity):
			entity.entity_tick(step)

	for id in players:
		(players[id] as PlaygroundPlayer).simulate(_tick, step)

	# After the moves and before the timers, which is the same ordering rule: a rider's
	# position for this tick is where the vehicle carried them, not where they were.
	_carry_riders()

	# And the locomotion state, from the movement that has just happened. Same rule
	# again: a state machine fed the position a player WAS at is one tick behind them,
	# and at a walk-to-run threshold that is a visible late change of animation.
	for id in players:
		(players[id] as PlaygroundPlayer).drive_character(step)

	for id in players:
		var player: PlaygroundPlayer = players[id]
		var sample: DotTimerSample = _samples[id]

		player.fill_sample(sample)

		timers.tick_player(
			id,
			sample.position,
			sample.velocity,
			sample.grounded,
			sample.alive,
			player.controller.state.yaw,
			player.controller.state.pitch,
			sample.buttons
		)


## One authoritative tick driven from outside, at a tick number the driver chose.
##
## The net bridge calls this instead of letting [method _physics_process] run, because
## the game's tick has to happen between dot-net applying the inputs that arrived and
## building the snapshot that goes back out. A game still running its own loop would
## simulate somewhere between those two and send state from the wrong instant.
func tick_once(tick: int) -> void:
	_tick = tick
	_simulate_tick(1.0 / float(maxi(tick_rate, 1)))

	if player_stack != null:
		player_stack.tick(tick)


## The timer half of a tick, and nothing else.
##
## What a CLIENT runs. A client may not simulate props — rigid bodies are not
## reproducible across machines, which is the whole reason this sandbox is
## server-authoritative — and it may not simulate remote players, which are
## interpolated from snapshots. Its own player is simulated by the predictor through
## [PlaygroundPlayerNet]. What is left is feeding every timer the position it can see,
## so a local run reads a tick earlier than any packet could deliver it.
func tick_timers_only(tick: int) -> void:
	_tick = tick

	for id in players:
		var player: PlaygroundPlayer = players[id]
		var sample: DotTimerSample = _samples[id]

		player.fill_sample(sample)

		timers.tick_player(
			id,
			sample.position,
			sample.velocity,
			sample.grounded,
			sample.alive,
			player.controller.state.yaw,
			player.controller.state.pitch,
			sample.buttons
		)


## Puts the whole game on a tick rate decided elsewhere — a server's `sv_tickrate`,
## reaching a client through HELLO.
##
## [b]Every player's controller moves with it, not just the loop.[/b] A controller
## keeps its own rate to size a step, so changing the game's and leaving theirs runs
## the simulation at one rate and the movement at another — and the symptom is a
## player who is correct on their own screen and wrong everywhere else.
## The tick this game is on.
##
## The same accessor `ArenaGame` and `G2GGame` both have, and this project did without
## because every layer it had was handed the tick as an argument. A layer that is ticked
## from the module rather than from `_simulate_tick` has no such argument, and reaching
## for `_tick` from outside would be reaching past the underscore.
func current_tick() -> int:
	return _tick


func set_tick_rate(rate: int) -> bool:
	if rate <= 0 or rate == tick_rate:
		return false

	timers.set_tick_rate(rate)
	# Read back rather than assigned: the timer manager clamps, and two copies of this
	# number that disagree is the failure the whole method exists to prevent.
	tick_rate = timers.tick_rate

	for id in players:
		(players[id] as PlaygroundPlayer).tick_rate = tick_rate

	DotLog.info(CHANNEL, "tick rate adopted", {"tick_rate": tick_rate})
	return true


# --- Building --------------------------------------------------------------

func _build_styles() -> void:
	for style in DotFpsStyle.defaults():
		movement_styles[style.id] = style


func _build_leaderboards() -> void:
	boards = DotLeaderboardManager.new()
	boards.name = "Leaderboards"
	boards.store = DotLeaderboardStoreMemory.new()
	# Off by default: publishing sends player names and times off the server, and
	# that is an operator's decision rather than a default.
	boards.report_to_backbone = config.report_to_backbone
	add_child(boards)

	var fastest := DotLeaderboardDef.make(
		&"fastest", DotLeaderboardDef.Kind.TIME
	)
	fastest.display_name = "Fastest time"
	boards.define(fastest)

	var top_speed := DotLeaderboardDef.make(
		&"top_speed", DotLeaderboardDef.Kind.POINTS
	)
	top_speed.display_name = "Highest speed"
	top_speed.decimals = 1
	top_speed.unit = "m/s"
	boards.define(top_speed)

	var points := DotLeaderboardDef.make(
		&"points", DotLeaderboardDef.Kind.POINTS
	)
	points.display_name = "Ranking points"
	points.decimals = 1
	boards.define(points)


func _build_timers() -> void:
	timers = DotTimerManager.new()
	timers.name = "Timers"

	# Handed a DotTimerConfig rather than having its exports set one at a time, so
	# the timer half is configured through the same layered path as everything else
	# — and so `tick_rate = 0` means "take it from the engine", which is what a
	# server operator setting `sv_tickrate` expects to control.
	var timer_config := DotTimerConfig.new()
	timer_config.tick_rate = 0
	timer_config.default_tick_rate = tick_rate
	timer_config.authoritative = authoritative
	timer_config.record_runs = true
	timer_config.records_directory = config.records_directory
	timer_config.record_replays = config.record_replays
	timer_config.fastest_expected_speed = 40.0

	timers.config = timer_config

	add_child(timers)

	# After `_ready` has applied the config, so this is the value everything agrees
	# on rather than the export's default.
	tick_rate = timers.tick_rate

	var timer_styles := DotTimerStyle.defaults()
	for style in timer_styles:
		# The community timers' `startinair`, on: a hopper leaves the start pad mid-hop more often
		# than not, and the prespeed clamp above is what guards the dive-through.
		style.allow_air_start = true
	timers.set_styles(timer_styles)

	timers.record_accepted.connect(_on_record_accepted)
	timers.record_refused.connect(_on_record_refused)
	timers.effect_requested.connect(_on_effect_requested)
	timers.player_finished.connect(_on_player_finished)


func _build_props() -> void:
	props = DotPropSpawner.new()
	props.name = "Props"
	props.authoritative = authoritative and config.allow_props
	props.catalogue = _prop_catalogue()

	var limits := DotPropLimits.new()
	limits.per_player_budget = config.prop_budget
	limits.world_budget = config.prop_world_budget
	limits.spawn_interval = config.prop_spawn_interval
	props.limits = limits

	props.world_ref = DotNodeRef.of_path(^"../World")

	# Every prop this build ships is the same scene, and what makes a plank a plank
	# rather than a crate is three fields of its definition. dot-props deliberately
	# does not know that: it instantiates a scene and places it, because a server
	# with real content has a scene per prop and nothing to configure.
	props.spawned.connect(_on_prop_spawned)
	props.removed.connect(_on_prop_removed)

	add_child(props)


## Builds a spawned prop's body from the definition it came from.
##
## Connected rather than done inside a subclass of [DotPropSpawner], because what a
## prop's scene needs is the game's business and overriding the spawner would mean
## re-implementing the budget, the cooldown and the undo stack to get at one line.
func _on_prop_spawned(prop: DotPropInstance) -> void:
	_classify_spawned(prop)

	match PlaygroundSpawnables.kind_of(prop.def):
		PlaygroundSpawnables.Kind.ENTITY:
			_configure_entity(prop)
			return
		PlaygroundSpawnables.Kind.VEHICLE:
			_configure_vehicle(prop)
			return
		_:
			pass

	var body := prop.node as PlaygroundProp

	if body == null:
		# A delivered prop with its own scene. Nothing to do — and not a warning,
		# because that is the shape a real server's catalogue has.
		return

	body.configure(prop.def)


## Puts a spawned body on the layer that matches what it is.
##
## [b]`sandbox_3d` is the one preset with `held_prop` and `frozen_prop` in it, and this is
## why they exist.[/b] A prop being carried by the physics gun must not collide with the
## player carrying it — otherwise it shoves them backwards down a corridor — and a frozen
## prop is scenery that everything should be solid against. They are different rows in the
## layout rather than different code, which is the whole argument for having one.
##
## Everything arrived on Godot's default layer 1 masking layer 1 before this, so two
## crates dropped in the same place fell through one another and an NPC was indis-
## tinguishable from the floor as far as collision was concerned.
##
## [b]Spawn time only, and that is a real limitation.[/b] dot-props emits `spawned`,
## `removed` and `refused` and has no signal for freezing or grabbing, so a prop frozen
## later keeps the layer it spawned with. `PlaygroundProp` calls `reclassify` when it
## changes state, which is the half this can reach.
func _classify_spawned(prop: DotPropInstance) -> void:
	if player_stack == null or prop.node == null:
		return

	var layer := &"prop"

	match PlaygroundSpawnables.kind_of(prop.def):
		PlaygroundSpawnables.Kind.ENTITY:
			layer = &"npc"
		PlaygroundSpawnables.Kind.VEHICLE:
			layer = &"vehicle"
		_:
			layer = &"frozen_prop" if prop.frozen else &"prop"

	var _put := player_stack.classify(prop.node, layer)


## Re-reads a prop's layer after it was frozen, unfrozen, grabbed or dropped.
##
## Public because the states change long after the spawn and dot-props has no signal for
## any of them — so the code that changes the state is the code that has to say so.
func reclassify_prop(node: Node, frozen: bool, held: bool) -> void:
	if player_stack == null or node == null:
		return

	var layer := &"prop"

	if held:
		layer = &"held_prop"
	elif frozen:
		layer = &"frozen_prop"

	var _put := player_stack.classify(node, layer)


## Turns a spawned body into a scripted entity, by attaching the script its definition
## names.
##
## [b]This is the whole "an entity has a script" mechanism, and it is four lines.[/b]
## The scene is a bare [RigidBody3D]; the script comes from `meta`, is loaded by PATH
## because a mounted dot-cloud pack's `class_name` globals are not registered in the
## host, and is attached here. [method Node._ready] has already run by this point —
## the spawner adds the body to the world before it emits — so nothing in an entity
## may rely on `_ready`, which is why the base has `_entity_ready` instead.
##
## A failure removes the prop rather than leaving it. A body with no script sits there
## being a crate, which is indistinguishable from an NPC with nothing to do — and "the
## NPC does not move" sends the next person to the movement code.
func _configure_entity(prop: DotPropInstance) -> void:
	var script := PlaygroundSpawnables.load_script(prop.def)

	if script == null:
		props.remove(prop.instance_id, DotPropSpawner.REASON_CLEANUP)
		return

	var body := prop.node as RigidBody3D

	if body == null:
		DotLog.error(CHANNEL, "an entity's scene is not a RigidBody3D", {
			"entity": String(prop.def.id), "scene": prop.def.scene_path
		})
		props.remove(prop.instance_id, DotPropSpawner.REASON_CLEANUP)
		return

	body.set_script(script)

	# Checked after attaching rather than assumed. A script that is valid GDScript but
	# extends the wrong thing attaches perfectly and then has none of the methods the
	# tick calls — and the first symptom is a crash inside the simulation loop, a long
	# way from the catalogue entry that caused it.
	var entity := body as PlaygroundEntity

	if entity == null:
		DotLog.error(CHANNEL, "an entity's script is not an entity", {
			"entity": String(prop.def.id),
			"script": PlaygroundSpawnables.script_of(prop.def),
			"hint": "extend res://game/entities/playground_entity.gd",
		})
		props.remove(prop.instance_id, DotPropSpawner.REASON_CLEANUP)
		return

	entity.configure(prop.def)
	entity.bind(self, prop)

	entities.append(entity)


## The vehicle spawner, and the handover it drives.
##
## [b]It spawns nothing.[/b] Every vehicle in this game arrives through
## [DotPropSpawner] and is handed over with [method DotVehicleSpawner.adopt], because a
## vehicle here is a prop first — budgeted, undoable, and punt-able by a gravity gun. Its
## own budget is left generous for that reason: the number that actually limits vehicles
## is the prop budget, and a second limit that bites first would be a refusal an operator
## editing `pg_prop_budget` could not explain.
func _build_vehicles() -> void:
	vehicles = DotVehicleSpawner.new()
	vehicles.name = "Vehicles"
	vehicles.authoritative = authoritative and config.allow_props
	vehicles.catalogue = PlaygroundVehicles.catalogue()
	vehicles.world_ref = DotNodeRef.of_path(^"../World")
	vehicles.world_budget = 0
	vehicles.per_player_budget = 0
	vehicles.spawn_interval = 0.0

	# The rider node IS carried: a PlaygroundPlayer is a Node3D with the camera under it
	# on a client, so parenting it into the seat is what puts a rider's view on the
	# vehicle without a single line about cameras in this file. The controller state is
	# pulled back off the node each tick — see [method _carry_riders].
	vehicles.ride.carry_rider_nodes = true

	# Layer 1 is the world's, which is what a playground map builds its geometry on and
	# what the movement collides against. Checked rather than left at the addon's default
	# of 1 by luck: an exit sweep against the wrong mask finds nothing, always succeeds,
	# and puts players through walls — the one failure this whole sweep exists to stop.
	vehicles.ride.exit_mask = 1

	vehicles.ride.on_seated = _on_seated
	vehicles.ride.on_unseated = _on_unseated

	add_child(vehicles)


## Makes a spawned prop a vehicle as well.
##
## [b]Configured before adopted, and the order is load-bearing.[/b] [DotVehicleWheeled]
## walks the body's direct children for wheels once, when the chassis binds, and caches
## what it finds — so a car whose wheels are built after the adoption has four wheels
## that nothing drives, steers or brakes, with every number in its tunables correct.
func _configure_vehicle(prop: DotPropInstance) -> void:
	var body := prop.node as PlaygroundVehicle

	if body == null:
		# A delivered vehicle with its own scene, exactly as a delivered prop is. Its
		# scene is its own business; all this game needs is a Node3D to adopt.
		var plain := prop.node as Node3D

		if plain == null:
			DotLog.error(CHANNEL, "a vehicle's scene is not a Node3D", {
				"vehicle": String(prop.def.id), "scene": prop.def.scene_path
			})
			props.remove(prop.instance_id, DotPropSpawner.REASON_CLEANUP)
			return
	else:
		body.configure(prop.def)

	var vehicle_id := PlaygroundVehicles.vehicle_id_of(prop.def)
	var vehicle := vehicles.adopt(prop.node as Node3D, vehicle_id, prop.owner_id)

	if vehicle == null:
		# Loud, and the prop goes with it. A body that is a vehicle in the catalogue and
		# not one in the world is a car that will not drive, sitting there being a crate
		# — which sends the next person to the handling code.
		DotLog.error(CHANNEL, "a vehicle would not be adopted", {
			"prop": String(prop.def.id), "vehicle": String(vehicle_id)
		})
		props.remove(prop.instance_id, DotPropSpawner.REASON_CLEANUP)
		return

	if body != null:
		body.vehicle_def = vehicle.def


## Whoever is in a vehicle stops being a player who walks.
##
## [b]The controller is turned OFF, not ignored.[/b] A controller still simulating a
## player parented into a moving vehicle writes its own answer into the state every tick
## and the two fight: the movement pushes the body one way, the vehicle carries the node
## the other, and the result reads as the vehicle shaking itself apart. [method
## PlaygroundPlayer.set_riding] is the switch; [method _carry_riders] is what keeps the
## replicated state honest while it is off.
func _on_seated(
	rider_id: StringName, vehicle: DotVehicleInstance, seat: DotVehicleSeat
) -> void:
	var player: PlaygroundPlayer = players.get(rider_id)

	if player == null:
		return

	player.set_riding(true)

	# The run goes on a track that is run, and it is not optional there: a timed course
	# driven in a car is not a run anybody can compare with one that was walked, and
	# dot-timer has no idea a vehicle exists. Stopping it is the same call a teleport
	# makes, for the same reason.
	#
	# [b]On a track that is DRIVEN, getting in is the opposite of a reason to stop.[/b]
	# `pg_lobby`'s bonus 3 is a circuit, where the car is the point; cancelling there
	# would make a driving track impossible to build, and the rule that could not tell
	# the two apart is why there was not one. The map answers, because the map is the
	# only thing that knows which of its tracks is which.
	if player.timer != null and not _track_is_driven(player.timer.track):
		player.timer.stop(DotTimer.REASON_TELEPORT)

	# A physics gun cannot hold a prop from inside a car. Not a rule about vehicles: the
	# tools reach from the eye and the eye has just moved, so whatever was on the end of
	# the beam is now somewhere the player never aimed.
	if player.phys_gun != null:
		player.phys_gun.release()
	if player.grav_gun != null:
		player.grav_gun.drop()

	DotLog.debug(CHANNEL, "a player got in", {
		"player": String(rider_id), "vehicle": String(vehicle.def.id), "seat": String(seat.id)
	})


func _on_unseated(
	rider_id: StringName,
	_vehicle: DotVehicleInstance,
	_seat: DotVehicleSeat,
	at: Vector3
) -> void:
	var player: PlaygroundPlayer = players.get(rider_id)

	if player == null:
		return

	player.set_riding(false)

	# And the mirror image on a driving track: the run ends when the driver leaves the
	# car, because the rest of the lap on foot is not the same lap. On a foot track
	# getting out changes nothing, which is what it has always done.
	if player.timer != null and _track_is_driven(player.timer.track):
		player.timer.stop(DotTimer.REASON_TELEPORT)

	# Put down where the sweep said there was room, through the controller's own state
	# rather than by moving the node: the movement reads position from the state and
	# would put them straight back otherwise. `teleport` is the one call that sets both.
	player.teleport(at)


## Keeps a riding player's movement state on the seat they are sitting in.
##
## [b]The half that is invisible until somebody watches from another machine.[/b] The
## rider's NODE is carried by the vehicle, because dot-vehicle reparents it — but
## everything that reads a player reads [code]controller.state.position[/code]: the
## timer, the NPC candidate list, the HUD, and above all [PlaygroundPlayerNet], which
## replicates the movement state and nothing else. Without this a passenger is drawn on
## everybody else's screen at the spot where they got in, for the whole journey, while
## being perfectly correct on their own.
##
## Run AFTER the vehicles have ticked and before the timers are fed, which is the same
## "time the tick with the position the move produced" rule the players already follow.
func _carry_riders() -> void:
	if vehicles == null or vehicles.ride.rider_count() == 0:
		return

	for id in players:
		var player: PlaygroundPlayer = players[id]

		if not player.riding:
			continue

		var vehicle := vehicles.vehicle_of_rider(id)

		if vehicle == null:
			continue

		player.adopt_ride(player.global_position, vehicle.velocity())


func _build_npc_senses() -> void:
	npc_senses = DotNpcSenses.new()

	# Tuned for a sandbox rather than for a horde. A playground NPC is something a
	# player is poking at, so it should be harder to make it change its mind and quicker
	# to give up than a zombie in a corridor would be.
	npc_senses.switch_ratio = 0.55
	npc_senses.commitment_grace = 2.5

	# Off. A line-of-sight raycast per candidate per NPC at 128 Hz is the single most
	# expensive thing an NPC layer can do, and in a sandbox where the NPCs are toys
	# nobody is hiding from them. A catalogue entry can still ask for it per kind.
	npc_senses.line_of_sight_enabled = true


## The players as perception candidates. See [member npc_candidates].
func _rebuild_npc_candidates() -> void:
	npc_candidates.clear()

	for id in players:
		var player: PlaygroundPlayer = players[id]

		# Loudness is the player's own speed. A sprinting player is heard further than
		# one edging along a wall, which is the whole reason hearing is separate from
		# sight — and it is a number this game already has.
		var loudness := player.speed() * 0.9

		npc_candidates.append(
			DotNpcSenses.Candidate.new(id, player.global_position, &"player", loudness)
		)


## Drops an entity from the tick list when its prop goes.
##
## Connected to the spawner's own signal rather than checked per tick. `removed` is
## emitted BEFORE the node is freed, which is exactly so a listener holding a
## reference can let go while it still exists.
func _on_prop_removed(prop: DotPropInstance, _reason: StringName) -> void:
	# A vehicle first, because it may still have people in it. `remove` evacuates them —
	# forcing the exit, because a car being deleted is exactly the case where there may
	# be nowhere to stand — and leaves the node alone, since dot-props owns it.
	if PlaygroundSpawnables.kind_of(prop.def) == PlaygroundSpawnables.Kind.VEHICLE:
		# Found by NODE, not by the prop's instance id. dot-props and dot-vehicle both
		# key their tables on "an instance id" and there is nothing making the two the
		# same number; the node is what both of them actually agree about.
		var riding_vehicle := vehicles.vehicle_for_node(prop.node) if vehicles != null else null

		if riding_vehicle != null:
			vehicles.remove(riding_vehicle.instance_id, DotVehicleSpawner.REASON_CLEANUP)

	var entity := prop.node as PlaygroundEntity

	if entity == null:
		return

	entities.erase(entity)


func _build_maps() -> void:
	maps = DotMapSession.new()
	maps.name = "Maps"
	maps.world_ref = DotNodeRef.of_path(^"../World")
	add_child(maps)

	maps.catalogue = _map_catalogue()

	if config.catalogue_path != "":
		var loaded := maps.load_catalogue(config.catalogue_path)
		DotLog.result(CHANNEL, "loading the map catalogue", loaded)

	maps.rotation = DotMapRotation.of(maps.catalogue)
	maps.rotation.cooldown = 1

	maps.time_limit.duration = config.map_seconds
	maps.time_limit.rtv_fraction = config.rtv_fraction

	maps.changing.connect(_on_map_changing)
	maps.changed.connect(_on_map_changed)
	maps.map_over.connect(_on_map_over)


## The maps this build ships. A server with delivered maps loads a JSON catalogue.
##
## An instance method that forwards, so a caller with a [Playground] keeps working — and
## [b]a static one beside it, because the server browser needs the list without a game.[/b]
## A browser is a menu: there is no world, no server and no [Playground] to ask, and a
## second copy of the list written into the menu is the thing this tree has now gone stale
## four times over.
func _map_catalogue() -> DotMapCatalogue:
	return map_catalogue()


static func map_catalogue() -> DotMapCatalogue:
	var catalogue := DotMapCatalogue.new()

	var table := [
		[&"pg_lobby", "Playground", DotMapDef.KIND_SANDBOX, 1],
		[&"pg_surf_intro", "Surf: Introduction", DotMapDef.KIND_SURF, 2],
		[&"pg_bhop_intro", "Bhop: Introduction", DotMapDef.KIND_BHOP, 3],
		# The one map in this family that is not written down. A sandbox's content is
		# what the players build in it, so "somewhere new" is worth more here than
		# "somewhere good" -- which is not true of the three above, and is why this is
		# the only one.
		[&"pg_generated", "Playground: Generated", DotMapDef.KIND_SANDBOX, 1],
	]

	for row in table:
		var map := DotMapDef.new()
		map.id = row[0]
		map.display_name = row[1]
		map.kind = row[2]
		map.tier = row[3]
		map.scene_path = "res://maps/%s.tscn" % String(row[0])
		map.author = "playground"
		catalogue.add(map)

	return catalogue


func _prop_catalogue() -> DotPropCatalogue:
	if config.props_path != "":
		# An operator's own catalogue, which is the seam between "a game with a
		# handful of props" and "a server with a content pack". Loaded here rather
		# than layered over the built-in list: a catalogue that merged with the
		# defaults would give every server these fourteen whether it wanted them or
		# not, and there would be no way to remove one.
		var loaded := DotPropCatalogue.load_json(config.props_path)

		if loaded.ok:
			var theirs := loaded.value as DotPropCatalogue

			DotLog.info(CHANNEL, "loaded a prop catalogue", {
				"path": config.props_path, "props": theirs.size()
			})

			for problem in theirs.problems():
				DotLog.warn(CHANNEL, "the prop catalogue has a problem", {
					"problem": problem
				})

			return theirs

		# Refused rather than fallen back on silently. An operator who pointed this
		# at a file and got the built-in props would conclude their file was being
		# read and their edits ignored.
		DotLog.error(CHANNEL, "the prop catalogue could not be read", {
			"path": config.props_path, "why": loaded.error.message
		})

	return PlaygroundSpawnables.catalogue()


# --- Players ---------------------------------------------------------------

## Adds a player and puts them on the current map's spawn.
func add_player(id: StringName, display_name: String) -> PlaygroundPlayer:
	if players.has(id):
		return players[id]

	var player := PlaygroundPlayer.new()
	player.name = "Player_" + String(id)
	player.player_id = id
	player.display_name = display_name
	player.authoritative = authoritative
	player.tick_rate = tick_rate

	add_child(player)

	var added := timers.add_player(id, display_name)

	if not added.ok:
		DotLog.warn(CHANNEL, "could not give a player a timer", {
			"player": String(id), "why": added.error.message
		})

	player.timer = timers.timer_for(id)

	player.set_style(
		movement_styles[&"normal"], timers.style_for(&"normal")
	)

	player.phys_gun = DotPhysGun.new()
	player.phys_gun.spawner = props
	player.phys_gun.wielder = id

	# [b]A held prop, a frozen prop and a loose one are three rows in the layout.[/b]
	# `sandbox_3d` carries `held_prop` and `frozen_prop` for exactly this, and until
	# dot-props grew these three signals a game could only set a layer at spawn and then
	# be wrong for the rest of the prop's life — a carried crate colliding with the
	# player carrying it, which shoves them backwards down a corridor.
	player.phys_gun.grabbed.connect(
		func(prop: DotPropInstance, _who: StringName) -> void:
			reclassify_prop(prop.node, false, true)
	)
	player.phys_gun.released.connect(
		func(prop: DotPropInstance, _who: StringName) -> void:
			reclassify_prop(prop.node, prop.frozen, false)
	)
	player.phys_gun.freeze_changed.connect(
		func(prop: DotPropInstance, frozen: bool) -> void:
			reclassify_prop(prop.node, frozen, prop.held_by != &"")
	)

	player.grav_gun = DotGravGun.new()
	player.grav_gun.spawner = props
	player.grav_gun.wielder = id

	# The layout's player mask rather than the magic 1. With props, entities and
	# vehicles on their own layers, a mask of 1 is a player who walks through all three.
	if player_stack != null:
		player.use_collision_mask(player_stack.player_collision_mask())
		# And a body other people can see. Built for every player, local or not: the one
		# who does not need it is the LOCAL player in first person, and that is a
		# `set_shown(false)` rather than a missing model.
		player.build_character(player_stack.character(), _colour_for(id))
		# And the body itself, now that a player IS a CharacterBody3D — it is in the
		# physics space whether or not the movement uses it, and a body on layer 1 is a
		# body every other sweep treats as level geometry.
		var _put := player_stack.classify(player, &"player")


	players[id] = player
	_samples[id] = DotTimerSample.new()

	spawn_player(id)

	# After the player is fully built and in the dictionary: a listener answers this
	# by replicating them, and an entity built over a half-constructed player would
	# replicate a controller that has no style and no timer.
	player_added.emit(id)

	return player


func remove_player(id: StringName) -> void:
	if not players.has(id):
		return

	# Before anything is torn down, so a listener can still read what they were.
	player_removed.emit(id)

	# Their rock-the-vote goes with them. Without it a server whose players trickle
	# away keeps their votes while the threshold falls with the player count, so a
	# map ends on the votes of people who are no longer there.
	maps.time_limit.unrock(id)

	# Out of the car before anything else, and forced. A player who disconnects while
	# riding leaves a node stowed inside a vehicle and a rider id the ride will never
	# clear — so the seat stays occupied for the rest of the round and the id can never
	# enter anything again. Forced because there may be nowhere legal to stand, and the
	# alternative to putting them somewhere is not putting them anywhere.
	if vehicles != null and vehicles.ride.is_riding(id):
		var riding := vehicles.vehicle_of_rider(id)

		if riding != null:
			vehicles.ride.exit(riding, id, true)

	# Their vehicles are DISOWNED rather than removed, which is dot-vehicle's rule and
	# the opposite of dot-props'. A prop is a thing somebody built; a vehicle is a thing
	# somebody parked, usually with other people in it, and deleting it deletes the car
	# three passengers are riding in.
	if vehicles != null:
		vehicles.owner_left(id)

	# The prop spawner first: it may free nodes, and doing it after the player's own
	# teardown means a physics gun holding one of them is already gone.
	props.player_left(id)
	timers.remove_player(id)

	(players[id] as PlaygroundPlayer).queue_free()

	players.erase(id)
	_samples.erase(id)


## Puts a player at the current map's spawn for their track.

## A stable colour for a player, derived from their id.
##
## [b]Derived rather than assigned, so two machines agree without sending anything.[/b]
## A colour handed out by the server is one more field on the wire and one more thing to
## be out of step during a reconnect; a hash of the id is the same colour everywhere, for
## ever, for free. Full saturation and a fixed value, because two players told apart by
## brightness alone are not told apart at a distance.
func _colour_for(id: StringName) -> Color:
	var hue := float(hash(String(id)) % 360) / 360.0
	return Color.from_hsv(hue, 0.62, 0.92)


func spawn_player(id: StringName) -> void:
	var player: PlaygroundPlayer = players.get(id)

	if player == null:
		return

	var track := player.timer.track if player.timer != null else DotTimerTrack.MAIN
	var map := current_map_node()

	# [b]The director chooses among the map's own starts; the map is the fallback.[/b]
	# `PlaygroundPlayerStack.refresh_spawns` copies every track's start into it, so this
	# is a better choice among one set rather than a second set — the per-site cooldown,
	# the occupancy check, and with the arena layer on the protection window that is
	# granted inside `choose` and nowhere else.
	if player_stack != null:
		var chosen := player_stack.choose_start(id, track)

		if chosen.ok:
			var choice := chosen.value as DotSpawnChoice
			# Degrees out, for the same reason radians went in: `DotFpsState.yaw` is in
			# degrees and `DotFpsController` converts at exactly this boundary too.
			player.teleport(
				choice.transform.origin,
				rad_to_deg(choice.transform.basis.get_euler().y)
			)
			return

	if map != null:
		player.teleport(map.spawn_for(track), map.spawn_yaw_for(track))
	else:
		player.teleport(Vector3(0.0, 2.0, 0.0), 0.0)


## Puts a player on a style, both halves.
func set_player_style(id: StringName, style_id: StringName) -> bool:
	var player: PlaygroundPlayer = players.get(id)

	if player == null or not movement_styles.has(style_id):
		return false

	var ranking := timers.style_for(style_id)

	if ranking == null:
		return false

	return player.set_style(movement_styles[style_id], ranking).ok


## The definition of one weapon, or null.
func weapon_def(id: StringName) -> PlaygroundWeaponDef:
	return PlaygroundWeapons.find(weapons, id)


## Whether a player may act on somebody else's props, from the configuration.
##
## [b]Asked of the game, not decided in a tool.[/b] dot-props passes
## `can_touch_others` to every tool call precisely so this is one answer in one place;
## a physics gun and a remover that disagreed would be a server where you cannot move
## somebody's crate but can delete it.
func may_touch_others() -> bool:
	return config == null or config.touch_others_props


func current_map_node() -> PlaygroundMap:
	return maps.world as PlaygroundMap if maps != null else null


## Which tracks this map actually has something on, main track first.
##
## [b]Derived from the zones rather than declared on the map.[/b] A second list of
## tracks is a second thing that can disagree with the zone file — and it is the zone
## file a delivered map ships, so the declaration would be the half that is missing
## exactly when it matters.
##
## [constant DotTimerTrack.MAIN] is always in the result even when it has no zones at
## all, because a sandbox is a legitimate track: `pg_lobby` is one, and a player has
## to be able to get back to it from the course.
func tracks_on_this_map() -> Array[int]:
	var out: Array[int] = [DotTimerTrack.MAIN]

	if timers == null or timers.zones == null:
		return out

	for zone in timers.zones.zones:
		if zone.track != DotTimerTrack.MAIN and not out.has(zone.track):
			out.append(zone.track)

	out.sort()

	return out


# --- Maps ------------------------------------------------------------------

func change_map(id: StringName) -> DotResult:
	return await maps.change_to(id)


## The seed a generated map is built from.
##
## [b]Zero means "pick one and announce it", which is the only honest default.[/b] A
## generated world nobody can name the seed of is a world nobody can share, and "play the
## map I played" is the single most-requested feature every one of them gets. `pg_seed`
## is the cvar, and the seed that was actually used is logged whichever way it came.
##
## Taken from dot-randomness when a game has one, so a generated map and every other
## random thing in the session come out of one seed rather than two.
func map_seed() -> int:
	if config != null and config.map_seed != 0:
		return config.map_seed

	var rng: Object = DotRegistry.get_service(&"dot_random_source")
	if rng != null and rng.has_method("seed_for"):
		return int(rng.call("seed_for", &"map"))

	# Nothing configured and no randomness manager: a fixed seed rather than a random
	# one, because a sandbox that is a different shape on every boot and cannot say why
	# is worse than one that is always the same.
	return 1


func _on_map_changing(_from: DotMapDef, _to: DotMapDef) -> void:
	# Announced before anything is torn down, which is the whole point of the signal:
	# every run in progress is on geometry that is about to stop existing, and every
	# prop is parented to it.
	for id in players:
		var player: PlaygroundPlayer = players[id]

		if player.timer != null:
			player.timer.stop(DotTimer.REASON_RESET)

		if player.phys_gun != null:
			player.phys_gun.release()

		if player.grav_gun != null:
			player.grav_gun.drop()

	props.clear_all(DotPropSpawner.REASON_CLEANUP)


func _on_map_changed(map: DotMapDef, loaded: Node) -> void:
	var playground_map := loaded as PlaygroundMap

	# A map that has to be told something before it can build itself. Duck-typed rather
	# than type-checked, so a delivered map with the same shape works and this file names
	# nothing from `maps/`.
	#
	# [b]Before the spawns below, and that ordering is the whole reason it is here.[/b]
	# A generated map's spawn point comes out of the generator, so spawning a player
	# before it has run puts them at the fallback -- which on a generated map is a guess,
	# and a guess inside a wall is a player who cannot move.
	if loaded != null and loaded.has_method("configure"):
		loaded.call("configure", map_seed(), DotRegistry.get_service(&"dot_random_source"))

	# A map that carries its own zones hands them over; one that ships a JSON file
	# has already had it read by dot-map, into `maps.zones_json`. Both routes end
	# here, which is what lets a delivered map and a built-in one behave the same.
	var zones: DotTimerZoneSet = null

	if playground_map != null:
		zones = playground_map.timer_zones()

	if zones == null and maps.zones_json != "":
		var parsed := DotTimerZoneSet.from_json(maps.zones_json)

		if parsed.ok:
			zones = parsed.value
		else:
			DotLog.warn(CHANNEL, "a map's zone file could not be read", {
				"map": String(map.id), "why": parsed.error.message
			})

	timers.set_zones(zones)

	for id in players:
		spawn_player(id)

	DotLog.info(CHANNEL, "map ready", {
		"map": String(map.id),
		"zones": zones.zones.size() if zones != null else 0,
		"players": players.size(),
	})

	map_ready.emit(map)


## The map ran out of time, or enough players rocked the vote.
##
## [b]The session says the map is over; deciding what happens next is here.[/b] A
## game might run a vote, show a scoreboard, finish the round first, or go straight
## to the rotation — and a session that changed the map itself would have to be
## fought by every game that wanted any of those.
##
## A run in progress is not protected: a map ending under somebody mid-run costs them
## that attempt, which is what a time limit means. Waiting for the last runner would
## mean a map that never ends while one person keeps restarting.
func _on_map_over(_map: DotMapDef, reason: StringName) -> void:
	var next := maps.rotation.choose(players.size())

	if next == null:
		DotLog.warn(CHANNEL, "the map is over and the rotation has nothing to offer")
		return

	DotLog.info(CHANNEL, "changing map", {
		"reason": String(reason), "to": String(next.id)
	})

	var changed: DotResult = await change_map(next.id)

	if not changed.ok:
		# Still on the old map, which is what dot-map's ordering guarantees. Restart
		# its clock rather than leaving a server that will never try again.
		DotLog.warn(CHANNEL, "the map change failed; extending instead", {
			"why": changed.error.message
		})
		maps.time_limit.extend(120.0)


## Registers a rock-the-vote from a player.
# --- Vehicles ---------------------------------------------------------------

## Turns each driver's movement keys into what their vehicle is being asked for.
##
## [b]The mapping is here and not in dot-vehicle, and that is where it belongs.[/b] A
## [DotVehicleCommand] is built by the game from a keyboard, a gamepad, a touch layout or
## a bot; the addon deliberately has no input at all. Reusing [DotFpsCommand] rather than
## adding a second wire format is the other half of the same decision — a client already
## sends one of those every tick, it is already sanitised, already replayed by the
## predictor and already quantised, and a driver's throttle is exactly as much a per-tick
## intent as a walk is.
func _drive_vehicles() -> void:
	if vehicles == null or vehicles.ride.rider_count() == 0:
		return

	for id in players:
		var player: PlaygroundPlayer = players[id]

		if not player.riding:
			continue

		var vehicle := vehicles.vehicle_of_rider(id)

		if vehicle == null or vehicle.driver() != id:
			# A passenger's keys do nothing, and the refusal is dot-vehicle's anyway:
			# `set_command` checks the driver on the server on every command, because a
			# client is a program the player can edit and driving from the back seat is
			# what that hole would give them.
			continue

		vehicles.set_command(vehicle.instance_id, id, drive_command(player.pending_command()))


## One tick of driving, from one tick of movement input.
##
## Static and public because it is the whole mapping, and a suite that had to build a
## player to test it would be testing something else.
static func drive_command(move: DotFpsCommand) -> DotVehicleCommand:
	var cmd := DotVehicleCommand.new()

	if move == null:
		return cmd

	# W and S. `move.y` is forward in DotFpsCommand and +1 is forward in
	# DotVehicleCommand, so this is not a coincidence worth inverting.
	cmd.throttle = move.move.y
	# A and D. `move.x` strafes right and +1 steers right.
	cmd.steer = move.move.x

	# Crouch brakes and jump is the handbrake. Both are chosen so a player who gets into
	# a car with their fingers where they were still has a brake under one of them.
	cmd.brake = 1.0 if move.is_pressed(DotFpsCommand.BUTTON_CROUCH) else 0.0
	cmd.handbrake = move.is_pressed(DotFpsCommand.BUTTON_JUMP)

	cmd.aim_yaw = deg_to_rad(move.yaw)
	cmd.aim_pitch = deg_to_rad(move.pitch)

	return cmd.sanitise()


## The nearest vehicle a player could get into, or null.
##
## [b]Measured from the eye and not from the feet.[/b] A player standing beside a car is
## about 1.7 m above the point their body reports, and a reach measured from there is a
## reach that fails while they are looking straight at the door.
func vehicle_near(player_id: StringName, reach: float = 3.5) -> DotVehicleInstance:
	var player: PlaygroundPlayer = players.get(player_id)

	if player == null or vehicles == null:
		return null

	return vehicles.nearest_free(player.eye_position(), reach)


## Gets a player into whatever they are standing next to, or out of what they are in.
##
## [b]One entry point for both, because the player pressed one key.[/b] A game with
## separate "enter" and "exit" calls has a client deciding which one to send, and a
## client that guesses wrong asks to get into the car it is already in.
func use_vehicle(player_id: StringName) -> DotResult:
	var player: PlaygroundPlayer = players.get(player_id)

	if player == null or vehicles == null:
		return DotResult.fail(DotError.CODE_STATE, "No such player.")

	var riding := vehicles.vehicle_of_rider(player_id)

	if riding != null:
		return vehicles.ride.exit(riding, player_id)

	var near := vehicle_near(player_id)

	if near == null:
		return DotResult.fail(DotError.CODE_STATE, "There is nothing to get into.")

	return vehicles.ride.enter(near, player_id, player)


func rock_the_vote(player_id: StringName) -> bool:
	return maps.rock_the_vote(player_id, players.size())


# --- Timer events ----------------------------------------------------------

func _on_effect_requested(player_id: StringName, zone: DotTimerZone) -> void:
	var player: PlaygroundPlayer = players.get(player_id)

	if player == null:
		return

	# The timer never moves a player. It says what the map asked for and this
	# decides what that means here — which is the only reason the same timer works
	# for a first-person game, a 2D game and a replay being scrubbed.
	match zone.kind:
		DotTimerZone.Kind.RESPAWN:
			spawn_player(player_id)
		DotTimerZone.Kind.TELEPORT:
			player.teleport(zone.destination, zone.destination_yaw)
		DotTimerZone.Kind.SLAY:
			spawn_player(player_id)
		_:
			pass


## Zones the timer cannot act on are applied here, once per tick, by the player.
##
## Nothing to do at this level: the effects that matter to the movement are read
## directly off the timer inside `PlaygroundPlayer._on_simulated`, because they change
## where the player ends up and so have to be applied on the tick rather than when a
## signal arrives.
func _on_player_finished(player_id: StringName, run: DotTimerRun) -> void:
	var player: PlaygroundPlayer = players.get(player_id)

	if player == null:
		return

	# The movement statistics belong to the controller and the run belongs to the
	# timer, and this is the one place they meet.
	timers.note_stats(player_id, player.controller.stats.to_dictionary())
	player.controller.stats.reset()

	player.finished.emit(run)


func _on_record_accepted(
	record: DotTimerRecord, _previous: DotTimerRecord, rank: int
) -> void:
	var scope := {
		"map": String(record.map_id),
		"track": str(record.track),
		"style": String(record.style_id),
	}

	await boards.submit(
		&"fastest", scope, record.player_id, record.player_name, record.time
	)

	if record.stats.has("max_speed"):
		await boards.submit(
			&"top_speed", scope, record.player_id, record.player_name,
			float(record.stats["max_speed"])
		)

	# Points are global rather than per map: a player's standing on the server is
	# the sum of what they have earned, and scoping it per map would make every map
	# its own points board, which is what "fastest" already is.
	var totals := DotStatSet.new()
	totals.add(&"points", record.points)
	totals.add(&"completions", 1.0)

	await boards.add_stats(record.player_id, totals)
	await boards.publish_stat(
		&"points", {}, record.player_id, record.player_name, &"points"
	)

	# The player may have left between finishing and the record reaching the store —
	# every `await` above is a chance for it, and a disconnect during the write is
	# exactly when this path is slowest.
	var who := timers.player(record.player_id)

	if who == null:
		return

	run_filed.emit(record.player_id, who.last_finished, rank, "")


func _on_record_refused(
	player_id: StringName, run: DotTimerRun, reason: String
) -> void:
	# Reported rather than swallowed. "I finished and nothing happened" is the
	# commonest complaint on a timer server and the reason is almost always one the
	# player could have been told.
	DotLog.info(CHANNEL, "a run was not recorded", {
		"player": String(player_id), "why": reason
	})

	run_filed.emit(player_id, run, 0, reason)


# --- Diagnostics -----------------------------------------------------------

func describe() -> Dictionary:
	return {
		"map": String(maps.current.id) if maps != null and maps.current != null else "-",
		"players": players.size(),
		"props": props.world_count() if props != null else 0,
		"tick_rate": tick_rate,
		"time_left": maps.time_limit.formatted_remaining() if maps != null else "-",
		"timers": timers.describe() if timers != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("map          %s" % (
		String(maps.current.id) if maps != null and maps.current != null else "-"
	))
	out.append("players      %d" % players.size())
	out.append("props        %d" % (props.world_count() if props != null else 0))
	out.append("tick rate    %d%s" % [
		tick_rate,
		"" if timers == null or timers.tick_rate_matches_engine()
			else " (DISAGREES with the engine's %d)" % Engine.physics_ticks_per_second,
	])
	out.append("time left    %s" % (
		maps.time_limit.formatted_remaining() if maps != null else "-"
	))

	for id in players:
		out.append("  %s" % str((players[id] as PlaygroundPlayer).describe()))

	return out


func _exit_tree() -> void:
	DotRegistry.unregister_instance(DotRegistry.scoped_name(SERVICE, service_scope), self)


## Whether the current map calls [param track] a driving track.
##
## Answered by the map, defaulting to false when there is no map loaded — the state a
## dedicated server is in between `changelevel`s, where there is also nobody riding
## anything, and where the safe answer is the one every map gave before there were cars.
func _track_is_driven(track: int) -> bool:
	var map := current_map_node()

	return map != null and map.track_is_driven(track)
