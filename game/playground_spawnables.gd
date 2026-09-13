extends RefCounted

const PlaygroundPaths := preload("playground_paths.gd")

const PlaygroundVehicles := preload("playground_vehicles.gd")

## Everything this build can put in the world, and what kind of thing each one is.
##
## [b]A prop is inert and an entity has a script.[/b] That is the sandbox's own
## division and it is the right one: a crate is a shape with a mass, and a thing that
## walks about needs code. dot-props does not know the difference and does not need
## to — it instantiates a scene, places it, and counts it against a budget — so the
## difference lives in [member DotPropDef.meta] and is applied by [Playground] on
## spawn.
##
## [codeblock]
## { "kind": "entity", "script": "res://game/entities/npc_wanderer.gd" }
## [/codeblock]
##
## [b]The script is named by PATH, and that is not a style choice.[/b] A game
## delivered through dot-cloud is a mounted `.pck`, and **a mounted pack's
## `class_name` globals are not registered in the host** — measured, and written down
## in the family's own CLAUDE.md. So every cross-file type reference inside a pack
## fails to compile and the pack's scripts are dead, while `preload("res://x.gd")` and
## `extends "res://x.gd"` both work. A catalogue that named a class could therefore
## only ever ship inside the build. Naming a path is what makes an entity deliverable,
## and it is why the entities here `extends "res://game/entities/playground_entity.gd"`
## rather than `extends PlaygroundEntity` — they are the template a pack copies, so
## they are written the way a pack has to be.

const CHANNEL := "playground.spawnables"

## The scene an inert prop is built into. Carries [PlaygroundProp] already.
static var SCENE_PROP := PlaygroundPaths.rebase("res://game/prop.tscn")

## The scene an entity is built into: a bare [RigidBody3D] whose script comes from the
## definition. Bare, because attaching one here would mean every entity replaced it.
static var SCENE_ENTITY := PlaygroundPaths.rebase("res://game/entity.tscn")

enum Kind {
	## A shape with a mass. No code.
	PROP,
	## A prop with a script attached at spawn, ticked by the simulation.
	ENTITY,
	## A prop that is also a [DotVehicleInstance]: it has seats and it drives.
	##
	## [b]Still a prop, and that is the decision.[/b] It counts against the same budget,
	## it is on the same undo stack, it goes when its owner leaves, and a gravity gun can
	## punt it — because a car you cannot punt is not a sandbox car. What being a vehicle
	## adds is a chassis and the handover, and both are dot-vehicle's.
	VEHICLE,
}


## What kind of thing a definition describes. Anything unrecognised is a prop.
##
## Defaulting to PROP rather than refusing: a catalogue written for an older build, or
## by an operator who has not heard of entities, is a catalogue of props — which is
## both true and the safe reading, because the failure mode of guessing "entity" is a
## script path that does not exist.
static func kind_of(def: DotPropDef) -> Kind:
	if def == null:
		return Kind.PROP

	match str(def.meta.get("kind", "prop")).to_lower():
		"entity", "npc":
			return Kind.ENTITY
		"vehicle":
			return Kind.VEHICLE
		_:
			return Kind.PROP


## The script an entity runs, or empty.
static func script_of(def: DotPropDef) -> String:
	return str(def.meta.get("script", "")) if def != null else ""


## Loads an entity's script, or null with a reason logged.
##
## [b]Every failure here is loud.[/b] A script that does not load leaves a body that
## sits there being a crate, which is indistinguishable from an NPC that has nothing
## to do — and "the NPC does not move" would send somebody to the movement code.
static func load_script(def: DotPropDef) -> GDScript:
	var path := script_of(def)

	if path == "":
		DotLog.error(CHANNEL, "an entity has no script", {"entity": String(def.id)})
		return null

	if not ResourceLoader.exists(path):
		DotLog.error(CHANNEL, "an entity's script is not there", {
			"entity": String(def.id), "script": path
		})
		return null

	var res: Resource = load(path)

	if not (res is GDScript):
		DotLog.error(CHANNEL, "an entity's script is not a script", {
			"entity": String(def.id), "script": path
		})
		return null

	return res as GDScript


# --- The built-in catalogue -------------------------------------------------

## Everything this build ships: fourteen props and four entities.
##
## [b]Enough to build something, which is the point of a sandbox.[/b] Four props are a
## demonstration; a plank, a panel, a beam and a pillar are a set somebody can make a
## house out of, and the spawn menu needs categories to be worth having at all.
##
## Every prop is [code]res://game/prop.tscn[/code] and every entity is
## [code]res://game/entity.tscn[/code]; what differs is the definition. See
## [PlaygroundProp] for what `meta` means and why it is done that way.
##
## [b]The masses are the interesting column.[/b] They are what a physics gun's
## `grab_mass_limit` is checked against and what a gravity gun's punt is divided by, so
## a beach ball that is bigger than a boulder and a fortieth of its weight is the one
## entry that proves both tools read it.
static func catalogue() -> DotPropCatalogue:
	var out := DotPropCatalogue.new()

	# id, name, category, shape, extent, colour, mass kg, cost, size
	var props := [
		[&"plank", "Plank", &"construction", "box", Vector3(3.0, 0.15, 0.6),
			"c9a227", 30.0, 1, DotPropDef.Size.SMALL],
		[&"beam", "Beam", &"construction", "box", Vector3(6.0, 0.4, 0.4),
			"8a6a3a", 80.0, 2, DotPropDef.Size.MEDIUM],
		[&"panel", "Panel", &"construction", "box", Vector3(4.0, 0.1, 4.0),
			"6f7480", 60.0, 2, DotPropDef.Size.MEDIUM],
		[&"slab", "Slab", &"construction", "box", Vector3(6.0, 0.6, 6.0),
			"4a4e57", 400.0, 4, DotPropDef.Size.LARGE],
		[&"pillar", "Pillar", &"construction", "cylinder", Vector3(1.0, 4.0, 1.0),
			"7d8189", 120.0, 2, DotPropDef.Size.MEDIUM],
		[&"platform", "Platform", &"construction", "box", Vector3(4.0, 0.4, 4.0),
			"46586a", 300.0, 3, DotPropDef.Size.LARGE],

		[&"crate", "Crate", &"containers", "box", Vector3(1.0, 1.0, 1.0),
			"b8873f", 20.0, 1, DotPropDef.Size.SMALL],
		[&"crate_large", "Large crate", &"containers", "box",
			Vector3(2.0, 2.0, 2.0), "9c7134", 90.0, 2, DotPropDef.Size.MEDIUM],
		[&"barrel", "Barrel", &"containers", "cylinder", Vector3(1.0, 1.4, 1.0),
			"3f6a55", 40.0, 1, DotPropDef.Size.SMALL],
		[&"can", "Can", &"containers", "cylinder", Vector3(0.4, 0.5, 0.4),
			"9aa3ad", 4.0, 1, DotPropDef.Size.TINY],

		[&"ball", "Ball", &"toys", "sphere", Vector3(1.0, 1.0, 1.0),
			"c25b4a", 8.0, 1, DotPropDef.Size.TINY],
		[&"beach_ball", "Beach ball", &"toys", "sphere", Vector3(2.4, 2.4, 2.4),
			"e0c14a", 2.0, 1, DotPropDef.Size.SMALL],
		[&"boulder", "Boulder", &"toys", "sphere", Vector3(3.0, 3.0, 3.0),
			"5b5750", 900.0, 3, DotPropDef.Size.LARGE],
		[&"die", "Die", &"toys", "box", Vector3(0.8, 0.8, 0.8),
			"ddd6c8", 12.0, 1, DotPropDef.Size.TINY],
	]

	for row in props:
		var prop := DotPropDef.make(row[0], SCENE_PROP)
		prop.display_name = row[1]
		prop.category = row[2]
		prop.mass = row[6]
		prop.cost = row[7]
		prop.size = row[8]
		prop.meta = {
			"shape": row[3],
			"extent": [row[4].x, row[4].y, row[4].z],
			"colour": row[5],
		}
		out.add(prop)

	# id, name, script, extent, colour, mass kg, cost, meta
	#
	# Entities cost more than props of the same size on purpose: each one runs a
	# script every tick and a budget counted only in physics would let a player fill
	# a server with things that are cheap to simulate and expensive to think.
	var entities := [
		[&"npc_wanderer", "Wanderer", "npc_wanderer", Vector3(0.8, 1.7, 0.8),
			"5d8fb8", 70.0, 3, {}],
		[&"npc_chaser", "Chaser", "npc_chaser", Vector3(0.9, 1.8, 0.9),
			"b8565d", 80.0, 4,
			{
				"speed": 5.0,
				# The perception envelope, read by dot-npc through
				# `PlaygroundEntity._make_npc`. `sight` replaced a `give_up_range` that
				# the chaser applied by hand: giving up is now what happens when a
				# target leaves the envelope and the commitment grace expires, which
				# also gets the hysteresis and the memory that the hand-rolled version
				# never had.
				"sight": 40.0,
				"sight_angle": 150.0,
				"hearing": 14.0,
			}],
		[&"npc_hopper", "Hopper", "npc_wanderer", Vector3(0.7, 0.9, 0.7),
			"6fae7a", 30.0, 2, {"speed": 2.5, "hop": 4.5, "turn_seconds": 1.2}],
		[&"turret_spinner", "Spinner", "npc_spinner", Vector3(1.6, 0.5, 1.6),
			"c9a227", 200.0, 3, {"rpm": 90.0, "shove": 9.0}],
		# The same NPC as `npc_chaser`, with a **decision** instead of an `if`: dot-npc-ai's
		# state machine and the arena shooters' characteristics table. Both are in the catalogue
		# deliberately — the cheap one is for filling a room with and the expensive one is
		# for the arena, and keeping both is the only honest way to say what the addon
		# actually bought. `skill` is a per-NPC character rather than a server difficulty,
		# which is dot-npc-ai's whole claim.
		[&"npc_hunter", "Hunter", "npc_hunter", Vector3(0.9, 1.8, 0.9),
			"c05a9a", 85.0, 6,
			{
				"speed": 5.4,
				"skill": "normal",
				"sight": 45.0,
				"sight_angle": 140.0,
				"hearing": 16.0,
				"give_up_seconds": 3.0,
			}],
		[&"npc_hunter_hard", "Hunter (hard)", "npc_hunter", Vector3(0.9, 1.8, 0.9),
			"e0483f", 85.0, 8,
			{
				"speed": 6.2,
				"skill": "hard",
				"sight": 55.0,
				"sight_angle": 160.0,
				"hearing": 20.0,
				"give_up_seconds": 4.5,
			}],
	]

	for row in entities:
		var entity := DotPropDef.make(row[0], SCENE_ENTITY)
		entity.display_name = row[1]
		entity.category = &"entities"
		entity.mass = row[5]
		entity.cost = row[6]
		entity.size = DotPropDef.Size.MEDIUM

		# `meta` is assembled rather than assigned from the row, so an entity's own
		# settings and the fields every spawnable has cannot collide by accident: a
		# tuning key called "extent" would otherwise silently resize the body.
		var meta := {
			"kind": "entity",
			"script": PlaygroundPaths.rebase("res://game/entities/%s.gd") % row[2],
			"shape": "box",
			"extent": [row[3].x, row[3].y, row[3].z],
			"colour": row[4],
		}

		for key in (row[7] as Dictionary):
			meta[key] = (row[7] as Dictionary)[key]

		entity.meta = meta
		out.add(entity)

	for vehicle in PlaygroundVehicles.catalogue().vehicles:
		out.add(_vehicle_prop(vehicle))

	return out


## The prop definition a vehicle is spawned through.
##
## [b]Derived from the vehicle definition, never written twice.[/b] It is the same
## "one description, three representations" rule the maps follow: the mass a physics gun
## checks and the mass the chassis puts on the rigid body are the SAME number, read from
## the tunables, so a catalogue saying 620 kg over a chassis saying 900 is a state this
## build cannot reach. Two hand-kept copies is exactly the shape that gave dot-props a
## prop a gun refused for being too heavy and a gravity gun threw like a beach ball.
static func _vehicle_prop(vehicle: DotVehicleDef) -> DotPropDef:
	var def := DotPropDef.make(vehicle.id, PlaygroundVehicles.SCENE)
	def.display_name = vehicle.name_or_id()
	def.category = &"vehicles"
	def.mass = vehicle.tuning().mass
	def.cost = vehicle.cost
	def.size = DotPropDef.Size.LARGE

	var meta := {
		"kind": "vehicle",
		"vehicle": String(vehicle.id),
		"shape": "box",
	}

	# Assembled rather than assigned, exactly as an entity's is: the vehicle's own
	# fields — extent, colour, the wheel geometry — come across, and the three keys
	# above cannot be overwritten by one of them by accident.
	for key in vehicle.meta:
		if not meta.has(key):
			meta[key] = vehicle.meta[key]

	def.meta = meta
	return def
