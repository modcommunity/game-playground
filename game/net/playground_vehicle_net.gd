class_name PlaygroundVehicleNet
extends PlaygroundPropNet

## What a vehicle replicates, through [DotVehicleNetSync].
##
## [b]The first time that class has ever crossed a wire.[/b] dot-vehicle's own suite
## round-trips its quantisers in one process, which proves the encoders are inverses and
## proves nothing about whether the properties it names can be declared to dot-net at
## all — the family's own "produced correctly and consumed by nothing", one layer down.
##
## [b]It extends [PlaygroundPropNet] rather than sitting beside it.[/b] A vehicle IS a
## prop here, so the bridge keeps one table of replicated bodies and one `pull` loop; a
## second parallel table is a second thing that can disagree about which of them exists.
## What is overridden is all three halves that differ: what is declared, what is copied
## out of the authority, and what is drawn on the mirror.
##
## [b]Nothing here is predicted, and that is dot-vehicle's decision rather than this
## game's shortcut.[/b] A vehicle is a rigid body with a contact solver under it, so two
## machines diverge in a second or two; a predicted vehicle is a corrected vehicle, and a
## correction on something a player is steering reads far worse than latency does. The
## driver's own throttle therefore goes round trip. What is honest is interpolation, and
## every positional spec asks for it.

## The instance, on the authority only. Null on a client, where a vehicle is a body being
## drawn where the server says it is and nothing more.
var vehicle: DotVehicleInstance = null

# The replicated properties, named by DotVehicleNetSync. Declared here because GDScript
# has no dynamic properties: `specs()` says what to send, and these are what it sends.
var net_x: float = 0.0
var net_y: float = 0.0
var net_z: float = 0.0
var net_qx: int = 0
var net_qy: int = 0
var net_qz: int = 0
var net_qw: int = 0
var net_speed: int = 0
var net_steering: int = 0
var net_health: int = 100
var net_occupancy: int = 0


## Declared from the addon's own table, exactly as [PlaygroundPlayerNet] is.
##
## [b]The type is resolved from a STRING, and that is the whole reason the table is
## written the way it is.[/b] `DotVehicleNetSync` never mentions a dot-net `class_name`,
## because a script naming a class the project does not have fails to parse and takes
## every script that references it down with it — so a game without dot-net could still
## use dot-vehicle. Resolving `DotNetVar.Type[spec.type]` is the game's half of that
## bargain and it can only be done here.
func _register_net_vars() -> void:
	for spec in DotVehicleNetSync.specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))

		if bool(spec["interpolated"]):
			declaration.interpolated()


## Authority only: where the physics server left the vehicle this tick.
func pull() -> void:
	if vehicle == null or not vehicle.is_alive():
		return

	DotVehicleNetSync.pull(vehicle, self)


func _draw() -> void:
	if prop == null or not is_instance_valid(prop):
		return

	if identity != null and identity.is_authoritative:
		return

	DotVehicleNetSync.apply(prop, self)

	# The wheels. It cannot be derived from anything else replicated — a client watching
	# a car go round a corner knows the body is turning and not which way the wheels are
	# pointed, and a drifting car has them on opposite lock — so a mirror without this
	# draws every vehicle going straight ahead, which is the most noticeable thing wrong
	# with a networked car.
	var body := prop as PlaygroundVehicle

	if body != null:
		body.draw_steering(DotVehicleNetSync.dequantise_steering(net_steering))

	# Frozen for the same reason a mirrored prop is: an unfrozen VehicleBody3D fights
	# every transform written into it, and the result is a car that jitters against its
	# own suspension while the packets say it is standing still.
	var rigid := prop as RigidBody3D

	if rigid != null and not rigid.freeze:
		rigid.freeze = true


## Whether a seat is occupied, from the replicated mask. What a "get in" prompt reads.
func seat_occupied(seat_index: int) -> bool:
	return DotVehicleNetSync.is_seat_occupied(net_occupancy, seat_index)
