extends "res://game/entities/playground_entity.gd"

## Spins in place and shoves whatever comes near it. A hazard, and a toy.
##
## Extends a PATH rather than a class for the reason in `npc_wanderer.gd`.
##
## [b]It shoves through the prop spawner's own list rather than a physics query.[/b]
## The spawner already knows every prop in the world and what owns it, so this is a
## walk over a dictionary instead of a shape cast every tick — and it means the shove
## respects exactly the same set of things a physics gun can touch, which is the
## answer a player expects when they ask why their frozen tower was not thrown about.

func _entity_tick(delta: float) -> void:
	# Turned by hand rather than by torque: a torque on a body that is also being
	# collided with spins up without limit, and a spinner at 400 rpm removes a build
	# in one tick.
	angular_velocity = Vector3.ZERO
	rotate_y(deg_to_rad(tune(&"rpm", 90.0) * 6.0) * delta)

	if game == null or game.props == null:
		return

	var reach := tune(&"reach", 4.0)
	var shove := tune(&"shove", 9.0)

	for other in game.props.all_props():
		if other == instance or not other.is_alive() or other.is_held():
			continue

		var body := other.body()

		if body == null or other.frozen:
			continue

		var away := body.global_position - global_position
		away.y = 0.0

		var distance := away.length()

		if distance < 0.01 or distance > reach:
			continue

		# Falls off with distance, so the edge of the reach is a nudge rather than a
		# cliff — a constant impulse inside a radius makes a prop crossing the
		# boundary jump, which looks like a physics glitch rather than a fan.
		var strength := shove * (1.0 - distance / reach)

		body.apply_central_impulse(
			(away / distance + Vector3.UP * 0.35) * strength * body.mass * delta
		)
