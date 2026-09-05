class_name PlaygroundProp
extends RigidBody3D

## One spawnable thing, built from its [DotPropDef] rather than from a saved scene.
##
## [b]One scene for the whole catalogue, because this project ships no art.[/b] A
## sandbox needs a menu with enough in it to build something — planks, panels,
## barrels, balls of four sizes — and the honest way to get that is a modelled prop
## per entry. There are none here, so the shape, the extent and the colour are three
## fields of [member DotPropDef.meta] and this builds the body from them. A server
## with real content points [member DotPropDef.scene_path] at its own scenes and
## never loads this at all, which is the seam the catalogue was designed around:
## [DotPropDef] is checkable without loading anything, and the scene is fetched only
## when something is actually created.
##
## [codeblock]
## "meta": { "shape": "cylinder", "extent": [0.5, 1.4, 0.5], "colour": "6a6f78" }
## [/codeblock]
##
## [b]The body is built by [method configure], not by [method Node._ready].[/b]
## [DotPropSpawner] instantiates the scene, places it, adds it to the world and
## [i]then[/i] emits `spawned` — so the definition is not available until after the
## node is in the tree, and a `_ready` that built a default box would build one that
## is immediately thrown away. Configuring instead of rebuilding also means the
## collision shape is only ever created once.

const CHANNEL := "playground.prop"

## Extent used when a definition says nothing. A one-metre crate.
const DEFAULT_EXTENT := Vector3.ONE

enum Shape {
	BOX,
	SPHERE,
	CYLINDER,
}

## The definition this was built from. Kept so a tool or a HUD can name the prop
## without going back to the catalogue.
var def: DotPropDef = null

var _configured: bool = false


func _ready() -> void:
	# A prop that nothing configured has no collision shape and no mesh: it falls
	# through the floor, is invisible, and cannot be grabbed — three symptoms that
	# all point somewhere else. Said once, loudly, on the frame after spawning,
	# which is the first moment "nobody called configure" is distinguishable from
	# "configure has not been called yet".
	_warn_if_unconfigured.call_deferred()


func _warn_if_unconfigured() -> void:
	if _configured:
		return

	DotLog.error(CHANNEL, "a prop was spawned and never configured", {
		"hint": "Playground connects DotPropSpawner.spawned to configure it.",
	})


## Builds the body from a definition. Called once, immediately after spawning.
func configure(p_def: DotPropDef) -> void:
	def = p_def
	_configured = true

	var extent := extent_of(p_def)
	var shape := shape_of(p_def)
	var colour := colour_of(p_def)

	# Mass is NOT set here. `DotPropSpawner` puts `def.mass` on the body before it
	# enters the tree, which is earlier than this runs and earlier than the first
	# physics step — and setting it twice would make it ambiguous which of the two
	# an operator is editing.

	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	collision.shape = _make_shape(shape, extent)
	add_child(collision)

	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	mesh.mesh = _make_mesh(shape, extent)

	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	# Unshaded, like the maps: this project ships no lights, and a lit grey box in
	# an unlit scene is a black box.
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material_override = material

	add_child(mesh)

	# Continuous collision detection, because a sandbox's whole point is throwing
	# things hard. A punted prop at 40 m/s moves 31 cm in a 128 Hz step, which is
	# further than a plank is thick — so the discrete solver puts it through a wall
	# and the player watches their build leave the map.
	continuous_cd = true


# --- Reading a definition --------------------------------------------------
#
# Public, and static, because the spawn menu draws an icon from the same three fields
# this builds the body from. A barrel is a green cylinder in the world and a green
# cylinder in the menu because both read `meta` through here — and a second copy of
# "what does meta mean" is a second thing that can disagree with the first.

static func shape_of(p_def: DotPropDef) -> Shape:
	match str(p_def.meta.get("shape", "box")).to_lower():
		"sphere":
			return Shape.SPHERE
		"cylinder":
			return Shape.CYLINDER
		_:
			return Shape.BOX


static func extent_of(p_def: DotPropDef) -> Vector3:
	var raw: Variant = p_def.meta.get("extent", null)

	if not (raw is Array) or (raw as Array).size() != 3:
		return DEFAULT_EXTENT

	var values := raw as Array

	# Clamped rather than trusted. A zero extent is a collision shape with no
	# volume, which the solver treats as a point and which then falls through
	# everything — and it arrives here from a JSON catalogue an operator wrote.
	return Vector3(
		maxf(float(values[0]), 0.05),
		maxf(float(values[1]), 0.05),
		maxf(float(values[2]), 0.05)
	)


static func colour_of(p_def: DotPropDef) -> Color:
	var raw := str(p_def.meta.get("colour", ""))

	if raw == "" or not Color.html_is_valid(raw):
		return Color(0.72, 0.55, 0.30)

	return Color.html(raw)


static func _make_shape(shape: Shape, extent: Vector3) -> Shape3D:
	match shape:
		Shape.SPHERE:
			var sphere := SphereShape3D.new()
			# The extent is a diameter everywhere else in this file, so halve it
			# here rather than making spheres the one entry an operator writes in
			# radii.
			sphere.radius = extent.x * 0.5
			return sphere
		Shape.CYLINDER:
			var cylinder := CylinderShape3D.new()
			cylinder.radius = extent.x * 0.5
			cylinder.height = extent.y
			return cylinder
		_:
			var box := BoxShape3D.new()
			box.size = extent
			return box


static func _make_mesh(shape: Shape, extent: Vector3) -> Mesh:
	match shape:
		Shape.SPHERE:
			var sphere := SphereMesh.new()
			sphere.radius = extent.x * 0.5
			# A SphereMesh's height is its full extent while its radius is half of
			# one, so the two have to be set together or it draws an ellipsoid that
			# does not match the collision shape it is inside.
			sphere.height = extent.x
			return sphere
		Shape.CYLINDER:
			var cylinder := CylinderMesh.new()
			cylinder.top_radius = extent.x * 0.5
			cylinder.bottom_radius = extent.x * 0.5
			cylinder.height = extent.y
			return cylinder
		_:
			var box := BoxMesh.new()
			box.size = extent
			return box
