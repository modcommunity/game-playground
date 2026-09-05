extends PlaygroundMap

## `pg_bhop_intro` — a straight run of blocks with gaps that widen.
##
## [b]A bhop map is a speed test disguised as a platformer.[/b] Each gap is a little
## wider than the last, so the only way to clear the later ones is to have kept the
## speed from the earlier ones — which means landing and jumping on the same tick,
## every time, which is the whole skill. A player who stops between jumps loses their
## speed to friction and cannot finish.
##
## The gaps are sized against the shipped movement defaults with `auto_hop` on: a
## player who hops perfectly gains roughly a metre per second per jump, so the last
## gap needs about twice the speed the first one does.

const START_Z := 0.0
const BLOCKS := 14
const BLOCK_LENGTH := 6.0

## Gap between blocks, in metres. Grows linearly across the run.
const FIRST_GAP := 3.0
const LAST_GAP := 7.0

const BLOCK_Y := 0.0
const BLOCK_WIDTH := 8.0


func _build() -> void:
	PlaygroundGeometry.sun(self)

	fallback_spawn = Vector3(0.0, BLOCK_Y + 1.0, START_Z + 10.0)

	# The start pad, long enough to build speed on before the first gap.
	PlaygroundGeometry.box(
		self,
		Vector3(0.0, BLOCK_Y - 0.5, START_Z + 12.0),
		Vector3(BLOCK_WIDTH, 1.0, 30.0),
		PlaygroundGeometry.COLOUR_START
	)

	var z := START_Z

	for i in range(BLOCKS):
		PlaygroundGeometry.box(
			self,
			Vector3(0.0, BLOCK_Y - 0.5, z - BLOCK_LENGTH * 0.5),
			Vector3(BLOCK_WIDTH, 1.0, BLOCK_LENGTH),
			PlaygroundGeometry.COLOUR_PLATFORM
		)

		z -= BLOCK_LENGTH + gap_at(i)

	# The finish pad.
	PlaygroundGeometry.box(
		self,
		Vector3(0.0, BLOCK_Y - 0.5, z - 8.0),
		Vector3(BLOCK_WIDTH, 1.0, 18.0),
		PlaygroundGeometry.COLOUR_END
	)


## The gap after block [param index], in metres.
static func gap_at(index: int) -> float:
	return lerpf(FIRST_GAP, LAST_GAP, float(index) / float(maxi(BLOCKS - 1, 1)))


## Where the run's blocks end, in Z. Derived rather than stored, so the finish zone
## and the finish pad cannot disagree about where the map stops.
static func end_z() -> float:
	var z := START_Z

	for i in range(BLOCKS):
		z -= BLOCK_LENGTH + gap_at(i)

	return z


func timer_zones() -> DotTimerZoneSet:
	return build_zones()


static func build_zones() -> DotTimerZoneSet:
	var zones := DotTimerZoneSet.new()
	zones.map_id = &"pg_bhop_intro"
	zones.meta["tier"] = 3
	zones.meta["author"] = "playground"

	var start := DotTimerZone.make(DotTimerZone.Kind.START, DotTimerTrack.MAIN)
	start.set_box(
		Vector3(-5.0, BLOCK_Y, START_Z),
		Vector3(5.0, BLOCK_Y + 5.0, START_Z + 27.0)
	)
	zones.add(start)

	var finish_z := end_z()

	var finish := DotTimerZone.make(DotTimerZone.Kind.END, DotTimerTrack.MAIN)
	finish.set_box(
		Vector3(-5.0, BLOCK_Y, finish_z - 14.0),
		Vector3(5.0, BLOCK_Y + 5.0, finish_z - 2.0)
	)
	zones.add(finish)

	# Fall off a block and you are out. A respawn volume rather than a kill volume,
	# because on a bhop map falling is the ordinary way to fail and a death animation
	# every eight seconds is intolerable.
	var pit := DotTimerZone.make(DotTimerZone.Kind.RESPAWN, DotTimerTrack.MAIN)
	pit.set_box(
		Vector3(-200.0, BLOCK_Y - 40.0, finish_z - 200.0),
		Vector3(200.0, BLOCK_Y - 6.0, START_Z + 200.0)
	)
	zones.add(pit)

	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN, DotTimerTrack.MAIN)
	spawn.destination = Vector3(0.0, BLOCK_Y + 1.0, START_Z + 22.0)
	zones.add(spawn)

	return zones
