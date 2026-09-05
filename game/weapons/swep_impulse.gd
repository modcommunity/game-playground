extends "res://game/weapons/playground_weapon.gd"

## A shockwave. Left click shoves everything nearby away, right click pulls it in.
##
## Extends a PATH rather than a class, for the reason in `swep_launcher.gd`.
##
## [b]An impulse, not a velocity, and that is what makes it feel like it has weight.[/b]
## The solver divides an impulse by the mass, so a beach ball leaves at forty times a
## boulder's speed for the same push — free, and exactly what a shockwave should do.
## `DotGravGun.punt` makes the same choice for the same reason; `PlaygroundWeapon.launch`
## deliberately makes the opposite one, because a launcher is aimed and a blast is not.
##
## [b]It walks the spawner's own list rather than casting a shape.[/b] The spawner
## already knows every prop in the world, so this is a loop over a dictionary instead
## of a physics query per click — and it means the blast touches exactly the set a
## physics gun could, which is the answer a player expects when they ask why a frozen
## tower did not move.


func _primary(_space: Variant, origin: Vector3, _aim: Vector3) -> DotResult:
	return _blast(origin, 1.0)


func _secondary(_space: Variant, origin: Vector3, _aim: Vector3) -> DotResult:
	# Inward, and weaker. A pull as strong as the push gathers the whole map into the
	# player's face and there is no way back out of it.
	return _blast(origin, -tune(&"pull_scale", 0.55))


func _blast(origin: Vector3, sign_of: float) -> DotResult:
	if spawner == null:
		return DotResult.fail(DotError.CODE_STATE, "This weapon has no world.")

	var radius := tune(&"radius", 9.0)
	var force := tune(&"force", 900.0)
	var moved := 0

	for prop in spawner.all_props():
		# Frozen props are left alone. Freezing is how a builder says "this is
		# finished", and a blast that undid it would make the two tools fight.
		if prop.frozen or prop.is_held():
			continue

		var body := prop.body()

		if body == null:
			continue

		var away := body.global_position - origin
		var distance := away.length()

		if distance < 0.05 or distance > radius:
			continue

		# Falls off with distance, so the edge of the radius is a nudge rather than a
		# cliff — a constant impulse inside a sphere makes a prop crossing the
		# boundary jump, which reads as a physics glitch.
		var falloff := 1.0 - distance / radius

		body.apply_central_impulse(
			(away / distance + Vector3.UP * 0.3) * force * falloff * sign_of
		)
		moved += 1

	return DotResult.success(moved)
