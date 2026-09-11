class_name PlaygroundWorldGen
extends RefCounted

## A generated sandbox: a pipeline, a document, and boxes extruded out of it.
##
## [b]This is the only map in the family that is not written down.[/b] Every other one —
## `pg_lobby`, `dm_atrium`, `bhop_g2g_stages` — is a `_build()` full of constants, which
## is the right shape for a level somebody designed. A sandbox is the one place where
## "somewhere new every time" is worth more than "somewhere good", because what a player
## does in it is build, and what they build is the level.
##
## [b]The generator produces a document and this class extrudes it.[/b] Two separate
## things on purpose, which is dot-procedural-generation's whole design:
##
## - the document is data, so a server and a client with the same seed produce the same
##   world and compare a fingerprint rather than a map;
## - the extrusion is this game's, because a grid becomes boxes differently in a sandbox
##   than it would in a top-down game;
## - and the validator refuses a map nobody could walk round **before** anything is built,
##   which is the difference between generation being a feature and being a source of
##   rounds nobody can finish.
##
## The seed is a cvar. That is not a debugging affordance — "play the map I played" is the
## single most-requested feature of every generated world, and a seed nobody can name is a
## world nobody can share.

const CHANNEL := "playground.worldgen"

## Metres per grid cell. A sandbox wants rooms a physics gun can work in.
const CELL := 6.0

## How high a wall is. Tall enough that a gravity gun cannot punt a crate over one by
## accident, low enough that the sun still reaches the floor.
const WALL_HEIGHT := 6.0

const FLOOR_Y := 0.0


## The pipeline. Rooms, corridors with loops, spawns, props, and a validator.
##
## [b]Every step's name is its random stream[/b], so adding one at the end cannot change
## what the ones before it produced — which is what makes a seed somebody shared keep
## meaning the same world after the next feature lands.
static func pipeline(width: int = 40, height: int = 40) -> DotProcGenPipeline:
	var p := DotProcGenPipeline.new()
	p.width = width
	p.height = height
	p.pipeline_name = &"pg_generated"
	# Ten seeds before giving up. A sandbox that fails to generate is a server that did
	# not change map, which an operator sees as a hang.
	p.max_attempts = 10

	var rooms := DotProcGenRooms.new()
	rooms.step_name = &"rooms"
	# Big leaves: a sandbox room wants space to build in, and a maze of cupboards is the
	# failure mode of every BSP generator whose minimum is set for a dungeon.
	rooms.min_leaf = 11
	rooms.min_rooms = 5
	rooms.margin = 0.15
	p.add(rooms)

	var corridors := DotProcGenConnect.new()
	corridors.step_name = &"corridors"
	# Three cells wide, which is about eighteen metres: a corridor a player can carry a
	# crate down without wedging it, and wide enough for two people to pass.
	corridors.corridor_width = 3
	# Loops on purpose. A spanning tree has exactly one route between any two rooms, so
	# every chase is a corridor and every retreat is the way you came.
	corridors.extra_loops = 4
	p.add(corridors)

	var spawn := DotProcGenMarkers.new()
	spawn.step_name = &"spawn"
	spawn.kind = &"spawn"
	spawn.placement = DotProcGenMarkers.Placement.ROOM_CENTRE
	spawn.count = 1
	p.add(spawn)

	var props := DotProcGenMarkers.new()
	props.step_name = &"props"
	props.kind = &"prop"
	props.placement = DotProcGenMarkers.Placement.SCATTERED
	props.count = 12
	# Far enough apart that two crates do not spawn inside each other, which in a game
	# with a physics gun is a pair that explodes apart on the first frame.
	props.min_separation = 4
	p.add(props)

	var check := DotProcGenValidate.new()
	check.step_name = &"reachable"
	check.from_kind = &"spawn"
	# Everything placed has to be reachable from the spawn, and the map has to be mostly
	# one piece rather than a thread of corridor to a far wing.
	check.min_connected_fraction = 0.6
	# Sealed pockets are filled in rather than failing the seed: a cave with its pockets
	# filled is a good cave, and one with them left in has rooms that exist for a
	# navigation mesh and not for a player.
	check.fill_unreachable = true
	p.add(check)

	return p


## Generates a document, taking the seed from a game's randomness when it has one.
##
## [param seed_source] is anything with `seed_for(name)` — dot-randomness' manager,
## duck-typed, so this file names no type from that addon and the generator still lands on
## the session's own seed rather than on one of its own.
static func generate(seed_value: int, seed_source: Object = null) -> DotResult:
	var p := pipeline()
	p.seed_source = seed_source
	var res := p.generate(seed_value)
	if not res.ok:
		return res.wrap("generating the sandbox")

	var doc := res.value as DotProcGenDoc
	DotLog.info(CHANNEL, "generated a sandbox", {
		"seed": int(doc.meta.get("seed", 0)),
		"attempt": int(doc.meta.get("attempt", 0)) + 1,
		"rooms": doc.rooms.size(),
		"fingerprint": str(doc.meta.get("fingerprint", "")).substr(0, 16),
	})
	return DotResult.success(doc)


## Turns a document into geometry under [param parent].
##
## [b]Walls are built as one box per RUN of solid cells, not one per cell.[/b] A 40 x 40
## map is 1,600 cells and about 900 of them are solid; a box each is 900 static bodies,
## 900 meshes and a physics broad phase that has to sort them every tick — on a game whose
## whole point is throwing rigid bodies around. Run-length merging takes it to a few
## dozen, and the geometry is identical.
static func build(parent: Node3D, doc: DotProcGenDoc) -> Dictionary:
	var built := {"walls": 0, "floor": 0, "props": [], "spawn": Vector3.ZERO}

	# The floor is one box. A sandbox has no holes in it -- the walls are what shape it --
	# so the floor is a single slab and every unwalkable cell is a wall standing on it.
	var extent := Vector3(float(doc.width) * CELL, 1.0, float(doc.height) * CELL)
	PlaygroundGeometry.box(
		parent,
		Vector3(extent.x * 0.5, FLOOR_Y - 0.5, extent.z * 0.5),
		extent,
		PlaygroundGeometry.COLOUR_FLOOR
	)
	built["floor"] = 1

	# Rows first, then whatever is left column-wise. Two passes rather than a proper
	# rectangle decomposition: the second pass only ever sees single cells the first one
	# could not merge, which on a room-and-corridor map is a handful.
	var merged := PackedByteArray()
	merged.resize(doc.width * doc.height)

	for y in range(doc.height):
		var x := 0
		while x < doc.width:
			if doc.at(x, y) != DotProcGenDoc.SOLID or merged[y * doc.width + x] == 1:
				x += 1
				continue
			var run := 0
			while x + run < doc.width and doc.at(x + run, y) == DotProcGenDoc.SOLID \
					and merged[y * doc.width + x + run] == 0:
				merged[y * doc.width + x + run] = 1
				run += 1
			_wall(parent, x, y, run, 1)
			built["walls"] = int(built["walls"]) + 1
			x += run

	for m in doc.markers:
		var cell: Vector2i = m.get("cell", Vector2i.ZERO)
		var at := Vector3(
			(float(cell.x) + 0.5) * CELL, FLOOR_Y, (float(cell.y) + 0.5) * CELL
		)
		match str(m.get("kind", "")):
			"spawn":
				# A metre up, and the reason is written down in this family's own notes:
				# a capsule that starts within a few units of a triangle seam is a coin
				# toss whichever way the collision backend rounds, and one map shipped a
				# spawn that fell through the floor from exactly that.
				built["spawn"] = at + Vector3(0.0, 1.5, 0.0)
			"prop":
				(built["props"] as Array).append(at + Vector3(0.0, 1.0, 0.0))
	return built


static func _wall(parent: Node3D, x: int, y: int, w: int, h: int) -> void:
	var size := Vector3(float(w) * CELL, WALL_HEIGHT, float(h) * CELL)
	var centre := Vector3(
		(float(x) + float(w) * 0.5) * CELL,
		FLOOR_Y + WALL_HEIGHT * 0.5,
		(float(y) + float(h) * 0.5) * CELL
	)
	PlaygroundGeometry.box(parent, centre, size, PlaygroundGeometry.COLOUR_PLATFORM)


## A one-line description for a console command and for the map's own notice.
static func describe(doc: DotProcGenDoc) -> String:
	return "seed %d, %d rooms, %d links, %s" % [
		int(doc.meta.get("seed", 0)),
		doc.rooms.size(),
		doc.links.size(),
		str(doc.meta.get("fingerprint", "")).substr(0, 12),
	]
