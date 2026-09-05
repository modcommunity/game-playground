extends SceneTree

## Writes each built-in map's zones out as the JSON file a DELIVERED map would ship.
##
## [codeblock]
## godot --headless --path . --script tools/export_zones.gd
## [/codeblock]
##
## [b]Why a generated file rather than a hand-written one.[/b] The playground's maps
## build their geometry and their zones from the same constants, which is what stops
## the two drifting apart — but a map delivered through dot-cloud cannot carry a
## script that does that, it ships a zone file. So the file is generated from the same
## source, committed, and checked against the map by the headless suite. A hand-copied
## file would be correct exactly once.


func _init() -> void:
	var maps := {
		# pg_lobby is in here even though its main track has no timer: it carries the
		# sandbox's spawn point and the bonus course's whole zone set, and a delivered
		# copy of it would ship exactly this file.
		"pg_lobby": preload("res://maps/pg_lobby.gd"),
		"pg_surf_intro": preload("res://maps/pg_surf_intro.gd"),
		"pg_bhop_intro": preload("res://maps/pg_bhop_intro.gd"),
	}

	var failures := 0

	for id in maps:
		var zones: DotTimerZoneSet = (maps[id] as GDScript).build_zones()
		var path := "res://maps/%s.zones.json" % id
		var wrote := zones.save_json(path)

		if wrote.ok:
			print("wrote %s (%d zones, %s)" % [
				path, zones.zones.size(), zones.fingerprint()
			])
		else:
			printerr("could not write %s: %s" % [path, wrote.error.message])
			failures += 1

		for problem in zones.problems():
			printerr("  PROBLEM %s" % problem)
			failures += 1

	quit(1 if failures > 0 else 0)
