class_name PlaygroundPropNet
extends DotNetBehaviour

## What a prop, an NPC or anything else with rigid-body physics replicates: where it is
## and how it is turned.
##
## [b]Server-authoritative and never predicted, and that is a decision rather than an
## omission.[/b] Godot's rigid-body solver is not reproducible across machines — island
## ordering, sleep thresholds and contact caching all differ — so a client that
## predicted a stack of barrels would disagree with the server within a second and be
## corrected continuously. That is why the whole sandbox is built around the client
## sending INTENT (spawn this, grab that) and the server owning the answer.
##
## The consequence a player feels is one round trip between clicking the physics gun and
## the prop moving, and it is the correct trade: a wrong-but-immediate barrel that snaps
## back is worse than a right one that starts a moment later.
##
## [member net_position] and [member net_rotation] are interpolated. Nothing else is
## replicated per tick: a client draws a prop, it does not simulate one.

var prop: Node3D = null

var net_position: Vector3 = Vector3.ZERO
var net_rotation: Quaternion = Quaternion.IDENTITY

## Whether the server has frozen it — a physics gun's freeze. Replicated because it
## changes how the prop is drawn, and because a frozen prop stops sending changes and a
## client otherwise cannot tell "frozen" from "the packets stopped".
var net_frozen: bool = false


func _register_net_vars() -> void:
	replicate(&"net_position", DotNetVar.Type.VECTOR3_POSITION).interpolated()
	# Smallest-three, nine bits an element. A prop's orientation does not need more:
	# the error is under a degree and nobody aligns a barrel to a degree.
	replicate(&"net_rotation", DotNetVar.Type.QUATERNION).bits(9).interpolated()
	replicate(&"net_frozen", DotNetVar.Type.BOOL)


## Authority only. The prop is moved by the physics server, and this copies where it
## ended up into the replicated properties.
func pull() -> void:
	if prop == null or not is_instance_valid(prop):
		return
	net_position = prop.global_position
	net_rotation = prop.global_basis.get_rotation_quaternion()
	var body := prop as RigidBody3D
	if body != null:
		net_frozen = body.freeze


func _net_simulate(_tick: int, _delta: float) -> void:
	if identity != null and identity.is_authoritative:
		pull()


## A remote prop, on a snapshot. Written straight to the node: nothing here is
## predicted, so there is no reconciliation to spoil by moving it — the reason
## [PlaygroundPlayerNet] guards this line does not apply.
func _net_state_applied(_tick: int) -> void:
	_draw()


## Every frame between snapshots. Without this a prop steps at the snapshot rate however
## smoothly the interpolator did its work — the family's own "produced correctly and
## consumed by nothing", which cost dot-net two bugs.
func _net_interpolated(_tick: int) -> void:
	_draw()


func _draw() -> void:
	if prop == null or not is_instance_valid(prop):
		return
	if identity != null and identity.is_authoritative:
		return

	prop.global_position = net_position
	prop.global_basis = Basis(net_rotation)

	# A mirrored prop must not be simulated locally as well. Freezing it is not
	# cosmetic: an unfrozen RigidBody3D fights every position written into it, and the
	# result is a prop that jitters against gravity while the packets say it is still.
	var body := prop as RigidBody3D
	if body != null and not body.freeze:
		body.freeze = true
