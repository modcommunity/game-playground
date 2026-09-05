class_name PlaygroundEntity
extends PlaygroundProp

## A prop with a script: the base every NPC in the catalogue extends.
##
## [b]The division every sandbox of this kind makes.[/b] A crate is a shape with a
## mass and needs no code;
## a thing that walks about does. dot-props knows nothing of the difference — it
## instantiates a scene, places it and counts it against a budget — so the script is a
## field of [member DotPropDef.meta] and [Playground] attaches it on spawn. See
## [PlaygroundSpawnables] for why it is named by path rather than by class.
##
## [b]An entity is a [RigidBody3D], and that is the whole reason this extends
## [PlaygroundProp].[/b] It gets the body, the shape, the colour and the mass for
## free — and, much more importantly, it is a prop as far as every other system is
## concerned: it counts against a budget, it can be undone, it is cleaned up when its
## owner leaves, a physics gun can pick it up and a gravity gun can punt it across the
## map. An NPC you cannot pick up is the one thing a sandbox player will try first.
##
## [codeblock]
## extends "res://game/entities/playground_entity.gd"
##
## func _entity_tick(delta: float) -> void:
##     drive(Vector3.FORWARD, tune(&"speed", 3.0), delta)
## [/codeblock]
##
## [b]Ticked by the simulation, not by the engine.[/b] `Playground._simulate_tick`
## drives every entity at the fixed rate everything else counts in — not `_process`,
## which would make an NPC's speed a function of the frame rate, and not
## `_physics_process`, which is the same loop but reached without the game's ordering.
## The same argument as the timer's, for the same reason.

## Whose simulation this is in. Set by [method bind] before [method _entity_ready].
var game: Playground = null

## This entity's row in the prop spawner: what owns it, and whether it is held.
var instance: DotPropInstance = null

## Simulated seconds since [method bind]. Not a wall clock — an entity that thought
## in wall time would move at a different speed on a server under load.
var age: float = 0.0


# --- Called by Playground ---------------------------------------------------

## Hands the entity its world. Called once, straight after [method configure].
##
## Separate from `configure` rather than a longer signature on it, because
## `configure` is [PlaygroundProp]'s and an override that widened it would mean an
## inert prop and an entity could no longer be built by the same call.
func bind(p_game: Playground, p_instance: DotPropInstance) -> void:
	game = p_game
	instance = p_instance
	_entity_ready()


## One simulated tick. Called by [Playground], at the game's tick rate.
func entity_tick(delta: float) -> void:
	age += delta

	# A held entity is furniture. Without this it fights the physics gun's spring —
	# the gun writes a velocity toward the goal and the NPC writes one toward wherever
	# it was walking, so the prop shudders between them and the player concludes the
	# gun is broken.
	if instance != null and instance.is_held():
		return

	_entity_tick(delta)


# --- Subclass interface -----------------------------------------------------

## Called once, after the body is built and the world is known.
func _entity_ready() -> void:
	pass


## Called every simulated tick, unless something is holding this.
func _entity_tick(_delta: float) -> void:
	pass


# --- Helpers for subclasses -------------------------------------------------

## A tuning number from the definition's `meta`, or [param fallback].
##
## [b]Tuning lives in the catalogue, not in the script.[/b] It is what lets one script
## serve three catalogue entries — `npc_wanderer` and `npc_hopper` are the same file
## at different speeds — and it is the only half of an entity an operator editing a
## JSON catalogue can reach.
func tune(key: StringName, fallback: float) -> float:
	if def == null:
		return fallback

	var raw: Variant = def.meta.get(String(key), null)

	return float(raw) if raw is float or raw is int else fallback


## The closest player, or null when nobody is in the world.
func nearest_player() -> PlaygroundPlayer:
	if game == null:
		return null

	var best: PlaygroundPlayer = null
	var best_distance := INF

	for id in game.players:
		var player: PlaygroundPlayer = game.players[id]
		var distance := player.global_position.distance_squared_to(global_position)

		if distance < best_distance:
			best_distance = distance
			best = player

	return best


## Steers the horizontal velocity toward [param direction] at [param speed].
##
## [b]The vertical component is left alone, and that is the whole method.[/b] Writing
## a whole velocity onto a rigid body cancels its gravity, so an NPC walking off a
## ledge would hang in the air — and writing one every tick also cancels every impulse
## anything else applies, so a punted NPC would stop dead in mid-flight rather than
## flying. Only the two axes this entity is steering are touched.
func drive(direction: Vector3, speed: float, delta: float, grip: float = 8.0) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)

	if flat.length_squared() < 0.0001:
		return

	var goal := flat.normalized() * speed
	var current := linear_velocity

	# Approached rather than assigned, so a shove from a gravity gun decays over a
	# few ticks instead of vanishing on the next one.
	var blend := clampf(grip * delta, 0.0, 1.0)

	linear_velocity = Vector3(
		lerpf(current.x, goal.x, blend),
		current.y,
		lerpf(current.z, goal.z, blend)
	)

	# Faced where it is going. Angular velocity is zeroed with it: a body shoved by a
	# gravity gun keeps spinning, and an NPC that has stopped tumbling but is still
	# rotating reads as a bug in the movement rather than as leftover momentum.
	look_at_direction(flat)


## Points the body along [param direction], upright.
func look_at_direction(direction: Vector3) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)

	if flat.length_squared() < 0.0001:
		return

	angular_velocity = Vector3.ZERO
	global_transform.basis = Basis(
		Quaternion(Vector3.FORWARD, flat.normalized())
	)


## Whether something is directly underneath, within [param reach] of the feet.
##
## A ray rather than a contact test: `RigidBody3D` reports contacts only when
## `contact_monitor` is on, which costs the solver work on every prop in the world for
## the sake of the handful that are entities.
func is_on_ground(reach: float = 0.25) -> bool:
	var world := get_world_3d()

	if world == null:
		return false

	var feet := global_position - Vector3.UP * (
		PlaygroundProp.extent_of(def).y * 0.5 if def != null else 0.5
	)

	var query := PhysicsRayQueryParameters3D.create(
		feet + Vector3.UP * 0.05, feet - Vector3.UP * reach
	)
	query.exclude = [get_rid()]

	return not world.direct_space_state.intersect_ray(query).is_empty()


## Jumps, if there is something to jump off.
func hop(speed: float) -> bool:
	if not is_on_ground():
		return false

	linear_velocity = Vector3(linear_velocity.x, speed, linear_velocity.z)

	return true


func describe() -> Dictionary:
	return {
		"entity": String(def.id) if def != null else "-",
		"script": get_script().resource_path if get_script() != null else "-",
		"age": "%.1f s" % age,
		"held": instance != null and instance.is_held(),
	}
