class_name PlaygroundPlayer
extends CharacterBody3D

## One player: movement, view, the timer, and the tools.
##
## [b]This class is the bridge, and the bridges are where the bugs are.[/b] Every
## addon here is complete and tested on its own; what has never run is the joins
## between them, and the family's own history says that is where everything is found.
## Concretely, this file is the only place that knows:
##
## - the timer must be ticked from the **movement** loop, once per simulated tick,
##   with the position the movement just produced — not from `_process`, and not
##   before the move;
## - a style has two halves that must be applied together
##   ([code]DotFpsStyle[/code] and [code]DotTimerStyle[/code]);
## - a zone's effects are the game's to apply, because the timer will not touch a
##   player;
## - a prespeed limit runs *inside* the simulation, so it is applied between the
##   move and the next tick rather than when a signal happens to arrive.

const CHANNEL := "playground.player"

## The run finished. The world files it; the player just reports.
signal finished(run: DotTimerRun)

## A zone asked for something only this class can do.
signal teleport_requested(to: Vector3, yaw: float)

@export var player_id: StringName = &"local"
@export var display_name: String = "Player"

## Whether this player's timer may file records. Server-side only.
@export var authoritative: bool = false

## Whether a command is sampled from the input devices each tick.
##
## True for the person at the keyboard, false for a bot, a replay and every remote
## player. It is a property of the PLAYER rather than of the build, because a client
## holds one of each: their own, which samples, and everybody else's, which does not.
@export var samples_input: bool = false

var controller: DotFpsController = null

## The third-person controller, when this player has one. See [method set_view_mode].
var tps: DotTpsController = null

## Which of the two is driving. Built only on a player that can have a camera.
var controller_switch: DotPlayerControllerSwitch = null

## The dot-player component root the two controllers bind through.
var player_node: DotPlayer = null

## The body other people see. Null until [method build_character] is called.
var character: PlaygroundCharacter = null

## The locomotion state machine over that body.
var anim: DotPlayerAnimDriver = null
var view: DotFpsView = null

## Turns devices into commands, for a locally controlled player only.
var sampler: DotFpsSampler = null

## See [method class_base_tunables].
var _class_base: DotFpsTunables = null

## This player's timer. Owned by the world's [DotTimerManager], not by this node.
var timer: DotTimer = null

## The movement half of the style in force.
var movement_style: DotFpsStyle = null

## The ranking half.
var timer_style: DotTimerStyle = null

## The tools, when the game has dot-props.
var phys_gun: DotPhysGun = null
var grav_gun: DotGravGun = null

## Whether this player is in a vehicle, and so is not walking.
##
## [b]Read-only from outside: [method set_riding] is the switch.[/b] It exists as a flag
## on the PLAYER rather than as a lookup in the vehicle spawner because everything that
## has to know is on this side — the tick, the sampler, the net behaviour and the HUD —
## and a client has no vehicle spawner at all to ask.
var riding: bool = false

## Set by the world so the timer is ticked with the same clock the movement uses.
## [b]Assigned through, not just stored.[/b] The controller sizes its step from its own
## copy, taken in [method _ready] — so setting this on a player who already exists and
## stopping there runs the game's loop at one rate and that player's movement at
## another. Nothing errors; the player is simply correct on their own screen and wrong
## on everybody else's. A client adopting the server's rate through HELLO is exactly
## that case whenever a player already exists, which is every map change.
var tick_rate: int = 128:
	set(value):
		tick_rate = value
		if controller != null:
			controller.tick_rate = value


func _ready() -> void:
	controller = DotFpsController.new()
	controller.name = "Controller"
	controller.tick_rate = tick_rate

	# EXTERNAL, not LOCAL, even in single player.
	#
	# [b]The game owns the tick, and that is the whole ordering argument.[/b] In
	# LOCAL the controller accumulates frame time and ticks itself, which means the
	# timer would be fed from a signal fired inside somebody else's loop and a bot
	# could not be driven at all. Owning the loop here makes the order explicit —
	# sample, move, then time the tick with the position the move produced — and it
	# is the same shape a dot-net bridge and a dedicated server use, so nothing has
	# to be rearranged when one arrives.
	controller.drive = DotFpsController.Drive.EXTERNAL
	controller.tunables = _tunables()

	# body_ref left unset, so it defaults to the parent — this node, which is the
	# Node3D the movement drives. `DotNodeRef.of_self()` looks equivalent and is not:
	# it resolves to the CONTROLLER, which is a plain Node, and setup() then refuses
	# with "the player body must be a Node3D" and the whole player never simulates.
	add_child(controller)

	controller.simulated.connect(_on_simulated)

	if samples_input:
		sampler = DotFpsSampler.new(controller.tunables)
		DotFpsSampler.register_default_actions(sampler)


## Gives this player a third-person controller and the switch that hands between them.
##
## [b]The sandbox is where third person belongs, and the other two 3D games are where it
## does not.[/b] game-g2gfast has a third-person view already and it is deliberately
## *cosmetic* — `G2GCamera` flips between two cameras over one motor, because a run set in
## third person has to be comparable with one set in first and a second movement model
## would make it a different game. game-arena is lag-compensated and analytic: its server
## and its clients agree because there is exactly one motor to agree about. A sandbox has
## neither constraint — nothing here is ranked and nothing is rewound — so it is the one
## place a genuinely different motor is free.
##
## [b]Built on demand, not for everybody.[/b] `DotTpsController` drives a
## `CharacterBody3D` through Godot's physics, which is real per-tick cost, and a
## dedicated server full of remote players that will never be looked at through a camera
## should not pay it. Only a player that samples input gets one.
##
## Returns whether it was built.
func build_view_switch() -> bool:
	if tps != null:
		return true

	if not samples_input:
		return false

	# [b]The component root both controllers bind through.[/b] `DotPlayerController` is a
	# `DotPlayerComponent`: it finds its player by walking up, reads the body from it and
	# refuses to run unbound. Without this node the third-person controller has no body to
	# ask for and logs "no CharacterBody3D for this player" once per activation.
	player_node = DotPlayer.new()
	player_node.name = "Player"
	player_node.player_key = String(player_id)
	player_node.is_local = true
	# [b]No `roster_ref`, deliberately.[/b] `DotPlayer` binds on a key alone when it
	# cannot find a roster, and everything the controllers ask it for — the body, whether
	# the player is alive — is answered without one. Pointing it at the stack's roster
	# would mean either a node path across two subtrees or turning
	# `register_service` on, and a registry name is global to the process: two servers in
	# one editor session would collide on it, which is the reason the stacks turn it off.
	# The body is this node, which is why it is a CharacterBody3D at all.
	player_node.body_ref = DotNodeRef.of_path(NodePath(".."))
	add_child(player_node)

	tps = DotTpsController.new()
	tps.name = "ThirdPerson"
	tps.controller_id = &"tp"
	tps.tunables = DotTpsTunables.new()
	add_child(tps)

	# [b]The id BEFORE the switch is added, and that ordering is the bug.[/b]
	# `DotPlayerControllerSwitch._ready` runs `refresh()` and activates its default the
	# moment it enters the tree — so a controller still carrying an empty `controller_id`
	# at that instant is registered under its class name instead, `default_controller`
	# names something that is not there, and the switch falls back to whatever it found
	# first. The sandbox opened in third person and the only symptom was the camera.
	controller.controller_id = &"fp"

	controller_switch = DotPlayerControllerSwitch.new()
	controller_switch.name = "ViewSwitch"
	# First person is what a sandbox opens in: the tools are aimed down a crosshair and a
	# physics gun held over the shoulder is a different, worse tool.
	controller_switch.default_controller = &"fp"
	add_child(controller_switch)

	return true


## Gives this player a visible body and the locomotion state machine that drives it.
##
## [b]dot-player-char's visual half had no implementation in any game in this family.[/b]
## Five projects installed the addon, four built a catalogue, and `DotPlayerCharVisual` —
## the abstract node the whole addon exists to fill — was subclassed nowhere. It survived
## because every game was first-person and nobody sees their own body; the third-person
## camera is what made it visible, and the first frame through it was an empty view four
## metres behind nothing.
##
## [param colour] is the player's own, so two people in a sandbox are told apart.
func build_character(def: DotPlayerCharDef, colour: Color) -> void:
	if def == null:
		return

	if character == null:
		character = PlaygroundCharacter.new()
		character.name = "Character"
		add_child(character)

	character.build_for(def, colour)

	if anim == null:
		anim = DotPlayerAnimDriver.new()
		anim.name = "Animation"
		# [b]Driven from here rather than by itself.[/b] `auto_drive` reads the body's
		# transform once a frame and differentiates it, which is a second opinion about
		# how fast the player is going — and this game already has an authoritative one
		# on the controller. Two sources of "am I running" disagree exactly when a
		# correction lands, which is when an animation pop is most visible.
		anim.auto_drive = false
		anim.anim_set = DotPlayerAnimSet.locomotion()
		add_child(anim)

	# First person hides the body the moment it is built: a player looking through their
	# own eyes must not see the inside of their own head.
	character.set_shown(view_mode() == &"tp")


## Advances the locomotion state from the movement that just happened.
##
## Called from the game's tick, after the controller has simulated, for the ordering
## reason every other consumer here follows: a state machine fed the position a player
## was at is a state machine one tick behind the player.
func drive_character(delta: float) -> void:
	if anim == null or controller == null:
		return

	var state := controller.state
	var _clip := anim.drive({
		"speed": Vector2(state.velocity.x, state.velocity.z).length(),
		"vertical": state.velocity.y,
		"on_floor": state.is_grounded(),
		"crouched": state.crouch_fraction > 0.5,
		"facing": deg_to_rad(state.yaw),
		"alive": true,
	}, delta)

	if character != null:
		character.set_stance(state.crouch_fraction > 0.5)
		# The body faces where the player is looking. Without this the capsule keeps the
		# rotation it was built with and a third-person camera orbiting a player shows a
		# character who never turns — which reads as the model being broken rather than
		# as a missing line.
		character.face(deg_to_rad(state.yaw))


## Switches between the first- and third-person controllers.
##
## [b]The handover is the point, and it is the switch's rather than this game's.[/b]
## Position, velocity and look angles cross; the motor state does not, because a
## first-person air-strafe has no counterpart in a third-person motor and any mapping
## between them is a lie. Returns the id now driving.
func set_view_mode(third_person: bool) -> StringName:
	if controller_switch == null:
		return &"fp"

	var wanted := &"tp" if third_person else &"fp"
	var res := controller_switch.activate(wanted)
	var now := StringName(str(res.value)) if res.ok else controller_switch.active_id()

	# The body is shown in third person and hidden in first, which is the whole reason
	# `DotPlayerCharVisual.set_shown` exists.
	if character != null:
		character.set_shown(now == &"tp")

	return now


## Which controller is driving.
func view_mode() -> StringName:
	return controller_switch.active_id() if controller_switch != null else &"fp"


## Sets which collision layers this player's movement sweeps against.
##
## [b]Not `DotFpsTunables`' default of 1.[/b] One means bit 0, which is right only while
## every body in the game is on bit 0 — the state a layout exists to end. Once props,
## entities and vehicles moved to their own layers, a mask of 1 was a player who walks
## through every crate, every NPC and every car in the sandbox, and nothing would have
## said so: a sweep that hits nothing is a sweep, not an error.
func use_collision_mask(mask: int) -> void:
	if controller != null and controller.tunables != null:
		controller.tunables.collision_mask = mask


## The movement this player was built with, before any class scaled it.
##
## [b]Captured once, and it is what makes applying a class on every respawn safe.[/b] A
## class's `move_speed_scale` is a multiplier; applied to tunables that already carry it
## the product compounds, so four respawns as a 0.8 class is 0.41 of the speed, arrived
## at silently with every number in the inspector looking deliberate.
func class_base_tunables() -> DotFpsTunables:
	if _class_base == null and controller != null and controller.tunables != null:
		_class_base = controller.tunables.duplicate()

	return _class_base


## The movement a bunny-hop and surf server runs.
##
## [b]These are not the addon's defaults and the differences are the whole genre.[/b]
## `auto_hop` on, because the alternative makes the skill a keyboard-hardware contest
## rather than an aiming one. `bhop_speed_cap_scale` at zero, because a cap is what
## those shooters added to *stop* bunny-hopping. `crease_slide` on, because a surf map
## is made of seams. `friction` low and `air_accelerate` high, because that pair is
## what makes a strafe worth making.
func _tunables() -> DotFpsTunables:
	var t := DotFpsTunables.new()

	t.auto_hop = true
	t.bhop_speed_cap_scale = 0.0
	t.crease_slide = true

	t.max_speed = 7.0
	t.accelerate = 10.0
	t.friction = 5.0
	t.stop_speed = 4.0

	t.air_accelerate = 100.0
	t.max_air_wish_speed = 1.0
	t.gravity = 20.0
	t.jump_height = 1.15

	# No coyote time and no jump buffer beyond one tick: on a timed map both are
	# free speed, and a run set with them is not comparable with one set without.
	t.coyote_time = 0.0
	t.jump_buffer_time = 0.0

	t.max_slope_angle = 46.0
	t.step_height = 0.4

	return t


## Puts this player on a style. Both halves, together.
##
## [b]Both, or neither.[/b] Applying only the movement half means a run is timed and
## ranked as "normal" while the player is actually sideways; applying only the ranking
## half means the opposite. Either way the leaderboard is wrong and nothing errors.
func set_style(movement: DotFpsStyle, ranking: DotTimerStyle) -> DotResult:
	movement_style = movement
	timer_style = ranking

	if timer != null:
		timer.set_style(ranking)

	return controller.set_style(movement)


## Moves the player, cancelling any run.
##
## Used by a respawn zone, a teleport zone, an admin, and the spawn on map load.
func teleport(to: Vector3, yaw: float = INF) -> void:
	controller.state.position = to
	controller.state.velocity = Vector3.ZERO

	if is_finite(yaw):
		controller.state.yaw = yaw

	global_position = to

	# The run goes with it. A teleport that kept the clock running is the simplest
	# possible cheat on any timed map, and a respawn zone is a teleport.
	if timer != null:
		timer.stop(DotTimer.REASON_TELEPORT)


func speed() -> float:
	return controller.state.horizontal_speed()


func eye_position() -> Vector3:
	return controller.motor.eye_position(controller.state)


func aim_direction() -> Vector3:
	return DotFpsMotor.aim_for(controller.state.yaw, controller.state.pitch)


# --- The tick --------------------------------------------------------------

## Advances this player by one simulated tick.
##
## Called by [Playground], not by the controller: see the note in [method _ready]
## about who owns the loop.
func simulate(tick: int, delta: float) -> void:
	if sampler != null:
		controller.apply_command(sampler.sample(delta))

	# A rider's movement is TURNED OFF, not ignored, and the sample above still happens.
	#
	# Off, because a controller simulating a player who is parented into a moving vehicle
	# writes its own answer into the state every tick while the vehicle carries the node
	# somewhere else — two authorities over one transform, which reads as the car shaking
	# itself apart at speed. Sampled anyway, because those same keys are what the car is
	# being driven with: `Playground._drive_vehicles` reads the pending command and turns
	# it into throttle and steering.
	if riding:
		return

	controller.simulate_tick(tick, delta)


## Called once per simulated tick, by the controller, after the move.
##
## [b]After the move, and that ordering is the point.[/b] The timer decides whether
## the player crossed a line during this tick, which it works out from where they were
## and where they now are — so it has to be told the position the move produced, not
## the one it started from. Ticking the timer first shifts every time by exactly one
## tick and, worse, shifts it by a different amount at each tickrate.
func _on_simulated(_tick: int, state: DotFpsState) -> void:
	global_position = state.position

	if timer == null:
		return

	# The prespeed limit runs INSIDE the simulation: clamping a player's speed
	# changes where they end up, so it has to happen on the tick, every tick, rather
	# than when a signal is delivered.
	if (
		timer_style != null
		and movement_style != null
		and movement_style.prespeed_limit > 0.0
		# in_zone, not is_inside: is_inside answers only for EFFECT zones and is
		# always false for START, which left this clamp dead. game-g2gfast had the
		# same line; its netcode suite is what found it.
		and timer.in_zone(DotTimerZone.Kind.START)
	):
		state.velocity = DotTimerRules.clamp_prespeed(
			state.velocity, movement_style.prespeed_limit
		)

	var speed_zone := timer.effect(DotTimerZone.Kind.SPEED_LIMIT)

	if speed_zone != null:
		state.velocity = DotTimerRules.apply_speed_limit(state.velocity, speed_zone)


## Gets in or out of a vehicle. Called by the ride's `on_seated` / `on_unseated`.
##
## Both halves matter and the second is the one that is easy to leave out: a player put
## back down after a drive whose velocity was whatever it was when they got in launches
## across the map on their first step.
func set_riding(value: bool) -> void:
	if riding == value:
		return

	riding = value

	if riding:
		controller.state.velocity = Vector3.ZERO
	else:
		# Handed back walking, standing still and in the air. The controller works out
		# on its next tick whether there is ground under them, which is the honest answer
		# — the exit sweep only proved there was room, not that it was a floor.
		controller.state.velocity = Vector3.ZERO
		controller.state.mode = DotFpsState.Mode.AIR


## Copies where the vehicle has carried this player into the movement state.
##
## [b]Without this a passenger is drawn on every other machine at the spot where they got
## in.[/b] The NODE is carried by dot-vehicle, which reparents it into the seat — but the
## timer, the NPC candidate list, the HUD and above all [PlaygroundPlayerNet] all read
## [code]controller.state.position[/code], and nothing was writing it. The failure is
## invisible in one process, because in one process the node is the thing being looked at.
func adopt_ride(at: Vector3, velocity: Vector3) -> void:
	controller.state.position = at
	controller.state.velocity = velocity


## The command this player is about to be simulated with, or was last simulated with.
##
## What a vehicle is driven from. Never null: the controller keeps the last command it
## was given, which is what makes a dropped input a straight line rather than a stop.
func pending_command() -> DotFpsCommand:
	return controller.current_command if controller.current_command != null else DotFpsCommand.new()


## The sample the world feeds the timer with. Reused, never allocated per tick.
func fill_sample(sample: DotTimerSample) -> void:
	var state := controller.state

	sample.position = state.position
	sample.velocity = state.velocity
	sample.grounded = state.is_grounded()
	sample.alive = true
	sample.buttons = state.previous_buttons


func describe() -> Dictionary:
	return {
		"id": String(player_id),
		"name": display_name,
		"style": String(movement_style.id) if movement_style != null else "-",
		"speed": "%.1f m/s" % speed(),
		"run": str(timer.run) if timer != null else "-",
	}
