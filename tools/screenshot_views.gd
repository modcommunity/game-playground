extends SceneTree

## Renders the sandbox in first person and in third, so a person can look at both.
##
## [b]A camera is the one thing in this repository no assertion reaches.[/b] Every check
## on the view switch is a check on an id — `active_id()`answers "tp" — and an id is equally
## happy when the rig is inside the player's head, behind a wall, or looking at the sky.
## Four of the bugs in this family's list were found by looking at a frame.
##
## [codeblock]
## tools/screenshot_views.sh
## [/codeblock]
##
## [b]Not `--headless`[/b]: that gives a null renderer and every frame it saves is empty,
## which is worse than no screenshot because it looks like one.

const OUT_DIR := "res://screenshots"

## Frames to let the rig settle. `DotTpsCameraRig` is on a spring arm and springs take
## time, so a capture on the tick of the switch is a picture of the camera mid-flight.
const SETTLE := 12

var _game: Playground = null
var _player: PlaygroundPlayer = null
var _shots: Array[Dictionary] = []
var _at := 0
var _wait := SETTLE
var _arranged := false
var _done := false


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	DotFpsSampler.register_default_actions()

	var config := PlaygroundConfig.new()
	config.records_directory = ""
	config.initial_map = &"pg_lobby"
	config.map_seconds = 0.0

	_game = Playground.new()
	_game.name = "Playground"
	_game.config = config
	root.add_child(_game)


func _process(_delta: float) -> bool:
	if _done:
		return true

	if _player == null:
		if _game.maps == null or _game.maps.current == null:
			return false

		_player = _game.add_player(&"local", "gamemann")
		_player.samples_input = true
		# The sampler reads real input and there is none behind xvfb; the player is left
		# standing, which is what makes the two frames comparable.
		_player.sampler = null

		var camera := Camera3D.new()
		camera.name = "Camera"
		camera.fov = 100.0
		camera.current = true
		_player.add_child(camera)

		var view := DotFpsView.new()
		view.name = "View"
		_player.add_child(view)
		_player.view = view

		if not _player.build_view_switch():
			push_error("no view switch was built; there is nothing to photograph")
			_done = true
			return true

		_shots = [
			{"name": "view_first_person", "third": false},
			{"name": "view_third_person", "third": true},
		]
		return false

	if _at >= _shots.size():
		print("[views] %d frames in screenshots/" % _shots.size())
		_done = true
		return true

	var shot: Dictionary = _shots[_at]

	if not _arranged:
		var now := _player.set_view_mode(bool(shot["third"]))
		print("[views] %s -> %s" % [String(shot["name"]), String(now)])
		_arranged = true
		_wait = SETTLE
		return false

	if _wait > 0:
		_wait -= 1
		return false

	_capture(String(shot["name"]))
	_at += 1
	_arranged = false
	return false


func _capture(shot_name: String) -> void:
	var image := root.get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, shot_name]

	if image.save_png(path) != OK:
		push_error("could not write %s" % path)
		return

	# Reported at CAPTURE time, not at arrange time. `DotTpsCameraRig.follow` runs once a
	# frame from `DotTpsController._process`, so everything about the rig is still at its
	# starting value on the frame the switch happens — printing it there says the camera
	# never moved when what it means is that it has not moved YET.
	var where := "first person"

	if _player.tps != null and _player.tps.rig != null and _player.tps.rig.camera != null:
		if _player.tps.active:
			where = "cam=%s behind body=%s arm=%.2f" % [
				str(_player.tps.rig.camera.global_position.round()),
				str(_player.global_position.round()),
				_player.tps.rig.arm.get_hit_length()
			]

	print("[views] %s  %dx%d  %s" % [
		path, image.get_width(), image.get_height(), where
	])
