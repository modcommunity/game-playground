class_name Playground
extends Node3D

## The playground: a sandbox with a surf map, a bhop map and a lobby, timed and
## ranked, with props you can spawn and a physics gun to move them with.
##
## [b]This is the only place every addon in the movement half of the family runs
## together[/b] — dot-fps-controller, dot-timer, dot-map, dot-props and
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
var boards: DotLeaderboardManager = null

## The scripted spawnables in the world, ticked every simulated tick.
##
## A list beside the spawner's rather than a walk over it every tick: a sandbox with a
## thousand crates and four NPCs would otherwise ask a thousand props whether they are
## an NPC, a hundred and twenty-eight times a second.
var entities: Array[PlaygroundEntity] = []

## What a player may hold. See [PlaygroundWeapons].
var weapons: Array[PlaygroundWeaponDef] = []

## The node loaded maps and spawned props are put under.
var world: Node3D = null

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

	DotRegistry.register(SERVICE, self)

	world = Node3D.new()
	world.name = "World"
	add_child(world)

	weapons = PlaygroundWeapons.built_in()

	_build_styles()
	_build_leaderboards()
	_build_timers()
	_build_props()
	_build_maps()

	# Physics ticks drive everything. Not _process: a timer sampled per frame counts
	# a different number of ticks on a 144 Hz monitor than on a 60 Hz one, and the
	# player's time then depends on their hardware.
	set_physics_process(true)

	if config.initial_map != &"":
		var started: DotResult = await change_map(config.initial_map)
		DotLog.result(CHANNEL, "loading the first map", started)

	booted = true
	ready_for_players.emit()


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
	if PlaygroundSpawnables.kind_of(prop.def) == PlaygroundSpawnables.Kind.ENTITY:
		_configure_entity(prop)
		return

	var body := prop.node as PlaygroundProp

	if body == null:
		# A delivered prop with its own scene. Nothing to do — and not a warning,
		# because that is the shape a real server's catalogue has.
		return

	body.configure(prop.def)


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


## Drops an entity from the tick list when its prop goes.
##
## Connected to the spawner's own signal rather than checked per tick. `removed` is
## emitted BEFORE the node is freed, which is exactly so a listener holding a
## reference can let go while it still exists.
func _on_prop_removed(prop: DotPropInstance, _reason: StringName) -> void:
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
func _map_catalogue() -> DotMapCatalogue:
	var catalogue := DotMapCatalogue.new()

	var table := [
		[&"pg_lobby", "Playground", DotMapDef.KIND_SANDBOX, 1],
		[&"pg_surf_intro", "Surf: Introduction", DotMapDef.KIND_SURF, 2],
		[&"pg_bhop_intro", "Bhop: Introduction", DotMapDef.KIND_BHOP, 3],
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

	player.grav_gun = DotGravGun.new()
	player.grav_gun.spawner = props
	player.grav_gun.wielder = id

	players[id] = player
	_samples[id] = DotTimerSample.new()

	spawn_player(id)

	return player


func remove_player(id: StringName) -> void:
	if not players.has(id):
		return

	# Their rock-the-vote goes with them. Without it a server whose players trickle
	# away keeps their votes while the threshold falls with the player count, so a
	# map ends on the votes of people who are no longer there.
	maps.time_limit.unrock(id)

	# The prop spawner first: it may free nodes, and doing it after the player's own
	# teardown means a physics gun holding one of them is already gone.
	props.player_left(id)
	timers.remove_player(id)

	(players[id] as PlaygroundPlayer).queue_free()

	players.erase(id)
	_samples.erase(id)


## Puts a player at the current map's spawn for their track.
func spawn_player(id: StringName) -> void:
	var player: PlaygroundPlayer = players.get(id)

	if player == null:
		return

	var track := player.timer.track if player.timer != null else DotTimerTrack.MAIN
	var map := current_map_node()

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
	DotRegistry.unregister_instance(SERVICE, self)
