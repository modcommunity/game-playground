extends SceneTree

const PlaygroundPresentation := preload("../game/playground_presentation.gd")
const PlaygroundSpawnMenu := preload("../game/playground_spawn_menu.gd")
const PlaygroundSpawnables := preload("../game/playground_spawnables.gd")
const PlaygroundWeapons := preload("../game/playground_weapons.gd")

## Renders this game's own screens to `screenshots/` so a person can look at them.
##
## Separate from `screenshot.gd`, which renders MAPS. The spawn menu is the screen worth
## the most here: it is this project's own, it is the one a player is in most often, and
## two of the interface bugs in this game's history were in it — a `TabBar` that hid two of
## its three tabs behind scroll arrows, and an NPC silhouette that came out as a coloured
## bar. Neither was reachable from an assertion; both were found by looking.
##
## [b]Not `--headless`[/b]: that gives a null renderer, a 64 x 64 viewport, and frames that
## are empty for a reason that has nothing to do with the code.

const OUT_DIR := "res://screenshots"
const SETTLE := 3

var _stack: DotScreenStack = null
var _presentation: PlaygroundPresentation = null
var _shots: Array[Dictionary] = []
var _at := 0
var _wait := SETTLE
var _done := false


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	_presentation = PlaygroundPresentation.new()
	_presentation.name = "Presentation"
	root.add_child(_presentation)
	_presentation.setup()

	_stack = DotScreenStack.new()
	_stack.name = "Stack"
	_stack.register_service = false
	_stack.manage_mouse = false
	_stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(_stack)
	_stack.setup()

	# The real catalogues, because a picture of a hand-built list is a picture of a list.
	var menu := PlaygroundSpawnMenu.new()
	menu.name = "SpawnMenu"
	menu.catalogue = PlaygroundSpawnables.catalogue()
	menu.weapons = PlaygroundWeapons.built_in()
	_stack.register(menu)

	var pause := DotPauseScreen.new()
	pause.name = "Pause"
	pause.build(PackedStringArray(["Resume", "Settings", "Servers", "Leave"]))
	_stack.register(pause)

	var settings := DotSettingsScreen.new()
	settings.name = "Settings"
	settings.build(_presentation.settings)
	_stack.register(settings)

	_shots = [
		{"id": &"spawn_menu", "file": "menu_spawn.png"},
		{"id": &"pause", "file": "menu_pause.png"},
		{"id": &"settings", "file": "menu_settings.png"},
	]


func _process(_delta: float) -> bool:
	if _done:
		return true

	if _at >= _shots.size():
		_done = true
		return false

	var shot: Dictionary = _shots[_at]

	if _wait == SETTLE:
		_stack.clear()

		var opened := _stack.push(StringName(shot["id"]))

		if not opened.ok:
			# Said out loud rather than saved as a grey rectangle. A picture of an empty
			# viewport is indistinguishable from a renderer that is not working, which is
			# exactly how dot-ui's unopened pause menu looked.
			push_error("could not open '%s': %s" % [shot["id"], opened.error.message])
			_at += 1
			return false

	if _wait > 0:
		_wait -= 1
		return false

	var image := root.get_texture().get_image()
	var path := OUT_DIR.path_join(str(shot["file"]))
	image.save_png(path)
	print("wrote %s (%d x %d)" % [path, image.get_width(), image.get_height()])

	_at += 1
	_wait = SETTLE
	return false
