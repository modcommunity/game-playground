class_name PlaygroundSpawnables
extends RefCounted

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
const SCENE_PROP := "res://game/prop.tscn"

## The scene an entity is built into: a bare [RigidBody3D] whose script comes from the
## definition. Bare, because attaching one here would mean every entity replaced it.
const SCENE_ENTITY := "res://game/entity.tscn"

enum Kind {
	## A shape with a mass. No code.
	PROP,
	## A prop with a script attached at spawn, ticked by the simulation.
	ENTITY,
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
			"b8565d", 80.0, 4, {"speed": 5.0, "give_up_range": 40.0}],
		[&"npc_hopper", "Hopper", "npc_wanderer", Vector3(0.7, 0.9, 0.7),
			"6fae7a", 30.0, 2, {"speed": 2.5, "hop": 4.5, "turn_seconds": 1.2}],
		[&"turret_spinner", "Spinner", "npc_spinner", Vector3(1.6, 0.5, 1.6),
			"c9a227", 200.0, 3, {"rpm": 90.0, "shove": 9.0}],
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
			"script": "res://game/entities/%s.gd" % row[2],
			"shape": "box",
			"extent": [row[3].x, row[3].y, row[3].z],
			"colour": row[4],
		}

		for key in (row[7] as Dictionary):
			meta[key] = (row[7] as Dictionary)[key]

		entity.meta = meta
		out.add(entity)

	return out
