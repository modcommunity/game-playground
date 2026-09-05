class_name PlaygroundPlayer
extends Node3D

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
var view: DotFpsView = null

## Turns devices into commands, for a locally controlled player only.
var sampler: DotFpsSampler = null

## This player's timer. Owned by the world's [DotTimerManager], not by this node.
var timer: DotTimer = null

## The movement half of the style in force.
var movement_style: DotFpsStyle = null

## The ranking half.
var timer_style: DotTimerStyle = null

## The tools, when the game has dot-props.
var phys_gun: DotPhysGun = null
var grav_gun: DotGravGun = null

## Set by the world so the timer is ticked with the same clock the movement uses.
var tick_rate: int = 128


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
