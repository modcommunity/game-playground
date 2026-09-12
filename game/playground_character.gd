class_name PlaygroundCharacter
extends DotPlayerModelVisual

## The player's body, drawn from a definition rather than loaded from art.
##
## [b]Every other project in this family installs dot-player-char and draws nothing with
## it.[/b] The catalogue is built, the metrics are read, and `DotPlayerCharVisual` —
## the abstract node the whole addon exists to fill — has no implementation anywhere. That
## was survivable while every game was first-person: nobody sees their own body. It stops
## being survivable the moment there is a third-person camera, which is what
## `PlaygroundPlayer.build_view_switch` added, and the first frame through it showed
## exactly what a player with no model looks like — an empty view four metres behind
## nothing.
##
## [b]Primitives, for this project's own stated reason.[/b] `PlaygroundIcons` draws a menu
## card from the three `meta` fields a prop's body is built from, so that a barrel is a
## green cylinder in the world and a green cylinder in the menu. A character here is the
## same argument one level up: the shipped `DotPlayerCharDef` carries height, radius and
## eye height, and those three numbers are enough to build a body that is the right size.
## A server with content points `DotPlayerModelDef.rig_scene` at a real rig and this class
## adopts it instead — which is the seam `DotPlayerModelRig.adopt` exists for.
##
## [b]It is not the local player's own view.[/b] `set_shown(false)` is what a first-person
## camera wants, and the switch drives it: a player looking through their own eyes must
## not see the inside of their own head, and one in third person must.

const CHANNEL := "playground.character"

## Parts of a body, as a fraction of the character's height.
const HEAD_FRACTION := 0.22
const TORSO_FRACTION := 0.46

var _built_for: StringName = &""
var _parts: Node3D = null


## Builds a body the size the character definition says, under an adopted rig.
##
## [b]The rig is adopted rather than loaded[/b], which is what lets a project with no art
## use the whole addon: `DotPlayerModelRig.build_from` returns success and builds nothing
## when `rig_scene` is empty, and `adopt` hands it the node this class made instead. Every
## mount, every attachment and every tint then works exactly as it would over a real rig.
func build_for(def: DotPlayerCharDef, colour: Color) -> void:
	if def == null:
		return

	if _built_for == def.id and _parts != null and is_instance_valid(_parts):
		return

	_built_for = def.id

	if _parts != null and is_instance_valid(_parts):
		_parts.queue_free()

	# [b]Under the RIG, not under this node.[/b] `DotPlayerCharVisual` is a
	# `DotPlayerComponent`, which is a plain `Node` — it has no transform, no `rotation`
	# and no `visible`, because a component is a behaviour rather than a place. The rig
	# is the `Node3D`, which is also what `set_shown` hides and what the mounts hang off.
	# Parenting the body to this node instead gave a character that could not be turned
	# and could not be hidden, with a runtime error per tick and nothing drawn.
	if rig == null:
		rig = DotPlayerModelRig.new()
		rig.name = "Rig"
		add_child(rig)

	_parts = Node3D.new()
	_parts.name = "Body"
	rig.add_child(_parts)

	var height := maxf(def.height, 0.4)
	var radius := maxf(def.radius, 0.1)

	var head_height := height * HEAD_FRACTION
	var torso_height := height * TORSO_FRACTION
	var legs_height := maxf(height - head_height - torso_height, 0.05)

	_capsule("Legs", radius * 0.85, legs_height, legs_height * 0.5, colour.darkened(0.35))
	_capsule(
		"Torso", radius, torso_height, legs_height + torso_height * 0.5, colour
	)
	# A head has to be WIDER than it is tall to read as a head at this size. The entity
	# icons in the spawn menu had the opposite problem — a torso that spanned the full
	# height covered the head entirely and every NPC in the menu came out a coloured bar.
	_sphere(
		"Head",
		radius * 0.78,
		legs_height + torso_height + head_height * 0.5,
		colour.lightened(0.25)
	)

	# A nose, so a body four metres away has a visible FACING. Without one a capsule
	# looks identical from every angle and a third-person camera behind a player who has
	# turned round shows no change at all — which reads as the turn not working.
	_marker(
		"Facing",
		radius * 0.3,
		legs_height + torso_height + head_height * 0.5,
		-radius * 0.9,
		colour.lightened(0.5)
	)

	rig.adopt(_parts, _model_def(def))

	DotLog.debug(CHANNEL, "body built", {
		"char": String(def.id), "height": height, "radius": radius
	})


## Turns the body to face [param yaw], in radians.
##
## On the rig rather than on this node, for the reason the body is parented to it: a
## component has no transform. Without this a third-person camera orbiting a player shows
## a character who never turns, which reads as the model being broken.
func face(yaw: float) -> void:
	if rig != null:
		rig.rotation.y = yaw


## Whether the body is currently drawn. For a suite, and for a HUD that says so.
func is_body_visible() -> bool:
	return rig != null and rig.visible


## A model definition for a rig that is built rather than loaded.
##
## `rig_scene` is deliberately empty: it is what tells `DotPlayerModelRig.build_from` to
## build nothing and wait for `adopt`. The mounts name nodes this class makes, so
## `attachment(&"right_hand")` answers for a weapon the same way it would over real art.
func _model_def(char_def: DotPlayerCharDef) -> DotPlayerModelDef:
	var def := DotPlayerModelDef.new()
	def.id = char_def.id
	def.display_name = char_def.display_name
	def.rig_scene = ""
	def.mounts = {"head": "Head", "torso": "Torso", "right_hand": "Torso"}
	def.weapon_mount = &"right_hand"
	def.eye_mount = &"Head"
	return def


func _capsule(
	part_name: String, radius: float, height: float, y: float, colour: Color
) -> void:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	# A CapsuleMesh's height INCLUDES its two hemispherical caps, so a height below twice
	# the radius is refused by the engine and clamped — which silently makes a short, fat
	# part the wrong size rather than erroring.
	mesh.height = maxf(height, radius * 2.0 + 0.01)
	_add_mesh(part_name, mesh, y, colour)


func _sphere(part_name: String, radius: float, y: float, colour: Color) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	_add_mesh(part_name, mesh, y, colour)


func _marker(
	part_name: String, radius: float, y: float, z: float, colour: Color
) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0

	var node := _add_mesh(part_name, mesh, y, colour)

	if node != null:
		node.position.z = z


func _add_mesh(
	part_name: String, mesh: Mesh, y: float, colour: Color
) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	# Unshaded, like every other surface this project draws: the sandbox has no lights
	# worth speaking of and a lit primitive at this size reads as a grey blob.
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var node := MeshInstance3D.new()
	node.name = part_name
	node.mesh = mesh
	node.material_override = material
	node.position.y = y
	_parts.add_child(node)
	return node
