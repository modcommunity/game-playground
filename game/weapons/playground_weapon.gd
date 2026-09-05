class_name PlaygroundWeapon
extends DotPropTool

## The base every SWEP extends: two mouse buttons and a tick.
##
## [b]It extends [DotPropTool], which is most of the work.[/b] A weapon in a sandbox is
## a thing that points at props and does something to them, and that is exactly what
## `DotPropTool` is: it carries the spawner, the wielder, the reach, a `target()` that
## resolves a ray to a prop, and a `may_act_on()` that answers the ownership question
## the host decides rather than the tool. A physics gun and a gravity gun are the two
## dot-props ships; these are the game's own, and they are the same kind of object.
##
## [b]A tool is not a node and does not own a camera[/b] — dot-props' rule, kept. It is
## handed an origin and a direction, so the same weapon works for a player with a
## first-person camera, a bot, a replay being played back and a headless test, none of
## which have a viewport.
##
## [codeblock]
## extends "res://game/weapons/playground_weapon.gd"
##
## func _primary(space: Variant, origin: Vector3, aim: Vector3) -> DotResult:
##     return _launch(origin, aim, 30.0)
## [/codeblock]

## The game. Weapons that spawn need a catalogue and a budget, not just a spawner.
var game: Playground = null

## This weapon's row in the registry: its name, its tuning, its icon colour.
var def: PlaygroundWeaponDef = null

## The prop the spawn menu last armed.
##
## [b]Pushed in by the client rather than read off it.[/b] It is what lets one weapon
## follow what the player picked — the launcher fires whatever is armed — without the
## weapon knowing there is a client at all, which is the same reason it is handed an
## origin instead of a camera.
var armed: StringName = &""

## Simulated seconds since equipping. Not a wall clock, for the reason on
## [member DotPropSpawner.advance].
var age: float = 0.0


# --- Called by the client ---------------------------------------------------

func equip(p_game: Playground, p_def: PlaygroundWeaponDef) -> void:
	game = p_game
	def = p_def
	spawner = p_game.props if p_game != null else null
	age = 0.0
	_equip()


## Puts the weapon away. Anything it is holding is let go of here.
func holster() -> void:
	_holster()


func primary(space: Variant, origin: Vector3, aim: Vector3) -> DotResult:
	return _primary(space, origin, aim.normalized())


func secondary(space: Variant, origin: Vector3, aim: Vector3) -> DotResult:
	return _secondary(space, origin, aim.normalized())


func tick(space: Variant, origin: Vector3, aim: Vector3, delta: float) -> void:
	age += delta
	_tick(space, origin, aim.normalized(), delta)


# --- Subclass interface -----------------------------------------------------

func _equip() -> void:
	pass


func _holster() -> void:
	pass


func _primary(_space: Variant, _origin: Vector3, _aim: Vector3) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "This does nothing.")


func _secondary(_space: Variant, _origin: Vector3, _aim: Vector3) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "This does nothing.")


func _tick(_space: Variant, _origin: Vector3, _aim: Vector3, _delta: float) -> void:
	pass


# --- Helpers ----------------------------------------------------------------

## A tuning number from the definition, or [param fallback]. As [PlaygroundEntity.tune].
func tune(key: StringName, fallback: float) -> float:
	if def == null:
		return fallback

	var raw: Variant = def.meta.get(String(key), null)

	return float(raw) if raw is float or raw is int else fallback


## Spawns a prop in front of the muzzle and throws it along the aim.
##
## [b]The velocity is written after the spawn, not applied as an impulse.[/b] An
## impulse is divided by the mass — which is what makes a punt feel weighty and is
## exactly wrong here: a launcher whose boulder leaves at a fortieth of the speed of
## its ball is a launcher nobody can aim. A muzzle velocity is a muzzle velocity.
func launch(prop_id: StringName, origin: Vector3, aim: Vector3, speed: float) -> DotResult:
	if game == null or spawner == null:
		return DotResult.fail(DotError.CODE_STATE, "This weapon has no world.")

	var at := origin + aim * tune(&"muzzle", 2.0)
	var prop := spawner.spawn(prop_id, wielder, at)

	if prop == null:
		# The refusal reason has already gone to the player through the spawner's own
		# `refused` signal, which the HUD is listening to. Saying it again here would
		# put the same line on screen twice.
		return DotResult.fail(DotError.CODE_FORBIDDEN, "")

	var body := prop.body()

	if body != null:
		body.linear_velocity = aim * speed

	return DotResult.success(prop)


func describe() -> Dictionary:
	var out := super.describe()
	out["weapon"] = def.name_or_id() if def != null else "-"
	out["armed"] = String(armed)
	return out
