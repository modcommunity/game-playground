extends "../game/playground_map.gd"

const PlaygroundGeometry := preload("../game/playground_geometry.gd")
const PlaygroundWorldGen := preload("../game/playground_worldgen.gd")

## `pg_generated` — the sandbox nobody wrote down.
##
## [b]Every other map in this family is a `_build()` full of constants, and that is the
## right shape for a level somebody designed.[/b] This one is the exception, and the
## argument for it is specific rather than general: a sandbox's content is what the
## players build in it, so "somewhere new" is worth more here than "somewhere good" — and
## it is the one map where a layout nobody has memorised is a feature.
##
## It is also the only place in the family where the generator, the validator and the
## seed all have to work together to produce something a person can actually walk round:
##
## - **the pipeline is deterministic**, so a seed is a map and two machines agree;
## - **the validator refuses a map nobody could cross** and the pipeline retries on a new
##   seed, which is what stops "generated" meaning "sometimes broken";
## - **the seed is a cvar**, because "play the map I played" is the single most-requested
##   feature of every generated world and a seed nobody can name is a world nobody can
##   share.
##
## There is deliberately no timer course on it. A generated jump course would be a course
## nobody could learn and a record nobody could beat, which is the opposite of what
## dot-timer is for — and `pg_lobby` already proves a sandbox map can carry one.

## The seed this map was built from. Set by [Playground] out of `pg_seed` before the
## scene is added, so that a map change with a chosen seed produces the chosen map.
var seed_value: int = 0

## Anything with `seed_for(name)`. dot-randomness' manager, duck-typed.
var seed_source: Object = null

## The document that was generated, for a console command and for the suite.
var document: DotProcGenDoc = null

## Where the generator put things worth putting a prop on.
var prop_points: Array[Vector3] = []


## Whether anything has been built yet.
##
## [b]This map does not build itself in `_ready`, which every other one does.[/b] A
## generated map needs a seed, and dot-map's loader instantiates a scene and adds it --
## there is no moment between those two where anything could hand one over. So `_ready`
## does nothing and [Playground] calls [method configure] from its `map_changed` handler,
## before it spawns anybody.
##
## The alternative was a static holding the pending seed, which is the shape this family
## has a rule against: a second server in the same process would read the first one's.
var _built := false


func _ready() -> void:
	# Deliberately not `_build()`. See `_built` above.
	pass


## Gives this map its seed and builds it. Idempotent.
func configure(p_seed: int, p_source: Object = null) -> void:
	if _built:
		return
	seed_value = p_seed
	seed_source = p_source
	_built = true
	_build()


func _build() -> void:
	PlaygroundGeometry.sun(self)

	# A fallback first, so a failed generation still leaves somewhere to stand rather
	# than dropping the player into nothing. A generated map that fails is rare -- ten
	# seeds -- and "rare" is exactly when nobody has a fallback ready.
	fallback_spawn = Vector3(120.0, 2.0, 120.0)

	var res := PlaygroundWorldGen.generate(seed_value, seed_source)

	if not res.ok:
		# Refused rather than half-built. A partially generated sandbox is a room with no
		# way out, which is worse than an empty plate -- and the plate is what a player
		# gets, with the reason said out loud.
		DotLog.warn(
			"playground.map",
			"the sandbox could not be generated; falling back to a plain plate",
			{"why": res.error.message}
		)
		_plain_plate()
		return

	document = res.value as DotProcGenDoc
	var built := PlaygroundWorldGen.build(self, document)

	fallback_spawn = built["spawn"]
	prop_points.assign(built["props"])

	DotLog.info("playground.map", "pg_generated", {
		"what": PlaygroundWorldGen.describe(document),
		"walls": int(built["walls"]),
		"props": prop_points.size(),
	})


## What a generation failure leaves behind: somewhere flat, with walls.
func _plain_plate() -> void:
	const SIZE := 240.0
	PlaygroundGeometry.box(
		self,
		Vector3(SIZE * 0.5, -0.5, SIZE * 0.5),
		Vector3(SIZE, 1.0, SIZE),
		PlaygroundGeometry.COLOUR_FLOOR
	)
	fallback_spawn = Vector3(SIZE * 0.5, 1.5, SIZE * 0.5)


## No zones at all, and that is the point rather than an omission.
##
## A generated jump course is a course nobody can learn and a record nobody can beat.
## `pg_lobby` carries the timer; this map carries the sandbox.
func timer_zones() -> DotTimerZoneSet:
	return DotTimerZoneSet.new()


func spawn_for(_track: int) -> Vector3:
	return fallback_spawn
