extends SceneTree

## Renders a playground map to PNGs so a person can look at it.
##
## [b]A map is a rendered thing, and this family has shipped a 0 x 0 Control twice and a
## black screen once.[/b] Every other check on a map here is an assertion about a list of
## boxes, and a list of boxes passes just as happily when they are all in the same place
## — or when a pillar is standing where the player spawns, which is a real bug this map
## had and which no count caught.
##
##   xvfb-run -a godot --path . --script tools/screenshot.gd -- --map pg_lobby
##
## Needs a real rendering context, so it does NOT run under `--headless`; `xvfb-run` is
## how it runs on a machine with no display. It writes into `screenshots/`, which is
## gitignored — the frame is evidence for a review, not an asset.

const OUT_DIR := "screenshots"

const MAPS := {
	"pg_lobby": "res://maps/pg_lobby.tscn",
	"pg_surf_intro": "res://maps/pg_surf_intro.tscn",
	"pg_bhop_intro": "res://maps/pg_bhop_intro.tscn",
}

var _shots: Array[Dictionary] = []
var _index := 0
var _camera: Camera3D = null


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--map")
	var id := args[index + 1] if index >= 0 and index + 1 < args.size() else "pg_lobby"

	if not MAPS.has(id):
		push_error("no such map: %s. Known: %s" % [id, str(MAPS.keys())])
		quit(1)
		return

	var scene: Resource = load(MAPS[id])

	if not (scene is PackedScene):
		push_error("%s is not a PackedScene" % MAPS[id])
		quit(1)
		return

	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	root.add_child((scene as PackedScene).instantiate())

	# The map builds its own sun, but not a sky or any ambient light — a server has no
	# use for either. Without them every surface facing away from the sun is pure black,
	# which is a screenshot that says nothing about the shape of anything.
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = Sky.new()
	environment.sky.sky_material = ProceduralSkyMaterial.new()
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.6
	env.environment = environment
	root.add_child(env)

	_camera = Camera3D.new()
	_camera.fov = 70.0
	_camera.far = 800.0
	root.add_child(_camera)

	_shots = _shots_for(id)


## Angles per map, because a 200 m sandbox with two courses in opposite corners has
## nothing useful to say from one camera.
func _shots_for(id: String) -> Array[Dictionary]:
	if id != "pg_lobby":
		return [
			{"name": "%s_overview" % id, "from": Vector3(-90, 70, 90), "at": Vector3(0, 8, 0)},
			{"name": "%s_eye" % id, "from": Vector3(-20, 4, 30), "at": Vector3(0, 6, 0)},
		]

	var course := Vector3(60.0, 6.0, 20.0)
	var tower := Vector3(-60.0, 7.0, 60.0)

	return [
		# The whole plate, so the two courses can be seen to be in opposite corners and
		# the middle can be seen to be empty, which is what a sandbox is for.
		{"name": "pg_lobby_overview", "from": Vector3(-150, 130, 150), "at": Vector3(0, 4, 0)},
		# Eye level in the middle, which is where a player actually stands.
		{"name": "pg_lobby_eye", "from": Vector3(-10, 2.0, 20), "at": Vector3(20, 6, -10)},
		# Bonus 1: the jump course, along its length.
		{"name": "pg_lobby_course", "from": Vector3(78, 14, 66), "at": course},
		# Bonus 2: the tower, from above its top and well out from it.
		#
		# [b]Both parts matter and the first attempt got both wrong.[/b] From below, the
		# spiral's far side is hidden behind the pillar and the sandbox wall cuts the
		# frame in half at exactly the height the platforms are; from close in, a 70
		# degree lens puts the top of the tower off the top of the picture. Looking
		# DOWN at it from outside is the only angle that shows a spiral to be a spiral
		# rather than a scattering of slabs.
		{"name": "pg_lobby_tower", "from": Vector3(-36, 21, 84), "at": tower},
		# The tower's base at eye height, from just off the pad.
		#
		# Shot from BESIDE it rather than from the spawn point looking along the course.
		# From the spawn, a dev-textured spiral is a few identical slabs against the sky
		# with nothing to give them a scale — which is honestly what a player sees and
		# is useless as evidence. From the side, the pad, the pillar and the first turn
		# are all in one frame and a person can tell whether the first jump is a jump.
		{"name": "pg_lobby_tower_eye", "from": Vector3(-72, 5.0, 48), "at": Vector3(-59, 6.0, 61)},

		# Bonus 3, the circuit. Two angles, because the two things worth looking at are
		# opposite: whether the lap reads as a closed loop round the whole plate (from
		# high above the corner), and whether the road reads as a road at a driver's
		# height (down the start/finish straight, from the grid).
		{"name": "pg_lobby_circuit", "from": Vector3(-120, 105, 130), "at": Vector3(0, 0, 30)},
		{"name": "pg_lobby_circuit_grid", "from": Vector3(-26, 3.0, 82), "at": Vector3(40, 2.0, 82)},
	]


var _wait := 0
var _armed := false


## [b]Frame-counted rather than awaited.[/b] `SceneTree._process` is expected to return a
## bool synchronously; making it a coroutine returns a signal object instead, which is
## truthy, so the tree quits on the first frame and writes nothing. That is what
## game-arena's first version of this file did and the reason its comment says so.
func _process(_delta: float) -> bool:
	if _index >= _shots.size():
		return true

	if _wait > 0:
		_wait -= 1
		return false

	if not _armed:
		var shot: Dictionary = _shots[_index]
		_camera.position = shot["from"]
		_camera.look_at(shot["at"], Vector3.UP)
		_armed = true
		# Three frames before grabbing. The viewport's texture is the last COMPLETED
		# frame, so grabbing in the same frame the camera moved saves the previous shot
		# under the new shot's name — which looks exactly like a camera that did not
		# move.
		_wait = 3
		return false

	var image := root.get_texture().get_image()
	var path := OUT_DIR.path_join("%s.png" % _shots[_index]["name"])
	image.save_png(path)
	print("wrote %s (%d x %d)" % [path, image.get_width(), image.get_height()])

	_index += 1
	_armed = false
	return false
