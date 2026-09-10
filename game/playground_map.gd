class_name PlaygroundMap
extends Node3D

## Base class for the playground's built-in maps.
##
## [b]A map carries its own zones here, and a delivered map would ship a JSON
## file.[/b] Both routes are real and dot-map supports both: `DotMapDef.zones_path`
## points at a file, and a map that ships inside the game's own build can instead
## answer [method timer_zones] directly. This project uses the second for its own
## maps and keeps a written-out copy of one of them in `maps/` — with a check in the
## headless suite that the two agree, because a zone file that has drifted from the
## geometry it was drawn against is a leaderboard nobody can compare.
##
## Subclasses override [method _build] and [method timer_zones].

## Where players appear if the map has no spawn zone.
@export var fallback_spawn: Vector3 = Vector3(0.0, 2.0, 0.0)


func _ready() -> void:
	_build()


## Builds the geometry. Called once, from [method Node._ready].
func _build() -> void:
	pass


## The map's timer zones, or null for a map with no timer.
func timer_zones() -> DotTimerZoneSet:
	return null


## Where a player on [param track] starts.
func spawn_for(track: int) -> Vector3:
	var zones := timer_zones()

	if zones != null:
		var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)

		if spawn != null:
			return spawn.destination

	return fallback_spawn


## The yaw a player faces when they spawn on [param track], in degrees.
func spawn_yaw_for(track: int) -> float:
	var zones := timer_zones()

	if zones != null:
		var spawn := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)

		if spawn != null:
			return spawn.destination_yaw

	return 0.0


## Whether [param track] is meant to be driven rather than run.
##
## [b]Default false, which is every map that existed before there were cars.[/b]
## [code]Playground._on_seated[/code] cancels a run when a player gets into a vehicle,
## because a foot course driven round in a buggy is not a time anybody can compare with
## one that was jumped — and dot-timer has no idea a vehicle exists, so nothing below
## this can tell the difference.
##
## A circuit inverts that: the car is the point, and getting OUT of it mid-lap is the
## thing that should end the run. A map says which of its tracks are which, because the
## map is the only thing that knows. See `pg_lobby`'s bonus 3.
func track_is_driven(_track: int) -> bool:
	return false
