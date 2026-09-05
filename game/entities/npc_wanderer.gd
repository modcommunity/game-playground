extends "res://game/entities/playground_entity.gd"

## Walks about, turns when it is bored or stuck, and hops if the catalogue asks it to.
##
## [b]`extends` a PATH, not a class, and that is the point of this file.[/b] It is the
## template an entity delivered in a dot-cloud pack copies, and a mounted pack's
## `class_name` globals are not registered in the host — measured, and written down in
## the family's CLAUDE.md — so every cross-file type reference inside a pack fails to
## compile while `extends "res://x.gd"` works. Writing the shipped entities the way a
## delivered one has to be written is what keeps that path honest: if it ever stopped
## working, these would stop working with it.
##
## [b]Two catalogue entries run this file.[/b] `npc_wanderer` is the default and
## `npc_hopper` is the same script at a lower speed with `hop` set, which is what
## [method PlaygroundEntity.tune] exists for — the alternative is a second script that
## differs by two numbers and drifts from this one.

## How far off course a turn may be, in degrees either way.
const TURN_SPREAD := 140.0

## Below this fraction of the goal speed for a whole reconsider, it is stuck.
const STUCK_FRACTION := 0.25

var _heading: Vector3 = Vector3.FORWARD
var _next_turn: float = 0.0
var _rng := RandomNumberGenerator.new()


func _entity_ready() -> void:
	# Seeded from the instance rather than randomised, so two wanderers spawned in the
	# same place do not walk in lockstep for ever — and so a headless test that spawns
	# one gets the same walk every run. Props are server-authoritative and never
	# predicted, so nothing here has to agree with a client.
	_rng.seed = hash(instance.instance_id if instance != null else 0)

	_heading = _random_heading()
	_next_turn = tune(&"turn_seconds", 3.0)


func _entity_tick(delta: float) -> void:
	var speed := tune(&"speed", 3.0)

	if age >= _next_turn:
		_reconsider(speed)

	drive(_heading, speed, delta)

	var hop_speed := tune(&"hop", 0.0)

	if hop_speed > 0.0 and _rng.randf() < delta * 0.8:
		hop(hop_speed)


## Picks a new heading, turning harder when the last one went nowhere.
func _reconsider(speed: float) -> void:
	var flat := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	var stuck := flat.length() < speed * STUCK_FRACTION

	# Turned around when stuck rather than nudged. A wall is the commonest reason to
	# be going nowhere, and a small correction against one just walks back into it —
	# which reads as an NPC vibrating in a corner for the rest of the round.
	_heading = (
		-_heading.rotated(Vector3.UP, _rng.randf_range(-0.6, 0.6))
		if stuck
		else _random_heading()
	)

	_next_turn = age + tune(&"turn_seconds", 3.0)


func _random_heading() -> Vector3:
	return _heading.rotated(
		Vector3.UP,
		deg_to_rad(_rng.randf_range(-TURN_SPREAD, TURN_SPREAD))
	).normalized()
