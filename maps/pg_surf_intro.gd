extends PlaygroundMap

## `pg_surf_intro` — two ramps meeting in a valley, a start platform and a finish.
##
## [b]The shape every surf map is made of, reduced to its minimum.[/b] The player
## drops off the start platform onto a ramp too steep to stand on, slides along it
## under gravity, air-strafes to keep and gain speed, and crosses the finish at the
## bottom. Everything the movement needs to get right is in it: a face steeper than
## `max_slope_angle` so the player is never grounded, a seam between two ramps that a
## naive collide-and-slide would stop them dead in, and enough length that a strafing
## player measurably beats one who does not.
##
## Laid out along -Z, descending. Every number here is also read by
## [method timer_zones], which is why the geometry and the zones cannot drift apart.

## Where the run begins and ends, in metres along -Z.
const START_Z := 0.0
const END_Z := -220.0

## Height of the start platform and of the finish floor.
const START_Y := 40.0
const END_Y := -30.0

## Half the width of the valley at its floor.
const VALLEY_HALF_WIDTH := 3.0

## How far out each ramp reaches from the valley.
const RAMP_WIDTH := 26.0

## Ramp angle from horizontal. Well past the 46° a player can stand on.
const RAMP_ANGLE := 58.0

## The start platform's extent, and the finish pad's.
const PAD_SIZE := Vector3(18.0, 1.0, 18.0)


func _build() -> void:
	PlaygroundGeometry.sun(self)

	fallback_spawn = Vector3(0.0, START_Y + 1.0, START_Z + 6.0)

	# The start platform, and a lip so a player who walks backwards does not simply
	# fall off the map before starting.
	PlaygroundGeometry.box(
		self,
		Vector3(0.0, START_Y - 0.5, START_Z + 6.0),
		PAD_SIZE,
		PlaygroundGeometry.COLOUR_START
	)
	PlaygroundGeometry.box(
		self,
		Vector3(0.0, START_Y + 1.0, START_Z + 15.0),
		Vector3(18.0, 4.0, 1.0),
		PlaygroundGeometry.COLOUR_PLATFORM
	)

	# The two ramps. Each is a long slab tilted about Z so it falls toward the
	# valley, and the pair are placed so their inner edges meet along the centre
	# line — which is the seam DotFpsMotor._resolve_planes exists for.
	var length := absf(END_Z - START_Z)
	var drop := START_Y - END_Y
	var centre_z := (START_Z + END_Z) * 0.5

	# The slab is tilted about Z, so its own length runs along Z and its width runs
	# across the tilt. Its centre sits half a ramp-width out from the valley, raised
	# by the height that width gains at this angle.
	var lift := sin(deg_to_rad(RAMP_ANGLE)) * RAMP_WIDTH * 0.5
	var out := cos(deg_to_rad(RAMP_ANGLE)) * RAMP_WIDTH * 0.5

	for side in [-1.0, 1.0]:
		PlaygroundGeometry.ramp(
			self,
			Vector3(
				side * (VALLEY_HALF_WIDTH + out),
				# Descends along the run, so the whole valley falls from START_Y to
				# END_Y. The pitch is applied by placing the slab, not by a second
				# rotation: two rotations about different axes make the ramp's own
				# surface no longer a plane a player can hold a line on.
				(START_Y + END_Y) * 0.5 + lift,
				centre_z
			),
			Vector3(RAMP_WIDTH, 1.0, length),
			# Negative on the left so both ramps fall toward the middle.
			-side * RAMP_ANGLE,
			Vector3.FORWARD
		)

	# The descent. The ramps above are level along their length, so the fall comes
	# from a floor that steps down — which is what a real surf map does with a
	# succession of ramps, and keeps this one to two slabs.
	var steps := 10

	for i in range(steps):
		var t := float(i) / float(steps - 1)
		var z := lerpf(START_Z - 10.0, END_Z + 10.0, t)
		var y := lerpf(START_Y - 6.0, END_Y, t)

		PlaygroundGeometry.box(
			self,
			Vector3(0.0, y - 0.5, z),
			Vector3(VALLEY_HALF_WIDTH * 2.0, 1.0, length / float(steps) + 1.0),
			PlaygroundGeometry.COLOUR_FLOOR
		)

	# The finish pad.
	PlaygroundGeometry.box(
		self,
		Vector3(0.0, END_Y - 0.5, END_Z - 6.0),
		PAD_SIZE,
		PlaygroundGeometry.COLOUR_END
	)


## The map's zones, built from the same constants as the geometry.
func timer_zones() -> DotTimerZoneSet:
	return build_zones()


## Buildable without a scene, so a tool can write the JSON copy in `maps/`.
static func build_zones() -> DotTimerZoneSet:
	var zones := DotTimerZoneSet.new()
	zones.map_id = &"pg_surf_intro"
	zones.meta["tier"] = 2
	zones.meta["author"] = "playground"

	# The start volume sits ON the start platform: the run begins when the player
	# LEAVES it, which is when they step off the front edge onto the ramps.
	var start := DotTimerZone.make(DotTimerZone.Kind.START, DotTimerTrack.MAIN)
	start.set_box(
		Vector3(-9.0, START_Y, START_Z - 1.0),
		Vector3(9.0, START_Y + 6.0, START_Z + 15.0)
	)
	zones.add(start)

	# The finish spans the whole width of the pad and is six metres deep. Deep,
	# because at 128 Hz a player at 30 m/s crosses 23 cm in a tick and a thin finish
	# line is one the fastest players pass straight through — see
	# DotTimerZoneSet.thin_zones.
	var finish := DotTimerZone.make(DotTimerZone.Kind.END, DotTimerTrack.MAIN)
	finish.set_box(
		Vector3(-9.0, END_Y, END_Z - 12.0),
		Vector3(9.0, END_Y + 8.0, END_Z - 3.0)
	)
	zones.add(finish)

	# Two stages, so the map has splits.
	for i in range(1, 3):
		var stage := DotTimerZone.make(DotTimerZone.Kind.STAGE, DotTimerTrack.MAIN)
		stage.number = float(i)

		var z := lerpf(START_Z, END_Z, float(i) / 3.0)
		var y := lerpf(START_Y, END_Y, float(i) / 3.0)

		stage.set_box(
			Vector3(-30.0, y - 20.0, z - 2.0),
			Vector3(30.0, y + 20.0, z + 2.0)
		)
		zones.add(stage)

	# Below the map: anything that gets here has fallen off, and putting them back
	# at the spawn is much better than watching them descend for ever.
	var pit := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, DotTimerTrack.MAIN)
	pit.set_box(
		Vector3(-400.0, END_Y - 120.0, END_Z - 400.0),
		Vector3(400.0, END_Y - 40.0, START_Z + 400.0)
	)
	zones.add(pit)

	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, DotTimerTrack.MAIN)
	spawn.destination = Vector3(0.0, START_Y + 1.0, START_Z + 6.0)
	spawn.destination_yaw = 0.0
	zones.add(spawn)

	return zones
