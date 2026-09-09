class_name PlaygroundVehicles
extends RefCounted

## Everything this build can be driven in, and how each one handles.
##
## [b]A second catalogue beside the prop one, and it is deliberately not merged with
## it.[/b] The two answer different questions: [DotPropCatalogue] says what may be put in
## the world and what it costs, and [DotVehicleCatalogue] says how a thing drives. A
## vehicle here is in BOTH — it is spawned, budgeted and undone as a prop, and driven as
## a vehicle — and the join is one field of the prop's `meta`:
##
## [codeblock]
## { "kind": "vehicle", "vehicle": "buggy" }
## [/codeblock]
##
## Written the same way [PlaygroundSpawnables] is, for the same reason: an operator with
## a JSON catalogue can reach every number in here, and a dot-cloud pack can deliver one
## because nothing in it names a [code]class_name[/code].
##
## [b]Two vehicles, one of each chassis kind, and that is the minimum that proves
## anything.[/b] A build shipping only a car would leave [DotVehicleHover] as an
## untested promise, which in this family is the same thing as a bug — and the whole
## reason the chassis is a subclass point is that a boat and a car are the same problem
## with different suspension.

const CHANNEL := "playground.vehicles"

## The scene every vehicle is built into. A [VehicleBody3D], because Godot's raycast
## vehicle needs one at the root and a [VehicleBody3D] is a [RigidBody3D] — so the hover
## skiff is perfectly happy in the same scene and this project keeps its "one scene, one
## script, built from the definition" shape.
const SCENE := "res://game/vehicle.tscn"


## Whether a prop definition is really a vehicle, and which one.
##
## Empty for everything else. Read through here rather than through `meta` directly,
## because the spawn path, the net bridge, the HUD and the module all ask the same
## question and a second copy of "what does meta mean" is a second thing that can
## disagree with the first.
static func vehicle_id_of(def: DotPropDef) -> StringName:
	if def == null:
		return &""
	return StringName(str(def.meta.get("vehicle", "")))


## The vehicles this build ships.
static func catalogue() -> DotVehicleCatalogue:
	var out := DotVehicleCatalogue.new()

	out.add(_buggy())
	out.add(_skiff())

	return out


## A two-seat open car. Light, quick and deliberately a little loose at the back.
static func _buggy() -> DotVehicleDef:
	var def := DotVehicleDef.make(&"buggy", SCENE)
	def.display_name = "Buggy"
	def.category = &"car"
	def.kind = DotVehicleDef.Kind.WHEELED
	def.cost = 6
	def.max_health = 0.0

	var t := DotVehicleTunables.new()
	t.mass = 620.0
	t.engine_force = 3600.0
	t.top_speed = 24.0
	t.brake_force = 5200.0
	t.handbrake_force = 9000.0
	t.steering_limit_deg = 34.0
	t.steering_rate_deg = 150.0
	# The most important number in the file, per dot-vehicle's own note: full lock at
	# speed is a car that spins on the first corner and a player who concludes the
	# handling is broken. A sandbox car is driven badly on purpose, so it wants MORE
	# falloff than a racing one, not less.
	t.steering_speed_falloff = 0.30
	# Under 1.0 on purpose: a player can drive out of oversteer and cannot drive out of
	# understeer, and a sandbox car that will not slide is not a toy.
	t.rear_grip_fraction = 0.85
	t.friction_slip = 3.0
	t.suspension_stiffness = 40.0
	t.suspension_travel = 0.30
	# A buggy's origin is at the floor of its body, so the default centre of mass is
	# already low; dropping it further is what stops it rolling onto its roof every time
	# a gravity gun punts it.
	t.centre_of_mass_drop = 0.45
	# Higher than the addon's default. This is a sandbox: hopping out of a rolling car
	# is a thing people do for fun, and the exit sweep is what keeps it safe.
	t.max_exit_speed = 8.0
	t.allow_exit_when_inverted = true
	def.tunables = t

	def.seats = [
		_seat(&"driver", "Driver", true, Vector3(-0.45, 0.55, -0.25)),
		_seat(&"passenger", "Passenger", false, Vector3(0.45, 0.55, -0.25)),
	]

	def.meta = {
		# What PlaygroundVehicle builds the body from. Same three fields a prop uses,
		# plus the wheels.
		"extent": [1.9, 0.9, 3.2],
		"colour": "c25b4a",
		"wheel_radius": 0.42,
		"wheel_track": 1.7,
		"wheel_base": 2.3,
		# BELOW the chassis box, and this is the number that decides whether the car
		# moves at all. The body is a 0.9 m box centred on the origin, so it reaches
		# 0.45 m down; a wheel whose contact point is above that has the box resting on
		# the ground with the wheels in the air, and a raycast vehicle with no wheel on
		# the ground has no traction, no steering and no brakes. Every number in the
		# tunables reads correctly and the car simply sits there.
		"wheel_y": -0.32,
	}

	return def


## A hovercraft. No wheels, no ground contact, and the reason the chassis is a
## subclass point rather than a promise.
static func _skiff() -> DotVehicleDef:
	var def := DotVehicleDef.make(&"skiff", SCENE)
	def.display_name = "Skiff"
	def.category = &"hover"
	def.kind = DotVehicleDef.Kind.HOVER
	def.cost = 6
	def.max_health = 0.0

	var t := DotVehicleTunables.new()
	t.mass = 480.0
	t.engine_force = 2600.0
	t.top_speed = 20.0
	t.brake_force = 1800.0
	t.handbrake_force = 2600.0
	t.steering_limit_deg = 40.0
	t.steering_rate_deg = 120.0
	t.steering_speed_falloff = 0.55
	# The ride height and how hard it is held there. A skiff that floats too softly
	# grounds out on the sandbox's own ramps, which reads as the hover being broken.
	t.suspension_travel = 0.9
	t.suspension_stiffness = 26.0
	t.damping_relaxation = 0.85
	t.centre_of_mass_drop = 0.35
	t.max_exit_speed = 8.0
	def.tunables = t

	def.seats = [
		_seat(&"driver", "Pilot", true, Vector3(0.0, 0.65, -0.35)),
		_seat(&"passenger", "Passenger", false, Vector3(0.0, 0.65, 0.75)),
	]

	def.meta = {
		"extent": [2.2, 0.7, 3.4],
		"colour": "4a8fa8",
	}

	return def


## A seat with its exit candidates, in preference order.
##
## [b]Candidates, never one offset.[/b] dot-vehicle sweeps a body-sized capsule at each
## and refuses the exit when none is free, which is the correct answer — every game that
## teleports the player anyway is a game where players get outside the map. Left is
## tried first for the driver and right for the passenger, so two people getting out of
## the same car do not race for the same patch of ground; the roof is last, because
## standing on the car is silly but it is not inside a wall.
static func _seat(
	id: StringName, display: String, drives: bool, offset: Vector3
) -> DotVehicleSeat:
	var seat := DotVehicleSeat.make(id, drives)
	seat.display_name = display
	seat.seat_offset = offset

	var side := -1.0 if offset.x <= 0.0 else 1.0

	seat.exit_offsets = [
		Vector3(side * 2.0, 0.4, 0.0),
		Vector3(-side * 2.0, 0.4, 0.0),
		Vector3(0.0, 0.4, -2.6),
		Vector3(0.0, 0.4, 2.6),
		Vector3(0.0, 1.8, 0.0),
	]

	seat.exit_clearance = 0.4
	seat.exit_height = 1.8

	return seat
