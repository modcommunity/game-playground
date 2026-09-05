class_name PlaygroundClient
extends Node

## Boots a playable playground: one local player, a camera, a HUD, a spawn menu and
## the keys.
##
## [b]Separate from [Playground] on purpose.[/b] The playground is the simulation and
## runs headless — that is what `examples/headless_playground.tscn` drives, and it has
## no camera, no HUD and no input. This is everything a person needs on top of it, and
## a dedicated server simply never loads it.
##
## [b]The bindings are the sandbox ones[/b], because that is the game this one is asking
## to be compared with and a sandbox with its own scheme is a sandbox nobody can pick
## up. Two mouse buttons that mean different things depending on what is in your
## hands, a menu you hold open, and a spawn that happens the moment you click a prop:
##
## [codeblock]
## Q (hold)     the spawn menu. Release to close; tap to pin it open
## Mouse 1      the tool's primary: grab and hold, or punt
## Mouse 2      the tool's secondary: freeze what is held, or pull and carry
## Wheel        how far out the physics gun holds a prop
## Shift+mouse  turn the prop the physics gun is holding
## E            spawn the prop the menu last armed, again
## R            unfreeze everything you have frozen
## Z            undo your last spawn
## 1 / 2 / 3    physics gun / gravity gun / cycle the weapons you have
## T            switch track: the sandbox, or the course in the corner
## Tab          cycle style      M   next map
## C V X B      practice checkpoints: save, go to, cycle, forget
## [/codeblock]

const CHANNEL := "playground.client"

## Ids the tools are addressed by, here and in [PlaygroundSpawnMenu].
const TOOL_PHYS := &"phys"
const TOOL_GRAV := &"grav"

## How long Q may be held before releasing it closes the menu.
##
## [b]A tap pins, a hold does not.[/b] Both are wanted and they are the same key in
## in those sandboxes: holding it is how you glance at the menu without losing your place,
## and tapping it is how you leave it up while you build. A quarter of a second is
## comfortably longer than a click and comfortably shorter than a look.
const MENU_TAP_SECONDS := 0.25

## Where a spawned prop appears, in metres in front of the eye.
const SPAWN_REACH := 3.0

## The map to open on if the configuration names none. A client has to be somewhere.
const FALLBACK_MAP := &"pg_lobby"

@export var player_id: StringName = &"local"
@export var display_name: String = "Player"

## Configuration handed to the [Playground] this builds, or null for the defaults.
##
## [b]Forwarded rather than set afterwards.[/b] `Playground._ready` layers the config
## and loads `initial_map` from it, and both happen inside `add_child` — so anything
## assigned after that is assigned to a game that has already booted on the old
## values. It is also the only way a test can boot a real client without it writing
## records into the user's data directory.
@export var config: PlaygroundConfig = null

## A JSON file to layer over [member config]. Passed straight through.
@export var config_file: String = ""

var playground: Playground = null
var player: PlaygroundPlayer = null
var hud: PlaygroundHud = null
var camera: Camera3D = null

var screens: DotScreenStack = null
var menu: PlaygroundSpawnMenu = null

## Which prop the spawn key places. Armed by the menu.
var selected_prop: StringName = &"crate"

## Which tool is in hand: [constant TOOL_PHYS], [constant TOOL_GRAV], or a weapon id.
var tool: StringName = TOOL_PHYS

## The weapon in hand, when [member tool] is neither of the two built-in guns.
##
## [b]Instantiated per equip, not held as a pool.[/b] A weapon is a script with state —
## a charge, a cooldown, what it is holding — and a shared instance would carry one
## player's cooldown into another's hands the moment this becomes a server.
var weapon: PlaygroundWeapon = null

## Where the style key is in the list.
var _style_index: int = 0

## Whether the physics gun's button is down.
var _holding: bool = false

## Whether the gravity gun is pulling.
var _pulling: bool = false

## Whether Shift is down, which turns mouse motion into prop rotation.
var _rotating: bool = false

## When Q went down, so a release can tell a tap from a hold.
var _menu_down_at: float = 0.0

## Whether the menu is up because it was tapped rather than because Q is still down.
var _menu_pinned: bool = false


func _ready() -> void:
	playground = Playground.new()
	playground.name = "Playground"
	playground.config = config
	playground.config_file = config_file
	add_child(playground)

	# The playground loads its own first map and this waits for it, rather than
	# loading one here.
	#
	# [b]Two reasons, and the second is the one that bites.[/b] `initial_map` is
	# layered configuration, so a client that picked its own would ignore `--pg-map`
	# and every server-side default with it. And loading it twice builds the whole
	# map twice — the second change tears the first down, which frees the geometry
	# anything already placed on it is standing on.
	#
	# By this line `Playground._ready` has run as far as its own `await`, so the
	# config is layered and final while the map is not up yet: waiting on the signal
	# cannot miss it.
	#
	# `booted` is checked BEFORE the await, and that is not defensive. `change_map`
	# can complete without ever suspending — a built-in map is a scene already in the
	# build — in which case the playground finishes booting inside `add_child` above
	# and `ready_for_players` has already been emitted by the time this line runs.
	# Awaiting it then waits for ever, and the symptom is a black screen with no
	# error at all: no camera, no HUD, no player. It is the family's own fan-out trap
	# in its smallest form, and this file had it for exactly one screenshot.
	if not playground.booted:
		await playground.ready_for_players

	if playground.maps.current == null:
		var loaded: DotResult = await playground.change_map(FALLBACK_MAP)

		if not loaded.ok:
			DotLog.error(CHANNEL, "could not load the first map", {
				"why": loaded.error.message
			})
			return

	player = playground.add_player(player_id, display_name)
	player.samples_input = true

	# The sampler is built in the player's _ready, which has already run — so it is
	# built here instead. Setting the flag alone would leave a player who is
	# supposed to be driving and never samples anything, which reads as the input
	# being broken.
	player.sampler = DotFpsSampler.new(player.controller.tunables)
	DotFpsSampler.register_default_actions(player.sampler)

	_build_view()

	hud = PlaygroundHud.new()
	hud.name = "Hud"
	add_child(hud)
	hud.bind(playground, player_id)
	_sync_hud()

	# After the HUD, because for a CanvasItem tree order is draw order and a menu
	# that renders under the speedometer is one whose bottom row cannot be clicked.
	_build_screens()

	set_process(true)


func _build_view() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 100.0
	camera.current = true
	player.add_child(camera)

	var view := DotFpsView.new()
	view.name = "View"
	player.add_child(view)

	player.view = view


func _build_screens() -> void:
	screens = DotScreenStack.new()
	screens.name = "Screens"
	# Captured whenever nothing is open, which is what puts the mouse back on the
	# view the instant the menu closes. Doing it by hand in the close path means
	# every future screen has to remember to.
	screens.idle_mouse_mode = DotScreen.Mouse.CAPTURED
	add_child(screens)

	var ready := screens.setup()

	if not ready.ok:
		DotLog.error(CHANNEL, "the screen stack could not be set up", {
			"why": ready.error.message
		})
		return

	menu = PlaygroundSpawnMenu.new()
	menu.name = "SpawnMenu"
	menu.catalogue = playground.props.catalogue
	menu.weapons = playground.weapons
	menu.selected = selected_prop
	menu.tool = tool
	menu.prop_chosen.connect(_on_prop_chosen)
	menu.weapon_chosen.connect(_on_weapon_chosen)
	menu.tool_chosen.connect(_on_tool_chosen)
	menu.action_requested.connect(_on_menu_action)

	var registered := screens.register(menu)
	DotLog.result(CHANNEL, "registering the spawn menu", registered)


func _process(_delta: float) -> void:
	if player == null or camera == null:
		return

	# The camera follows the SIMULATED eye position rather than being parented to
	# something the movement drives. Parenting works and hides a real difference: the
	# simulation runs at a fixed tick and the camera is drawn every frame, so a
	# parented camera steps once per tick and judders between them.
	camera.global_position = player.eye_position()
	camera.global_rotation = Vector3(
		deg_to_rad(player.controller.state.pitch),
		deg_to_rad(player.controller.state.yaw),
		0.0
	)


## Tells the HUD what is in the player's hands.
##
## Pushed rather than polled: the HUD is bound to the simulation and a spectator or a
## replay has no client holding anything, so it cannot go and look.
func _sync_hud() -> void:
	if hud != null:
		hud.set_tool(_tool_name(), selected_prop)


## Whether a menu is up, in which case the mouse belongs to it.
func _menu_is_open() -> bool:
	return screens != null and screens.any_open()


# --- Input -----------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if player == null:
		return

	if event is InputEventMouseMotion:
		_on_mouse_motion(event as InputEventMouseMotion)
		return

	# Everything below moves the world. A menu is up, the mouse is a cursor, and a
	# click on a prop button must not also punt whatever is behind it.
	#
	# Checked here rather than relying on the screen consuming the event: the stack
	# blocks what reaches the GUI, and a click that lands on the menu's own
	# background is unhandled by design and would arrive here.
	if _menu_is_open() and not _is_menu_key(event):
		return

	if event is InputEventMouseButton:
		_on_mouse_button(event as InputEventMouseButton)
		return

	if not (event is InputEventKey):
		return

	var key := event as InputEventKey

	if key.physical_keycode == KEY_SHIFT:
		# Held, not toggled, and read on both edges: a rotate that stayed on after
		# the key came up would turn the prop every time the player looked around.
		_rotating = key.pressed
		return

	if key.physical_keycode == KEY_Q:
		_on_menu_key(key)
		return

	if not key.is_pressed() or key.is_echo():
		return

	match key.physical_keycode:
		KEY_E:
			_spawn()
		KEY_Z:
			playground.props.undo(player_id)
		KEY_R:
			_unfreeze_all()
		KEY_1:
			_set_tool(TOOL_PHYS)
		KEY_2:
			_set_tool(TOOL_GRAV)
		KEY_3:
			_cycle_weapon()
		KEY_T:
			_cycle_track()
		KEY_TAB:
			_cycle_style()
		KEY_M:
			_next_map()
		KEY_C:
			_save_checkpoint()
		KEY_V:
			_load_checkpoint()
		KEY_X:
			_cycle_checkpoint()
		KEY_B:
			_clear_checkpoints()
		KEY_ESCAPE:
			# Only when no screen is up. The stack's own back handling pops the menu,
			# and a second handler here would pop it and release the mouse in one
			# press.
			if not _menu_is_open():
				Input.mouse_mode = (
					Input.MOUSE_MODE_VISIBLE
					if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
					else Input.MOUSE_MODE_CAPTURED
				)


## Q is the one key that still means something while the menu is open.
func _is_menu_key(event: InputEvent) -> bool:
	return event is InputEventKey and (
		(event as InputEventKey).physical_keycode == KEY_Q
	)


func _on_mouse_motion(event: InputEventMouseMotion) -> void:
	if _menu_is_open():
		return

	if _rotating and _holding:
		# Turning the prop instead of the view, which is what makes the physics gun
		# a building tool. `DotPhysGun` stores the orientation relative to the view,
		# so this composes with looking around rather than fighting it.
		player.phys_gun.rotate_held(-event.relative.x * 0.4, -event.relative.y * 0.4)
		return

	if player.sampler == null:
		return

	# Handed to the sampler, which accumulates it and spends it on the next
	# simulated tick. Applying it to the view here would make the look a function of
	# how many mouse events happened to land in a frame.
	player.sampler.handle_event(event)


func _on_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_LEFT:
			if event.pressed:
				_primary_down()
			else:
				_primary_up()
		MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_secondary_down()
			else:
				_secondary_up()
		MOUSE_BUTTON_WHEEL_UP:
			if _holding:
				player.phys_gun.push(1.0, 0.1)
		MOUSE_BUTTON_WHEEL_DOWN:
			if _holding:
				player.phys_gun.push(-1.0, 0.1)


## Q down opens the menu; Q up closes it unless the press was a tap.
##
## [b]One key, two behaviours, and they are not a toggle.[/b] Holding shows the menu
## for as long as you hold it — a glance, with your place kept. Tapping leaves it up,
## which is what you want while building; tapping again puts it away. A plain toggle
## loses the glance, and a plain hold means you cannot let go of the mouse.
func _on_menu_key(key: InputEventKey) -> void:
	if screens == null or menu == null or key.is_echo():
		return

	var id := menu.screen_id()

	if key.pressed:
		_menu_down_at = _now()

		if not screens.is_open(id):
			# Whatever the tools were doing, they stop: the mouse is about to become
			# a cursor, and a physics gun still holding a crate would drag it round
			# the world following a pointer the player is aiming at buttons with.
			_primary_up()
			_secondary_up()
			_rotating = false

			menu.selected = selected_prop
			menu.tool = tool
			screens.push(id)
			_menu_pinned = false

		return

	if _now() - _menu_down_at >= MENU_TAP_SECONDS:
		screens.pop(id)
		_menu_pinned = false
		return

	if _menu_pinned:
		screens.pop(id)
		_menu_pinned = false
		return

	_menu_pinned = true


## Wall-clock seconds. Presentation only — nothing here is timed, compared or ranked,
## which is why this is not the simulated clock the timer counts in.
func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


# --- The tools -------------------------------------------------------------

func _space() -> PhysicsDirectSpaceState3D:
	return player.get_world_3d().direct_space_state


func _view_basis() -> Basis:
	return Basis(Quaternion.from_euler(Vector3(
		0.0, deg_to_rad(player.controller.state.yaw), 0.0
	)))


func _set_tool(id: StringName) -> void:
	if tool == id:
		return

	# Everything is let go of on the way out. A gravity gun that kept carrying a
	# crate after the player switched to the physics gun would have two tools
	# holding one prop, which `DotPropInstance.held_by` refuses — so the physics gun
	# would simply do nothing and there would be nothing on screen to say why.
	_primary_up()
	_secondary_up()

	if weapon != null:
		weapon.holster()
		weapon = null

	tool = id

	if id != TOOL_PHYS and id != TOOL_GRAV:
		# A weapon. Built from its definition, which loads its script by path — see
		# PlaygroundWeapons for why a path and not a class.
		var def := playground.weapon_def(id)
		weapon = PlaygroundWeapons.make(def)

		if weapon == null:
			# The reason is already in the log, in more detail than a notice can
			# carry. Falling back to the physics gun rather than leaving the player
			# holding nothing whose buttons silently do nothing.
			tool = TOOL_PHYS

			if hud != null:
				hud.notice("That weapon could not be loaded.")
		else:
			weapon.equip(playground, def)
			weapon.wielder = player_id
			weapon.armed = selected_prop

	if menu != null:
		menu.tool = tool

	_sync_hud()

	if hud != null:
		hud.notice(_tool_name().capitalize())


## What is in hand, in words. A weapon's own name, or one of the two guns'.
func _tool_name() -> String:
	if weapon != null and weapon.def != null:
		return weapon.def.name_or_id()

	return PlaygroundSpawnMenu.name_of_tool(tool)


## Steps through the weapons this server offers, and back to the physics gun.
##
## [b]Round-trips through the physics gun rather than cycling weapons only.[/b] The
## physics gun is the tool a sandbox is actually played with; a cycle that could not
## reach it would leave a player who pressed 3 twice holding a remover with no
## obvious way back.
func _cycle_weapon() -> void:
	if playground.weapons.is_empty():
		if hud != null:
			hud.notice("This server has no weapons.")
		return

	var index := -1

	for i in range(playground.weapons.size()):
		if playground.weapons[i].id == tool:
			index = i
			break

	if index + 1 >= playground.weapons.size():
		_set_tool(TOOL_PHYS)
		return

	_set_tool(playground.weapons[index + 1].id)


func _primary_down() -> void:
	if weapon != null:
		_report(weapon.primary(
			_space(), player.eye_position(), player.aim_direction()
		))
		return

	match tool:
		TOOL_PHYS:
			_grab()
		TOOL_GRAV:
			_punt()


func _primary_up() -> void:
	if tool == TOOL_PHYS and _holding:
		player.phys_gun.release()
		_holding = false


func _secondary_down() -> void:
	if weapon != null:
		_report(weapon.secondary(
			_space(), player.eye_position(), player.aim_direction()
		))
		return

	match tool:
		TOOL_PHYS:
			# Freezing is the physics gun's right-click everywhere it exists, and it lets
			# go of what it froze — which is what makes building one-handed.
			if _holding:
				var frozen := player.phys_gun.freeze_held()
				_holding = false

				if not frozen.ok and hud != null:
					hud.notice(frozen.error.message)
		TOOL_GRAV:
			var pulled := player.grav_gun.pull(
				_space(), player.eye_position(), player.aim_direction(),
				playground.may_touch_others()
			)
			_pulling = pulled.ok

			if not pulled.ok and hud != null:
				hud.notice(pulled.error.message)


func _secondary_up() -> void:
	if tool == TOOL_GRAV and _pulling:
		player.grav_gun.drop()
		_pulling = false


## Puts a refusal on the HUD, and says nothing about a success.
##
## An empty message is a refusal the player has already been told about through
## another route — `DotPropSpawner.refused`, which the HUD is listening to — and
## printing it again would put the same line on screen twice.
func _report(result: DotResult) -> void:
	if result.ok or hud == null or result.error.message == "":
		return

	hud.notice(result.error.message)


func _grab() -> void:
	var grabbed := player.phys_gun.grab(
		_space(), player.eye_position(), player.aim_direction(), _view_basis(),
		playground.may_touch_others()
	)

	_holding = grabbed.ok

	if not grabbed.ok and hud != null:
		hud.notice(grabbed.error.message)


func _punt() -> void:
	player.grav_gun.punt(
		_space(), player.eye_position(), player.aim_direction(),
		playground.may_touch_others()
	)
	_pulling = false


func _physics_process(delta: float) -> void:
	if player == null:
		return

	# Held from the physics loop, because the spring writes a velocity the solver
	# consumes on this step. Doing it in _process writes a velocity that a variable
	# number of physics steps then apply, and the prop jitters at exactly the rate
	# the frame time varies.
	if _holding:
		player.phys_gun.hold(
			player.eye_position(), player.aim_direction(), _view_basis(), delta
		)

	if _pulling:
		player.grav_gun.carry(
			player.eye_position(), player.aim_direction(), delta
		)

	# A weapon gets a tick whether or not a button is down: a charge, a cooldown and
	# a beam are all things that have to run between clicks, and a weapon that were
	# only ticked while firing could not have any of them.
	if weapon != null:
		weapon.tick(
			_space(), player.eye_position(), player.aim_direction(), delta
		)


# --- Props -----------------------------------------------------------------

func _spawn() -> void:
	if selected_prop == &"":
		if hud != null:
			hud.notice("Nothing armed. Hold Q and pick something.")
		return

	var at := player.eye_position() + player.aim_direction() * SPAWN_REACH
	playground.props.spawn(selected_prop, player_id, at)


func _on_prop_chosen(prop_id: StringName) -> void:
	selected_prop = prop_id

	# The weapon follows what the menu armed, which is what makes the launcher fire
	# a beach ball or a boulder without a second list of ammunition.
	if weapon != null:
		weapon.armed = prop_id

	_sync_hud()
	_spawn()


func _on_weapon_chosen(weapon_id: StringName) -> void:
	_set_tool(weapon_id)


func _on_tool_chosen(tool_id: StringName) -> void:
	_set_tool(tool_id)


func _on_menu_action(action: StringName) -> void:
	match action:
		&"undo":
			if not playground.props.undo(player_id) and hud != null:
				hud.notice("Nothing to undo.")
		&"unfreeze":
			_unfreeze_all()
		&"clear":
			var removed := playground.props.clear_player(
				player_id, DotPropSpawner.REASON_PLAYER
			)

			if hud != null:
				hud.notice("Removed %d prop%s." % [
					removed, "" if removed == 1 else "s"
				])


## Thaws every prop this player has frozen.
##
## [b]Never refused, deliberately.[/b] `DotPropSpawner.may_freeze` gates freezing
## against `per_player_frozen`, and the reverse has no limit to check — a cap that
## stopped somebody tidying up would be a limit fighting its own purpose.
func _unfreeze_all() -> void:
	var thawed := 0

	for prop in playground.props.props_of(player_id):
		if not prop.frozen:
			continue

		DotPhysGun.set_frozen(prop, false)
		thawed += 1

	if hud != null:
		hud.notice("Unfroze %d prop%s." % [thawed, "" if thawed == 1 else "s"])


# --- Practice ---------------------------------------------------------------
#
# Saving is free; teleporting is what costs the run. That asymmetry is the whole of
# practice mode, and it is why the two are separate keys rather than one toggle.

func _checkpoints() -> DotTimerCheckpoints:
	return playground.timers.checkpoints_for(player_id)


func _save_checkpoint() -> void:
	var state := player.controller.state
	var saved := _checkpoints().save(
		state.position, state.velocity, state.yaw, state.pitch,
		state.is_grounded(), state.is_crouched()
	)

	if hud == null:
		return

	if not saved.ok:
		hud.notice(saved.error.message)
		return

	hud.notice("Checkpoint %d saved" % _checkpoints().count())


func _load_checkpoint() -> void:
	var checkpoints := _checkpoints()
	var checkpoint := checkpoints.load_current()

	if checkpoint == null:
		if hud != null:
			hud.notice("No checkpoints. C saves one.")
		return

	# Restored through the player's own teleport, which abandons the run — a
	# teleport that kept the clock running is the simplest possible cheat on any
	# timed map, and a checkpoint restore is a teleport.
	player.teleport(checkpoint.position, checkpoint.yaw)
	player.controller.state.velocity = checkpoint.velocity
	player.controller.state.pitch = checkpoint.pitch

	if hud != null:
		hud.notice("Checkpoint %d of %d" % [
			checkpoints.index + 1, checkpoints.count()
		])


func _cycle_checkpoint() -> void:
	var checkpoints := _checkpoints()

	if checkpoints.next() == null:
		return

	if hud != null:
		hud.notice("Checkpoint %d of %d" % [
			checkpoints.index + 1, checkpoints.count()
		])


func _clear_checkpoints() -> void:
	_checkpoints().clear()

	if hud != null:
		# Said explicitly, because it is the thing a player will assume it does:
		# clearing the set does not launder a run that already used one.
		hud.notice("Checkpoints cleared. The current run is still flagged.")


# --- Styles, tracks and maps -----------------------------------------------

func _cycle_style() -> void:
	var styles := playground.timers.styles_in_order()

	if styles.is_empty():
		return

	_style_index = (_style_index + 1) % styles.size()

	var chosen := styles[_style_index]

	if playground.set_player_style(player_id, chosen.id) and hud != null:
		hud.notice("Style: %s" % chosen.display_name)


## Switches between the sandbox and whatever courses this map has.
##
## [b]The key that makes the minigame reachable at all.[/b] `pg_lobby` is a sandbox
## on the main track and a jump course on bonus 1, which is what lets one map be both
## without a timer running over somebody who is building — and without this the bonus
## track would be a zone set nothing could ever enter.
func _cycle_track() -> void:
	if player.timer == null:
		return

	var tracks := playground.tracks_on_this_map()

	if tracks.size() < 2:
		if hud != null:
			hud.notice("This map has one track.")
		return

	var index := tracks.find(player.timer.track)
	var next := tracks[(index + 1) % tracks.size()]

	if not player.timer.set_track(next):
		return

	# Moved to the new track's spawn. Staying put would leave a player standing in
	# the sandbox with a course timer that can never start, which looks exactly like
	# a timer that is broken.
	playground.spawn_player(player_id)

	if hud != null:
		hud.notice("Track: %s" % DotTimerTrack.name_of(next))


func _next_map() -> void:
	var next := playground.maps.rotation.choose(playground.players.size())

	if next == null:
		return

	await playground.change_map(next.id)
