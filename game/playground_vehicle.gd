extends "playground_prop.gd"


## One vehicle body, built from its definition — the same way every other spawnable in
## this project is, and for the same reason: this build ships no art.
##
## [b]A [VehicleBody3D] at the root, for both chassis kinds.[/b] Godot's raycast vehicle
## refuses anything else, and a [VehicleBody3D] IS a [RigidBody3D], so the hover skiff is
## perfectly happy in the same scene. One scene, two chassis, and what differs is the
## definition — which is the shape [PlaygroundProp] already has.
##
## [b]The wheels are built here and they have to exist before the chassis binds.[/b]
## [DotVehicleWheeled] walks the body's direct children for [VehicleWheel3D] once, in
## `bind`, and caches them; a wheel added afterwards is a wheel nothing drives, steers or
## brakes. So [Playground] configures the body and THEN adopts it — a car with four
## wheels that does not move, with every number in its tunables correct, is what the
## other order produces.
##
## [b]It extends [PlaygroundProp], and that is the point of the whole design.[/b] A
## vehicle here is a [DotPropInstance] first: it counts against a prop budget, it can be
## undone, it goes when its owner leaves, a physics gun can pick it up and a gravity gun
## can punt it across the map. A car you cannot punt is not a sandbox car.

## Wheel geometry, when a definition says nothing. A small car.
const DEFAULT_WHEEL_RADIUS := 0.4
const DEFAULT_WHEEL_TRACK := 1.6
const DEFAULT_WHEEL_BASE := 2.2

## The vehicle definition this body is driven by, set by [Playground] on adoption. Null
## until then, and null for ever on a client — where a vehicle is a body being drawn
## where the server says it is and nothing more.
var vehicle_def: DotVehicleDef = null

var _wheels: Array[VehicleWheel3D] = []


## Builds the body, then the wheels if the definition wants them.
##
## [param p_def] is the PROP definition; the vehicle definition is looked up from it,
## because the prop catalogue is what a spawn names and what the Q menu lists.
func configure(p_def: DotPropDef) -> void:
	super.configure(p_def)

	# Continuous collision detection is inherited from PlaygroundProp and is wrong here:
	# a raycast vehicle's wheels are already swept rays, and Godot's CCD on a body with
	# VehicleWheel3D children fights the wheel solver — the car judders at speed and the
	# judder is read as bad suspension.
	continuous_cd = false

	if str(p_def.meta.get("chassis_wheels", "yes")).to_lower() == "no":
		return

	if not p_def.meta.has("wheel_radius") and not p_def.meta.has("wheel_base"):
		# A definition with no wheel geometry is a hovercraft, a boat or a game's own
		# chassis. Silence is right: a warning here would fire on every skiff.
		return

	_build_wheels(p_def)


## Four wheels, front pair steering and rear pair driving.
##
## [b]Front-steer, rear-drive, and not all four of both.[/b] `set_engine_force` writes
## the same figure onto every traction wheel, so a four-wheel-drive body given the whole
## number accelerates twice as hard as a rear-wheel-drive one from identical tunables —
## which would make [member DotVehicleTunables.engine_force] mean two different things
## depending on a scene nobody reading the catalogue can see.
func _build_wheels(p_def: DotPropDef) -> void:
	var radius := float(p_def.meta.get("wheel_radius", DEFAULT_WHEEL_RADIUS))
	var track := float(p_def.meta.get("wheel_track", DEFAULT_WHEEL_TRACK))
	var base := float(p_def.meta.get("wheel_base", DEFAULT_WHEEL_BASE))
	var height := float(p_def.meta.get("wheel_y", 0.0))

	var half_track := track * 0.5
	var half_base := base * 0.5

	# -Z is forward everywhere in this family. dot-vehicle's own note records that
	# Godot's engine force drives +Z and that DotVehicleWheeled inverts it once, so the
	# wheels are laid out in OUR convention and the addon does the translation.
	for row in [
		["FrontLeft", Vector3(-half_track, height, -half_base), true, false],
		["FrontRight", Vector3(half_track, height, -half_base), true, false],
		["RearLeft", Vector3(-half_track, height, half_base), false, true],
		["RearRight", Vector3(half_track, height, half_base), false, true],
	]:
		var wheel := VehicleWheel3D.new()
		wheel.name = String(row[0])
		wheel.position = row[1]
		wheel.use_as_steering = bool(row[2])
		wheel.use_as_traction = bool(row[3])
		wheel.wheel_radius = radius
		# Left where the tunables will overwrite them. DotVehicleWheeled writes travel,
		# stiffness, damping and friction onto every wheel at bind time, which is the
		# whole reason handling is data rather than a scene.
		add_child(wheel)
		_wheels.append(wheel)

		var mesh := MeshInstance3D.new()
		mesh.name = "%sMesh" % String(row[0])
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = radius
		cylinder.bottom_radius = radius
		cylinder.height = radius * 0.5
		mesh.mesh = cylinder
		# Turned onto its side: a CylinderMesh stands up the Y axis and a wheel rolls
		# about X. Every unshaded box in this project is a lie about art and this one is
		# no different, but a wheel lying flat reads as a hubcap on the ground.
		mesh.rotation_degrees = Vector3(0.0, 0.0, 90.0)

		var material := StandardMaterial3D.new()
		material.albedo_color = Color("22242a")
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mesh.material_override = material

		wheel.add_child(mesh)


## How many wheels were built. Read by the suite, because "the car does not move" and
## "the car has no wheels" are the same symptom and different bugs.
func wheel_count() -> int:
	return _wheels.size()


## The wheels' steering angle, drawn from what the server sent. Client side only.
##
## It cannot be derived from anything else replicated: a client watching a car go round
## a corner knows the body is turning and not which way the wheels point, and a drifting
## car has them on opposite lock. Without this every mirrored vehicle drives with its
## wheels straight ahead, which is the single most noticeable thing wrong with a
## networked car.
func draw_steering(radians: float) -> void:
	for wheel in _wheels:
		if wheel.use_as_steering:
			wheel.steering = radians
