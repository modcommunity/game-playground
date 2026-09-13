extends Node

const Playground := preload("playground.gd")
const PlaygroundArena := preload("playground_arena.gd")
const PlaygroundPlayer := preload("playground_player.gd")

## The player-facing addons, stood up once and bound to the sandbox.
##
## [b]A sandbox is the loosest of the five games and the layer still earns its place.[/b]
## There is no match, no round and no win condition; there is a world people build in,
## a course in the corner with a timer on it, and a session that lasts as long as the
## server does. What the layer buys is the part a sandbox needs most and has least of:
## a record of who is here that survives them dropping out for a minute.
##
## So this stands up the same addons `ArenaPlayerStack` does and binds them to what the
## playground actually has:
##
## [codeblock]
## dot-physics  the SANDBOX layout and profile — held props, frozen props, a solver
##              that holds a stack, and an aggressive sleep threshold so two hundred
##              settled crates cost nothing
## dot-player   the roster, with a long reconnect window: a build takes hours
## dot-team     one playing side and a spectator side — free-for-all is ONE team
## dot-player-class  one class; what a player carries is dot-inventory's here
## dot-spawn    the map's start, as a site the richer selector can reason about
## dot-team's spectate half
## [/codeblock]
##
## [b]Why one team and not none.[/b] Free-for-all modelled as "no teams" makes every
## consumer branch on whether teams exist, and the branch nobody writes is the one that
## matters. One playing side with friendly fire on says the same thing and costs a
## consumer nothing — and it is what gives the spectator seat somewhere to be.

const CHANNEL := "playground.stack"

const SERVICE := &"playground_player_stack"

@export var register_service: bool = true

## Whether to apply a physics profile. Off on a client: the server's rate is what counts.
@export var apply_physics: bool = true

var game: Playground = null

var physics: DotPhysicsWorld = null
var roster: DotPlayerRoster = null
var teams: DotTeamRoster = null
var classes: DotPlayerClassManager = null

## The body metrics every player is drawn at. See [PlaygroundCharacter].
var characters: DotPlayerCharCatalogue = null
var spawns: DotSpawnDirector = null
var spectate: DotTeamSpectate = null

var _registered: bool = false

## Which map the sites in the director were read from. See [method _ensure_sites_current].
var _sites_from: StringName = &""

## The fight, when there is one. Assigned by [PlaygroundModule], like the spectate
## layer's and the downs layer's.
##
## [b]Not reached through the game, because it does not live there.[/b] `PlaygroundArena`
## is the module's — a sandbox is the thing that runs without it — so the stack is handed
## one or left with null, and null means "a sandbox", which is the answer that wants no
## spawn protection at all.
var arena: PlaygroundArena = null


func setup(p_game: Playground) -> DotResult:
	if p_game == null:
		return DotResult.fail(DotError.CODE_INVALID, "No game to bind to.")

	game = p_game

	var built := _build_physics()

	if not built.ok:
		return built

	_build_roster()
	_build_teams()
	_build_characters()
	_build_classes()
	_build_spawns()
	_build_spectate()

	game.player_added.connect(_on_player_added)
	game.player_removed.connect(_on_player_removed)
	game.map_ready.connect(_on_map_ready)

	if register_service:
		DotRegistry.register(
			DotRegistry.scoped_name(SERVICE, game.service_scope), self
		)
		_registered = true

	DotLog.info(CHANNEL, "player stack up", {"tick_rate": game.tick_rate})
	return DotResult.success(null)


func _exit_tree() -> void:
	if _registered:
		DotRegistry.unregister_instance(
			DotRegistry.scoped_name(SERVICE, game.service_scope), self
		)


# --- Building ---------------------------------------------------------------

## Builds the physics node, and applies the engine half of it only where that is wanted.
##
## [b]The LAYOUT is built on every instance, including a client that applies nothing.[/b]
## This used to return before creating the node at all when `apply_physics` was off, which
## left a client with no layout — and a collision layout is not a local preference, it is
## the numbers written into `collision_layer` on nodes both ends build. A server that put
## props on the prop bit while its clients left them on bit 0 would be two worlds with
## different collision matrices, agreeing only because nothing had ever read the layout.
##
## What `apply_physics` still gates is `setup()`, which writes ProjectSettings: the tick
## rate, gravity and damping. Those are the server's to decide.
func _build_physics() -> DotResult:
	physics = DotPhysicsWorld.new()
	physics.name = "Physics"
	# [b]The project's own numbers, not a preset's — and this is the one game in the
	# family where that is the right answer.[/b]
	#
	# Its rigid bodies are the content: props a player stacks, vehicles a player drives,
	# every one of them tuned by hand against whatever the project already had. A preset
	# is a set of decisions, and applying one retunes all of it at once. The symptom is
	# never "physics feels different": a net test measured a car doing -0.03 m/s that
	# should do six, because its traction was balanced against the old gravity, and then
	# a crate RISING out of a stack, because a stiffer contact bias pushed it out.
	#
	# The players are unaffected either way. DotFpsMotor carries its own gravity in
	# DotFpsTunables and never reads the engine's.
	#
	# What the layout below still buys, with none of that risk, is the naming: held and
	# frozen props stop being bit arithmetic at the call site.
	physics.profile = DotPhysicsProfile.from_project()

	# The one thing this game decides. The course in the corner is timed by dot-timer,
	# and a run set at one rate is not comparable with one set at another.
	physics.profile.tick_rate = game.tick_rate

	physics.layout = DotPhysicsLayout.sandbox_3d()
	physics.surfaces = DotPhysicsSurfaceSet.standard()
	physics.register_service = false
	physics.write_layer_names = false
	add_child(physics)

	# The layout alone, so `classify` answers on a client too.
	var built := physics.layout.build()

	if not built.ok:
		return built.wrap("The collision layout")

	if not apply_physics:
		return DotResult.success(null)

	return physics.setup().wrap("the playground's physics profile")


func _build_roster() -> void:
	roster = DotPlayerRoster.new()
	roster.name = "Roster"
	roster.authoritative = game.authoritative
	roster.register_service = false

	var config := DotPlayerConfig.new()
	config.tick_rate = game.tick_rate
	config.max_players = 32
	# Ten minutes. Somebody who has spent an hour building and drops out for a moment
	# should come back to their own props rather than to a stranger's slot.
	config.reconnect_window_sec = 600.0
	roster.config = config
	add_child(roster)


func _build_teams() -> void:
	teams = DotTeamRoster.new()
	teams.name = "Teams"
	teams.authoritative = game.authoritative
	teams.register_service = false
	teams.teams = DotTeamSet.free_for_all()
	teams.policy = DotTeamPolicy.free_for_all()
	teams.policy.tick_rate = game.tick_rate
	teams.alive_fn = _alive_of_key
	add_child(teams)

	var res := teams.setup()

	if not res.ok:
		DotLog.error(CHANNEL, "team roster", {"why": res.error.message})


## The character catalogue: how tall a player is, how wide, and where their eyes are.
##
## [b]`standard()` rather than a catalogue of this game's own[/b], because the sandbox has
## one body and the addon's own preset already describes it — and the numbers have to
## agree with `PlaygroundPlayer._tunables`' capsule, which is what `DotPlayerCharDef`
## exists to stop drifting from the collider.
func _build_characters() -> void:
	characters = DotPlayerCharCatalogue.standard()

	var res := characters.build()

	if not res.ok:
		DotLog.error(CHANNEL, "character catalogue", {"why": res.error.message})


## The body a player is drawn as.
func character() -> DotPlayerCharDef:
	return characters.fallback_for() if characters != null else null


func _build_classes() -> void:
	classes = DotPlayerClassManager.new()
	classes.name = "Classes"
	classes.authoritative = game.authoritative
	classes.register_service = false

	# One class. What a player is carrying is dot-inventory's question here, and what
	# they can build is the Q menu's; neither is a class, and modelling either as one
	# would put a sandbox's whole content model in a layer that cannot see it.
	classes.catalogue = DotPlayerClassCatalogue.single(100.0)
	classes.rules = DotPlayerClassRules.instant()
	classes.team_fn = func(key: String) -> StringName: return teams.team_of(key)
	classes.alive_fn = _alive_of_key
	add_child(classes)

	var res := classes.setup()

	if not res.ok:
		DotLog.error(CHANNEL, "class manager", {"why": res.error.message})


func _build_spawns() -> void:
	spawns = DotSpawnDirector.new()
	spawns.name = "Spawns"
	spawns.tick_rate = game.tick_rate
	spawns.register_service = false
	spawns.rules = DotSpawnRules.single_start()
	# The site whose track is the one the request asked for. The sandbox's course has a
	# main run and bonuses like any other, and without this the director would answer a
	# player who chose a bonus with the main start and be right by its own rules.
	spawns.conditions = [DotSpawnConditions.MetaMatchesRequest.new("track")]
	add_child(spawns)

	refresh_spawn_rules()
	refresh_spawns()


## Re-reads the map's start points. Call after a map change.
##
## One site per track: the playground's course has a main run and bonuses like any
## other, and the track is carried in the site's metadata so a mode that wants a
## specific one can ask with a condition.
func refresh_spawns() -> void:
	if spawns == null or game == null:
		return

	spawns.clear_sites()
	_sites_from = &""

	var map := game.current_map_node()

	if map == null:
		return

	_sites_from = game.maps.current.id if game.maps != null and game.maps.current != null else &""

	# Every track the map could have: the main run and up to eight bonuses. A map with
	# no bonus answers the origin for those, which is the skip below — reading
	# DotTimerTrack's own range rather than guessing a count is what keeps this right
	# when a map gains a ninth.
	for track in range(DotTimerTrack.MAIN, DotTimerTrack.COUNT):
		var at := map.spawn_for(track)

		if at.is_equal_approx(Vector3.ZERO):
			continue

		# [b]Radians in, because that is what a site holds.[/b] `spawn_yaw_for` answers
		# in degrees — it reads `DotTimerZone.destination_yaw`, which the zone painter
		# writes with `rad_to_deg` — and `DotSpawnSite.sample` builds
		# `Basis(Vector3.UP, yaw)`, which is radians. Storing one as the other put a
		# number 57 times too large into the field and nothing said so, because nothing
		# had ever called `sample()`: the site's own yaw had never been read.
		var site := DotSpawnSite.point(
			StringName("start_%d" % track), at, deg_to_rad(map.spawn_yaw_for(track))
		)
		site.meta = {"track": track}
		site.priority = 10 if track == DotTimerTrack.MAIN else 0
		site.id = StringName(DotTimerTrack.short_name_of(track))
		spawns.add_site(site)

	DotLog.debug(CHANNEL, "start sites", {"count": spawns.sites().size()})


func _build_spectate() -> void:
	spectate = DotTeamSpectate.new()
	spectate.name = "Spectate"
	spectate.teams = teams
	spectate.register_service = false
	spectate.rules = DotTeamSpectateRules.open()
	spectate.alive_fn = _alive_of_key
	spectate.pose_fn = _pose_of_key
	# No rounds on a timer server, so nothing is ever "mid-round" and the end-of-round
	# relaxation is permanently on. Said explicitly rather than left to the default,
	# because the default is the cautious one and would be wrong here.
	spectate.round_live_fn = func() -> bool: return false

	add_child(spectate)

	var res := spectate.setup()

	if not res.ok:
		DotLog.error(CHANNEL, "team spectate", {"why": res.error.message})


# --- Keeping in step --------------------------------------------------------

func _on_player_added(id: StringName) -> void:
	if not game.authoritative:
		return

	var player: PlaygroundPlayer = game.players.get(id)

	if player == null:
		return

	var key := String(id)
	var res := roster.join(key, player.display_name, 0, 0)

	if not res.ok:
		DotLog.warn(CHANNEL, "player not added to the roster", {
			"key": key, "why": res.error.message
		})
		return

	var _team := teams.add(key, 0)
	var _class := classes.add(key)
	# A timer server has no death: somebody who exists is in the world, and a roster
	# that never said so would report an empty session to every consumer.
	var _alive := roster.set_alive(key, true)


func _on_player_removed(id: StringName) -> void:
	var key := String(id)

	if not roster.authoritative:
		return

	spectate.end(key)
	classes.remove(key)
	var _left := teams.remove(key)
	var _held := roster.note_disconnected(key, 0)


func _on_map_ready(_map: DotMapDef) -> void:
	# [b]The level onto the layout's `world` layer.[/b] Built geometry arrives as
	# `StaticBody3D`s on Godot's default layer 1 masking layer 1 — so a projectile or a
	# prop could not hit the map, and the layer names dot-physics writes into the
	# inspector described a layout nothing in the world actually followed.
	var classified := classify_tree(game.current_map_node(), &"world")

	if classified > 0:
		DotLog.debug(CHANNEL, "level classified", {"bodies": classified})

	# The arena layer can be switched under a live server, and a map change is the
	# coarsest thing that reliably follows it.
	refresh_spawn_rules()
	refresh_spawns()


## One tick of what this node runs on its own.
func tick(current_tick: int) -> void:
	if not game.authoritative:
		return

	var _dropped := roster.advance(current_tick)
	spectate.advance(current_tick)


# --- Reading ----------------------------------------------------------------

## Rebuilds the sites when they came from a map that is no longer loaded.
##
## [b]Signal order.[/b] A map change emits `map_ready` and respawns everybody, and nothing
## orders this node's handler before the respawn. Losing that race means the director
## still holds the previous map's starts and answers with a real site, a real transform
## and a successful `DotResult` — for a map nobody is standing in. game-g2gfast shipped
## exactly that for the length of one debugging session; its surf section found it as a
## bot that never left the ground.
func _ensure_sites_current() -> void:
	if spawns == null or game == null or game.maps == null or game.maps.current == null:
		return

	if _sites_from != game.maps.current.id:
		refresh_spawns()


## Where a player should start, and this is the live path.
##
## [b]It was offered beside `Playground.spawn_player` and called by nothing[/b], so the
## director was built, given every track's start and asked nothing for the life of the
## server. `spawn_player` goes through here now and falls back to the map's own start —
## the sites are still the map's, and what the director adds is the choice among them,
## the per-site cooldown and, with the arena layer on, the protection window
## [DotSpawnProtection] only ever grants from inside [method DotSpawnDirector.choose].
func choose_start(id: StringName, track: int = DotTimerTrack.MAIN) -> DotResult:
	_ensure_sites_current()

	var key := String(id)
	return spawns.choose(DotSpawnRequest.make(
		key, teams.team_of(key), classes.class_of(key), game.current_tick(),
		{"track": track}
	))


## Whether spawn protection should stop [param attacker] hurting [param victim].
##
## Only ever true while the arena layer is on: a sandbox has nothing to be protected
## from, and [method refresh_spawn_rules] leaves the window shut until there is.
func blocks_damage(
	attacker_key: String, victim_key: String, tick: int, world_damage: bool = false
) -> bool:
	if spawns == null or spawns.protection == null:
		return false

	return spawns.protection.blocks(attacker_key, victim_key, tick, world_damage)


## Opens or closes the protection window according to whether anybody can shoot.
##
## The arena layer's own match rules carry the number. A second copy written here would
## be the disagreement game-arena had between its effect table and its modes.
func refresh_spawn_rules() -> void:
	if spawns == null or game == null:
		return

	var fighting := arena != null and arena.enabled
	spawns.rules.protection_sec = (
		arena.match_node.rules.spawn_protection_sec
		if fighting and arena.match_node != null else 0.0
	)
	# Off for game-arena's reason: it is what a fight wants and it can only be revoked in
	# one of the two records of it. See `ArenaPlayerStack.refresh_spawn_rules`.
	spawns.rules.protection_breaks_on_attack = false



## The dot-spectate team number for [param key], derived from the side they are on.
##
## [b]An index, not a hash, and zero means "no side".[/b] dot-spectate keys teams by
## [code]int[/code] and treats 0 as no team at all — two entities with no team are never
## team-mates, so a free-for-all cannot accidentally become a truce. The playing sides
## are numbered from 1 in the order the set declares them, which is the same rule
## `DotTeamRoster._match_team_id` uses to push an assignment down into dot-match.
##
## Somebody unassigned, spectating, or not in the roster at all gets 0. That is the part
## a hardcoded `return 1` got wrong: a spectator read as a team-mate of everybody.
func team_index_of(key: String) -> int:
	if teams == null:
		return 0

	var side := teams.team_of(key)

	if side == &"" or not teams.teams.is_playing(side):
		return 0

	return teams.teams.playing_ids().find(side) + 1



## Puts [param node] on the layout's [param layer_id] layer, with that layer's mask.
##
## [b]The half of dot-physics that was never used.[/b] The layout was assigned and its
## layer names were written into ProjectSettings for the inspector to show — and every
## body in this game stayed on Godot's default layer 1 with mask 1, so the inspector
## labelled layers nothing followed. Naming a layer is only half of a layout.
func classify(node: Node, layer_id: StringName) -> DotResult:
	if physics == null or physics.layout == null:
		return DotResult.fail(DotError.CODE_STATE, "No collision layout.")

	return physics.classify(node, layer_id)


## Puts every collision object under [param root] on [param layer_id]. Returns how many.
##
## One call rather than a call per body: the geometry is built by a class that describes
## boxes, and a physics decision belongs here rather than inside that description. Nodes
## that are not collision objects are skipped, so a whole scene can be handed in.
func classify_tree(root: Node, layer_id: StringName) -> int:
	if root == null or physics == null or physics.layout == null:
		return 0

	var done := 0

	if root is CollisionObject3D or root is CollisionObject2D:
		if classify(root, layer_id).ok:
			done += 1

	for child in root.get_children():
		done += classify_tree(child, layer_id)

	return done


## The mask a player's movement sweeps against, out of the layout.
##
## [b]`DotFpsTunables.collision_mask` defaults to 1 and no game here had ever set it.[/b]
## One is correct only while everything is on bit 0, which is the state a layout exists to
## end — so the moment props moved to their own layer, a mask of 1 was a player who walks
## through every crate in the map, and nothing would have said so: a sweep that hits
## nothing is a sweep, not an error.
func player_collision_mask() -> int:
	if physics == null or physics.layout == null:
		return 1

	return physics.layout.collision_mask(&"player")



## Writes a player's class numbers onto their health and their movement.
##
## [b]The class document reached nothing at all before this.[/b] `DotPlayerClassDef`
## carries `max_health`, `max_armour`, regeneration, a move-speed scale, a jump scale and
## a mass; the manager decided who was what and every one of those numbers was read by
## nobody. A catalogue a server can validate is only half of a class system — the other
## half is the spawn where it lands.
##
## [b]Idempotent, because the scales multiply.[/b] Applying one to tunables that already
## carry it compounds: 0.8 twice is 0.64, and a player who respawned four times would be
## at 0.41 of the speed with every number looking deliberate. The base handed to
## `DotPlayerClassApply.to_movement` is the untouched one, which makes a respawn safe.
##
## This game ships one class, so today it changes nothing visible — which is exactly when
## a mechanism is worth wiring, because a mode that swaps the catalogue is then a
## catalogue swap rather than a catalogue swap plus finding out why nothing happened.
func apply_class_numbers(key: String, health: Object, tunables: Object, base: Object) -> void:
	if classes == null:
		return

	var def := classes.def_of(key)

	if def == null:
		return

	# Not reset to full: the caller's own spawn path resets health, and two resets on one
	# spawn is one of them undoing the other's protection window.
	var _h := DotPlayerClassApply.to_health(def, health)
	var _m := DotPlayerClassApply.to_movement(def, tunables, base)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("--- player stack")

	if physics != null:
		out.append_array(physics.describe_lines())

	out.append_array(roster.describe_lines())
	out.append_array(teams.describe_lines())
	out.append_array(spawns.describe_lines())
	out.append_array(spectate.describe_lines())
	return out


func describe() -> Dictionary:
	return {
		"players": roster.count(),
		"connected": roster.connected_count(),
		"starts": spawns.sites().size(),
		"viewers": spectate.viewers().size(),
	}


# --- The callables the addons are given -------------------------------------

func _alive_of_key(key: String) -> bool:
	return game.players.has(StringName(key))


func _pose_of_key(key: String) -> Transform3D:
	var player: PlaygroundPlayer = game.players.get(StringName(key))

	if player == null or player.controller == null:
		return Transform3D.IDENTITY

	return player.controller.eye_transform()
