extends "res://game/entities/playground_entity.gd"

## Walks toward the nearest player, and gives up when they get far enough away.
##
## Extends a PATH rather than a class for the reason in `npc_wanderer.gd`: it is the
## shape an entity delivered in a dot-cloud pack must have.
##
## [b]It gives up, and that is a rule rather than a nicety.[/b] An NPC that chases for
## ever crosses the whole map, ends up in the middle of somebody's build, and cannot be
## escaped — so a sandbox fills with them and the only fix is `pg_props_clear`. The
## range is a catalogue field, so a server that wants the other behaviour sets it high
## rather than editing this.

var _wander: Vector3 = Vector3.FORWARD


func _entity_ready() -> void:
	_wander = Vector3.FORWARD.rotated(
		Vector3.UP, float(instance.instance_id if instance != null else 0)
	)


func _entity_tick(delta: float) -> void:
	var target := nearest_player()
	var speed := tune(&"speed", 4.0)

	if target == null:
		drive(_wander, speed * 0.4, delta)
		return

	var to_target := target.global_position - global_position
	to_target.y = 0.0

	if to_target.length() > tune(&"give_up_range", 40.0):
		drive(_wander, speed * 0.4, delta)
		return

	# Stops just short rather than walking into them: a rigid body pressing against a
	# CharacterBody3D every tick pushes the player around the map, and a player being
	# shoved by something they cannot damage is the worst thing in this file.
	if to_target.length() < tune(&"stand_off", 1.6):
		look_at_direction(to_target)
		return

	drive(to_target, speed, delta)
