extends "res://addons/dot_npc_ai/runtime/dot_npc_ai_brain.gd"

## What a director-released NPC does: come at the players, and back off when it loses them.
##
## [b]Extended by PATH, like every brain.[/b] A brain is named by
## [member DotNpcDef.brain_script_path] and a mounted dot-cloud pack's `class_name` globals
## are not registered in the host — so a brain that named a class could only ever ship
## inside a build.
##
## [b]A tree here, and a machine in `npc_hunter.gd`, and the difference is the point.[/b]
## dot-npc-ai ships both and says which is which: a machine holds what an NPC *is* and a
## tree decides what it *does* within that. A wave NPC has one job — reach the players —
## and what varies is which of three ways it is currently doing it, in priority order. That
## is a selector, and writing it as a machine would be three states whose transitions are
## all "if the higher-priority one is unavailable".
##
## The trap this file exists to stay out of: **a guard behind a plain sequence is asked
## exactly once.** The sequence resumes at the running action and never re-checks the
## condition, so an NPC chases a target it no longer has. `reactive_with` is the idiom and
## it is used here for exactly that reason.

## How fast, in metres a second. From the definition, so a catalogue tunes it.
var speed: float = 4.6


func _build() -> void:
	if npc != null and npc.def != null:
		speed = float(npc.def.meta.get("speed", speed))

	tree = DotNpcAiSelector.new(&"root", [
		# Reach them. [b]Reactive, because a sequence that resumed at its running action
		# would keep walking at somebody who is no longer there[/b] — the guard is asked
		# once and never again, which dot-npc-ai wrote into its own fixture on the first
		# pass and documents at both ends.
		DotNpcAiSequence.reactive_with(&"chase", [
			DotNpcAiLeaf.Condition.new(&"sees", _sees),
			DotNpcAiLeaf.Action.new(&"advance", _advance),
		] as Array[DotNpcAiNode]),
		# Go and look. Not standing still: an NPC that stops dead the instant it loses you
		# is one you escape by stepping behind a crate.
		DotNpcAiSequence.reactive_with(&"search", [
			DotNpcAiLeaf.Condition.new(&"remembers", _remembers),
			DotNpcAiLeaf.Action.new(&"look", _search),
		] as Array[DotNpcAiNode]),
		DotNpcAiLeaf.Action.new(&"wander", _wander),
	] as Array[DotNpcAiNode])


## Whether it can see somebody AND has had time to react to them.
##
## [b]Both halves, and the second is the one that matters.[/b] An NPC that commits on the
## tick it first perceives somebody is one no player can ever surprise — `has_reacted` is
## the arena shooters' reaction time, and the gate every "act on what you see" branch
## belongs
## behind.
func _sees(_ctx: DotNpcAiContext) -> bool:
	return npc.has_target() and has_reacted()


func _remembers(ctx: DotNpcAiContext) -> bool:
	return blackboard.has(&"last_seen", ctx.now)


func _advance(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	var goal := _target_position()

	if goal == Vector3.INF:
		return DotNpcAiNode.Status.FAILURE

	# Remembered with a lifetime. A blackboard that never forgot would send this NPC to a
	# position from five minutes ago — which is why `DotNpcAiBlackboard` has one at all.
	blackboard.put(&"last_seen", goal, ctx.now, 10.0)

	# With spacing: a wave converging on one player climbs itself, and the one on top has
	# a horizontal offset of nothing from the one below — so it chases perfectly at a dead
	# stop with every number about it correct.
	steer_with_spacing(goal, speed, ctx.delta, 1.8)
	return DotNpcAiNode.Status.RUNNING


func _search(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	var last: Variant = blackboard.get_value(&"last_seen", ctx.now, null)

	if not (last is Vector3):
		return DotNpcAiNode.Status.FAILURE

	var goal: Vector3 = last

	if npc.position().distance_to(goal) < 1.5:
		# Written with a lifetime that has already passed, which is how this blackboard
		# is cleared: expiry is on read rather than swept, so an entry nobody looks at
		# costs nothing and one written into the past is gone the next time anybody does.
		blackboard.put(&"last_seen", goal, ctx.now, 0.001)
		return DotNpcAiNode.Status.SUCCESS

	steer_toward(goal, speed * 0.8, ctx.delta)
	return DotNpcAiNode.Status.RUNNING


func _wander(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	var angle := float(blackboard.get_value(&"angle", ctx.now, 0.0))
	angle = DotNpcAiSteering.wander(angle, 0.3, npc.instance_id + int(ctx.now * 2.0))
	blackboard.put(&"angle", angle, ctx.now, 0.0)

	steer_toward(
		npc.position() + DotNpcAiSteering.angle_to_direction(angle) * 6.0,
		speed * 0.4,
		ctx.delta
	)
	return DotNpcAiNode.Status.RUNNING


## Where the thing this NPC has committed to is, or `Vector3.INF`.
##
## [b]Infinity rather than zero for "gone".[/b] Zero is the middle of the map, so an NPC
## whose target disconnected would sprint to the origin and mill about — which reads as a
## pathfinding bug and is a missing null check.
func _target_position() -> Vector3:
	if not npc.has_target() or director == null:
		return Vector3.INF

	if not director.has_method(&"candidate_position"):
		return Vector3.INF

	var at: Variant = director.call(
		&"candidate_position", npc.target_id, Vector3.INF
	)

	return at if at is Vector3 else Vector3.INF
