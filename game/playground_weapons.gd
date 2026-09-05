class_name PlaygroundWeapons
extends RefCounted

## The arsenal: what a player can hold, and how a script becomes a weapon.
##
## [b]Its own registry rather than a corner of the prop catalogue.[/b] dot-props'
## catalogue is "things you spawn into the world" and requires a `scene_path`, because
## that is what a spawn needs. A weapon is never spawned — it is held, and it has no
## body — so giving one a scene path to make it fit would be a lie that turns into
## "why does this crate have no collision". Three tabs in the menu, two systems
## underneath, and they are two for a reason.
##
## [b]A weapon is a script named by path, loaded and instantiated at equip time.[/b]
## That is the sandbox shape and it is also the only shape that survives delivery: a
## mounted dot-cloud pack's `class_name` globals are not registered in the host, so a
## weapon named by class could ship only inside the build. See [PlaygroundSpawnables]
## for the measurement.

const CHANNEL := "playground.weapons"

## Where the shipped weapons live. A delivered one points anywhere its pack is mounted.
const DIRECTORY := "res://game/weapons"


## Instantiates a weapon from its definition, or null with a reason logged.
##
## [b]Every failure is loud and none of them is a fallback.[/b] Handing back a base
## `PlaygroundWeapon` when a script will not load gives the player a weapon whose two
## buttons do nothing, which is indistinguishable from a weapon that is working and
## pointed at nothing.
static func make(def: PlaygroundWeaponDef) -> PlaygroundWeapon:
	if def == null:
		return null

	var valid := def.validate()

	if not valid.ok:
		DotLog.error(CHANNEL, "a weapon definition is not usable", {
			"why": valid.error.message
		})
		return null

	if not ResourceLoader.exists(def.script_path):
		DotLog.error(CHANNEL, "a weapon's script is not there", {
			"weapon": String(def.id), "script": def.script_path
		})
		return null

	var res: Resource = load(def.script_path)

	if not (res is GDScript):
		DotLog.error(CHANNEL, "a weapon's script is not a script", {
			"weapon": String(def.id), "script": def.script_path
		})
		return null

	var made: Variant = (res as GDScript).new()

	# Checked after construction rather than assumed. A script that is a valid
	# GDScript but extends the wrong thing constructs perfectly and then has none of
	# the methods the client calls — and the first symptom is a crash inside a mouse
	# handler, several frames from the catalogue entry that caused it.
	if not (made is PlaygroundWeapon):
		DotLog.error(CHANNEL, "a weapon's script is not a weapon", {
			"weapon": String(def.id),
			"script": def.script_path,
			"hint": "extend res://game/weapons/playground_weapon.gd",
		})
		return null

	return made as PlaygroundWeapon


## The weapons this build ships.
##
## Three, and each is a different shape of tool on purpose: one that creates, one that
## destroys, and one that only pushes. Between them they exercise everything the base
## offers — spawning against a budget, `may_act_on` and the host's ownership policy,
## and a walk over every prop in the world.
static func built_in() -> Array[PlaygroundWeaponDef]:
	var out: Array[PlaygroundWeaponDef] = []

	var launcher := PlaygroundWeaponDef.make(
		&"launcher", "Launcher", "%s/swep_launcher.gd" % DIRECTORY
	)
	launcher.description = "Fires whatever you have armed. Right click hurls it."
	launcher.category = &"toys"
	launcher.colour = Color(0.76, 0.62, 0.26)
	launcher.meta = {"speed": 26.0, "heavy_scale": 2.4, "muzzle": 2.0}
	out.append(launcher)

	var remover := PlaygroundWeaponDef.make(
		&"remover", "Remover", "%s/swep_remover.gd" % DIRECTORY
	)
	remover.description = "Deletes what you point at. Right click clears yours."
	remover.category = &"tools"
	remover.colour = Color(0.78, 0.34, 0.32)
	out.append(remover)

	var impulse := PlaygroundWeaponDef.make(
		&"impulse", "Impulse", "%s/swep_impulse.gd" % DIRECTORY
	)
	impulse.description = "Shoves everything nearby away. Right click pulls."
	impulse.category = &"toys"
	impulse.colour = Color(0.40, 0.66, 0.82)
	impulse.meta = {"radius": 9.0, "force": 900.0, "pull_scale": 0.55}
	out.append(impulse)

	return out


## The definition with this id, or null.
static func find(defs: Array[PlaygroundWeaponDef], id: StringName) -> PlaygroundWeaponDef:
	for def in defs:
		if def.id == id:
			return def

	return null


## The categories in a set of definitions, in a stable order.
static func categories(defs: Array[PlaygroundWeaponDef]) -> PackedStringArray:
	var seen := {}

	for def in defs:
		seen[String(def.category)] = true

	var out := PackedStringArray(seen.keys())
	out.sort()

	return out
