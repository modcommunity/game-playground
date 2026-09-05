class_name PlaygroundGeometry
extends RefCounted

## Builds dev-textured collision geometry in code, so the maps need no art.
##
## [b]Why the maps are built by a script rather than authored in the editor.[/b] Two
## reasons, and the second is the one that matters. The first is that this project
## ships no art and a hand-placed grey box is no more readable in a [code].tscn[/code]
## than one line of code. The second is that a surf map's timer zones have to line up
## with its ramps [i]exactly[/i] — a start line half a metre from where the mapper
## meant it is a leaderboard that cannot be compared with anybody else's — and a map
## whose geometry and zones are derived from the same constants cannot drift apart.
##
## A real game authors its maps in the editor and draws its zones with
## [code]DotTimerZonePainter[/code]. This is a test fixture that happens to be
## playable.

## Colours for the three surfaces a movement map is made of, so it is readable
## without textures.
const COLOUR_FLOOR := Color(0.32, 0.34, 0.38)
const COLOUR_RAMP := Color(0.26, 0.42, 0.55)
const COLOUR_START := Color(0.22, 0.55, 0.28)
const COLOUR_END := Color(0.60, 0.24, 0.24)
const COLOUR_PLATFORM := Color(0.42, 0.40, 0.34)


## A static box with collision and a visible mesh.
##
## [param size] is the full extent, and [param at] is its centre — the same
## convention [AABB] and [BoxShape3D] use, and deliberately not "a corner", because
## every zone in this file is placed relative to a box's middle.
static func box(
	parent: Node3D,
	at: Vector3,
	size: Vector3,
	colour: Color = COLOUR_FLOOR,
	basis: Basis = Basis.IDENTITY
) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.transform = Transform3D(basis, at)

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	body.add_child(shape)

	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh.mesh = box_mesh

	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	# Unshaded, because this project ships no lights either and a lit grey box in an
	# unlit scene is a black box.
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material_override = material

	body.add_child(mesh)
	parent.add_child(body)

	return body


## A ramp: a long thin box, tilted by [param angle_degrees] about [param axis].
##
## The tilt is applied to the box rather than to a plane, so the ramp has a back and
## an end — which is what makes a surf map a place rather than an infinite slope, and
## is the difference between this and [code]DotFpsFlatBody.add_ramp[/code].
static func ramp(
	parent: Node3D,
	at: Vector3,
	size: Vector3,
	angle_degrees: float,
	axis: Vector3 = Vector3.FORWARD,
	colour: Color = COLOUR_RAMP
) -> StaticBody3D:
	return box(
		parent, at, size, colour,
		Basis(axis.normalized(), deg_to_rad(angle_degrees))
	)


## A light, so a lit material is visible if a game adds one.
##
## The maps here are unshaded and do not need it; a game that replaces the materials
## does, and finding out that a map has no light by opening it is a wasted afternoon.
static func sun(parent: Node3D) -> DirectionalLight3D:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	parent.add_child(light)
	return light
