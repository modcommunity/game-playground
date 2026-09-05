extends "res://game/weapons/playground_weapon.gd"

## Fires whatever the spawn menu has armed. Left click lobs it, right click hurls it.
##
## Extends a PATH rather than a class, like every entity here: it is the shape a
## weapon delivered in a dot-cloud pack must have, because a mounted pack's
## `class_name` globals are not registered in the host.
##
## [b]It fires the armed prop rather than a projectile of its own.[/b] That is the one
## design decision in the file and it is what makes the weapon worth having: the menu
## already knows what the player picked, so a launcher that ignored it would need its
## own second list of ammunition and a second way to choose from it. Arm a beach ball
## and it is a party; arm a boulder and it is a siege engine, and the difference is
## free because the mass is already on the definition.

## What it fires when nothing is armed. A ball, because it is the one prop in the
## catalogue that is obviously ammunition.
const FALLBACK := &"ball"


func _primary(_space: Variant, origin: Vector3, aim: Vector3) -> DotResult:
	return launch(_ammunition(), origin, aim, tune(&"speed", 26.0))


func _secondary(_space: Variant, origin: Vector3, aim: Vector3) -> DotResult:
	# Same prop, much faster, and up a little so a heavy one carries rather than
	# ploughing into the floor two metres away.
	return launch(
		_ammunition(),
		origin,
		(aim + Vector3.UP * tune(&"loft", 0.12)).normalized(),
		tune(&"speed", 26.0) * tune(&"heavy_scale", 2.4)
	)


## The armed prop, if the catalogue still has it.
##
## Checked rather than trusted: a map change can swap the catalogue underneath a
## player who armed something the new one does not offer, and a spawn of a prop that
## is not there is refused with "no such prop" — which reads as the weapon being
## broken rather than as the ammunition being gone.
func _ammunition() -> StringName:
	if armed == &"" or game == null or game.props.catalogue == null:
		return FALLBACK

	return armed if game.props.catalogue.has(armed) else FALLBACK
