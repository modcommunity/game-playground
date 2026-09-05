extends PlaygroundMap

## `pg_lobby` — the sandbox, and a small timed course in the corner of it.
##
## [b]This is the map the server is on when it is not on a course[/b], and on a
## sandbox-first server that is most of the time: a big flat plate to build on, walls
## so props stay in and players do not walk off into nothing, a staircase and two
## ramps to prove stair-stepping and surfing still work, and room for a hundred props
## between them.
##
## [b]The course is on a bonus track, and the main track deliberately has no start
## and no end.[/b] That is the part worth reading twice. `pg_lobby` used to have no
## zones at all, which was the one thing proving the rest of the game does not quietly
## require a timer — and a sandbox with a minigame in it would have thrown that away.
## Putting the course on [constant DotTimerTrack.BONUS_FIRST] keeps both: a player on
## the main track is on a map with no timer for them, exactly as before, and a player
## who switches to bonus 1 gets a run. The mixed case is also a better test than the
## empty one, because it is the case a real sandbox server is in.
##
## It is also what answers "does this timer only do surf and bhop?". Nothing about a
## jump course is a movement genre: it is zones drawn round platforms, and the same
## sub-tick fractions, styles, records and replays apply to it.

## The floor plate, and the walls round it.
const SIZE := 200.0
const WALL_HEIGHT := 10.0

# --- The course ------------------------------------------------------------
#
# Every number below is read by both `_build` and `build_zones`, which is the whole
# reason the maps here are code: a start line half a metre from where the platforms
# actually are is a leaderboard that cannot be compared with anybody else's.

## Where the course runs, out in one corner and clear of the ramps.
const COURSE_X := 60.0

## The centre of the start pad, which is also where the first platform is measured
## from.
const COURSE_START_Z := 60.0

## Height of the start pad's top surface.
const COURSE_BASE_Y := 6.0

## Platforms after the start pad.
const COURSE_STEPS := 9

const PLATFORM := Vector3(3.0, 0.5, 3.0)

## The first gap, and how much longer each one is than the last.
##
## [b]Both sized against the movement, not chosen to look right.[/b] With
## `jump_height` 1.15 m and `gravity` 20 m/s² a jump lasts about 0.68 s, so a player
## at the 7 m/s ground speed covers 4.8 m — and the last gap here is 4.95 m, which is
## just past that. The course is therefore walkable to the second-to-last platform and
## needs a hop's worth of carried speed for the last one, which is the shape a
## minigame wants: finishable by anybody, faster for somebody who can move.
const COURSE_GAP := 2.5
const COURSE_GAP_GROWTH := 0.35

## How much each platform rises. Under `jump_height`, so a gap is never also a wall.
const COURSE_RISE := 0.8

## The pads at each end.
const PAD := Vector3(8.0, 1.0, 8.0)

## Where the reset volume reaches. Anything below this over the course's footprint is
## a player who fell off, and they go back to the start.
const COURSE_FLOOR_Y := 3.5


func _build() -> void:
	PlaygroundGeometry.sun(self)

	fallback_spawn = Vector3(0.0, 1.0, 0.0)

	PlaygroundGeometry.box(
		self,
		Vector3(0.0, -0.5, 0.0),
		Vector3(SIZE, 1.0, SIZE),
		PlaygroundGeometry.COLOUR_FLOOR
	)

	# Walls, so props stay in and players do not walk off into nothing.
	for side in [-1.0, 1.0]:
		PlaygroundGeometry.box(
			self,
			Vector3(side * SIZE * 0.5, WALL_HEIGHT * 0.4, 0.0),
			Vector3(1.0, WALL_HEIGHT, SIZE),
			PlaygroundGeometry.COLOUR_PLATFORM
		)
		PlaygroundGeometry.box(
			self,
			Vector3(0.0, WALL_HEIGHT * 0.4, side * SIZE * 0.5),
			Vector3(SIZE, WALL_HEIGHT, 1.0),
			PlaygroundGeometry.COLOUR_PLATFORM
		)

	_build_movement_corner()
	_build_course()


## A staircase and two ramps, so the movement is visible without leaving the sandbox.
##
## Kept from when this map was only a lobby. The staircase is what makes stair
## stepping visible, the shallow ramp is one a player walks up, and the steep one is
## past `max_slope_angle` and can only be surfed — which is somewhere to learn it
## without loading a surf map.
func _build_movement_corner() -> void:
	for i in range(6):
		PlaygroundGeometry.box(
			self,
			Vector3(-24.0 + float(i) * 2.0, float(i) * 0.35 - 0.175, -24.0),
			Vector3(2.0, 0.35 + float(i) * 0.7, 8.0),
			PlaygroundGeometry.COLOUR_PLATFORM
		)

	PlaygroundGeometry.ramp(
		self,
		Vector3(24.0, 2.0, -20.0),
		Vector3(14.0, 0.8, 20.0),
		30.0,
		Vector3.FORWARD
	)

	PlaygroundGeometry.ramp(
		self,
		Vector3(24.0, 8.0, 20.0),
		Vector3(20.0, 0.8, 30.0),
		55.0,
		Vector3.FORWARD
	)


## The minigame: a start pad, nine platforms with widening gaps, and a finish pad.
func _build_course() -> void:
	_pad(
		Vector3(COURSE_X, COURSE_BASE_Y - PAD.y * 0.5, COURSE_START_Z),
		PlaygroundGeometry.COLOUR_START
	)

	for i in range(COURSE_STEPS):
		var at := platform_centre(i)

		PlaygroundGeometry.box(
			self, at, PLATFORM, PlaygroundGeometry.COLOUR_PLATFORM
		)

	var finish := finish_centre()

	_pad(
		Vector3(finish.x, finish.y - PAD.y * 0.5, finish.z),
		PlaygroundGeometry.COLOUR_END
	)


## A pad plus the pillar holding it up, so the course reads as a structure rather
## than as slabs floating in the air.
func _pad(at: Vector3, colour: Color) -> void:
	PlaygroundGeometry.box(self, at, PAD, colour)

	# From the floor to the underside of the pad. Its centre is halfway up that.
	var height := at.y - PAD.y * 0.5

	if height <= 0.0:
		return

	PlaygroundGeometry.box(
		self,
		Vector3(at.x, height * 0.5, at.z),
		Vector3(1.6, height, 1.6),
		PlaygroundGeometry.COLOUR_PLATFORM
	)


## The centre of platform [param index], counted from 0.
##
## [b]Static, so [method build_zones] can call it without a scene.[/b] The zones and
## the geometry are the same arithmetic, which is what stops a stage line drifting off
## the platform it is supposed to be on.
static func platform_centre(index: int) -> Vector3:
	# Walked forward edge by edge rather than computed in closed form. The gap grows
	# with each step, so "centre to centre" and "clear air between them" are two
	# different numbers — and it is the second one a player has to jump. Spacing by
	# centres makes the real gap quietly shrink as the platforms get further apart,
	# which is the opposite of what this course is for.
	var edge := COURSE_START_Z - PAD.z * 0.5

	for i in range(index + 1):
		edge -= COURSE_GAP + COURSE_GAP_GROWTH * float(i)
		edge -= PLATFORM.z

	return Vector3(
		COURSE_X,
		COURSE_BASE_Y + COURSE_RISE * float(index + 1) - PLATFORM.y * 0.5,
		edge + PLATFORM.z * 0.5
	)


## The top surface of the finish pad, one gap past the last platform.
static func finish_centre() -> Vector3:
	var last := platform_centre(COURSE_STEPS - 1)

	var edge := last.z - PLATFORM.z * 0.5
	edge -= COURSE_GAP + COURSE_GAP_GROWTH * float(COURSE_STEPS)

	return Vector3(
		COURSE_X,
		last.y + PLATFORM.y * 0.5 + COURSE_RISE,
		edge - PAD.z * 0.5
	)


func timer_zones() -> DotTimerZoneSet:
	return build_zones()


## The zones, built from the same constants as the geometry.
##
## [b]The main track has no start and no end, and that is deliberate.[/b] See the
## class documentation: it is what keeps "a map with no timer" a case this project
## still runs, on the map an ordinary sandbox player is standing on.
static func build_zones() -> DotTimerZoneSet:
	var zones := DotTimerZoneSet.new()
	zones.map_id = &"pg_lobby"
	zones.meta["tier"] = 1
	zones.meta["author"] = "playground"

	# Where an ordinary sandbox player appears: the middle of the plate, on the main
	# track, with nothing to time them.
	var lobby_spawn := DotTimerZone.make(
		DotTimerZone.Kind.SPAWN, DotTimerTrack.MAIN
	)
	lobby_spawn.destination = Vector3(0.0, 1.0, 0.0)
	lobby_spawn.destination_yaw = 0.0
	zones.add(lobby_spawn)

	var track := DotTimerTrack.BONUS_FIRST

	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, track)
	spawn.destination = Vector3(COURSE_X, COURSE_BASE_Y + 1.0, COURSE_START_Z)
	spawn.destination_yaw = 0.0
	zones.add(spawn)

	# The start volume sits ON the pad: timing begins when the player LEAVES it,
	# which is the jump onto the first platform. Timing from the moment they entered
	# would time their run-up along the pad.
	var start := DotTimerZone.make(DotTimerZone.Kind.START, track)
	start.set_box(
		Vector3(
			COURSE_X - PAD.x * 0.5,
			COURSE_BASE_Y - 0.5,
			COURSE_START_Z - PAD.z * 0.5
		),
		Vector3(
			COURSE_X + PAD.x * 0.5,
			COURSE_BASE_Y + 5.0,
			COURSE_START_Z + PAD.z * 0.5
		)
	)
	zones.add(start)

	var finish := finish_centre()

	# Deep, for the reason dot-timer's `thin_zones` check exists: at 128 Hz a player
	# arriving at 12 m/s covers 9 cm in a tick, and a finish line thinner than that
	# is one the fastest players pass straight through without ever being inside it.
	var end := DotTimerZone.make(DotTimerZone.Kind.END, track)
	end.set_box(
		Vector3(finish.x - PAD.x * 0.5, finish.y - 1.0, finish.z - PAD.z * 0.5),
		Vector3(finish.x + PAD.x * 0.5, finish.y + 5.0, finish.z + PAD.z * 0.5)
	)
	zones.add(end)

	# One split, halfway along, so the course has something to compare against
	# itself. Spanning the whole width of the course rather than sitting on one
	# platform: a player who jumps past the platform still passed the line.
	var middle := platform_centre(COURSE_STEPS / 2)
	var stage := DotTimerZone.make(DotTimerZone.Kind.STAGE, track)
	stage.number = 1.0
	stage.set_box(
		Vector3(middle.x - 12.0, middle.y - 6.0, middle.z - 1.0),
		Vector3(middle.x + 12.0, middle.y + 12.0, middle.z + 1.0)
	)
	zones.add(stage)

	# Falling off. The course is six metres above a floor that goes on for another
	# ninety, so there is nothing to fall INTO — the reset volume is the air just
	# above the sandbox floor under the whole course, and touching it puts the player
	# back on the start pad.
	#
	# On the bonus track, so it is invisible to somebody walking through the same
	# corner of the sandbox with a physics gun. That track filter is the reason
	# [constant DotTimerZone.Kind.RESPAWN] can be used at all in a map that is also
	# somewhere people build.
	var reset := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, track)
	reset.set_box(
		Vector3(COURSE_X - 20.0, 0.0, finish.z - 16.0),
		Vector3(COURSE_X + 20.0, COURSE_FLOOR_Y, COURSE_START_Z + 16.0)
	)
	zones.add(reset)

	return zones
