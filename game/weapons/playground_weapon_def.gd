class_name PlaygroundWeaponDef
extends RefCounted

## One thing a player can hold, as a document rather than as a class.
##
## [b]Deliberately not a [DotPropDef].[/b] dot-props' catalogue is "things you spawn
## into the world", and it requires a `scene_path` because that is what a spawn needs.
## A weapon is never spawned — it is held, it has no body, and giving it a scene path
## so it would fit in a catalogue it does not belong in is exactly the sort of lie that
## turns into "why does this crate have no collision".
##
## So weapons have their own small registry, and the spawn menu shows both. The
## division a player sees — props, entities, weapons — is three tabs; the division
## underneath is two systems, and they are different systems for a real reason.
##
## [b]The script is a path, like an entity's.[/b] A mounted dot-cloud pack's
## `class_name` globals are not registered in the host, so a weapon named by class
## could only ever ship inside the build. See [PlaygroundSpawnables].

## Stable id. What the menu emits and what a console command names.
var id: StringName = &""

var display_name: String = ""

## One line, shown under the name in the menu. What it does, not how.
var description: String = ""

## The script, by path. Must extend `res://game/weapons/playground_weapon.gd`.
var script_path: String = ""

## Menu grouping, so a large arsenal is navigable.
var category: StringName = &"tools"

## What its generated icon is tinted. This project ships no art; see [PlaygroundIcons].
var colour: Color = Color(0.62, 0.68, 0.78)

## Anything the weapon's own script reads. Tuning lives here, not in the script, so
## one script can serve several entries — the same argument as [DotPropDef.meta].
var meta: Dictionary = {}


static func make(
	p_id: StringName, p_name: String, p_script: String
) -> PlaygroundWeaponDef:
	var def := PlaygroundWeaponDef.new()
	def.id = p_id
	def.display_name = p_name
	def.script_path = p_script
	return def


func name_or_id() -> String:
	return display_name if display_name != "" else String(id)


func validate() -> DotResult:
	if id == &"":
		return DotResult.fail(DotError.CODE_INVALID, "A weapon needs an id.")

	if script_path == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "A weapon needs a script.", String(id)
		)

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"id": String(id),
		"name": name_or_id(),
		"script": script_path,
		"category": String(category),
	}
