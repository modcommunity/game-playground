extends Node

const Playground := preload("playground.gd")

## What plays next, decided by the players.
##
## [b]This game already had a rock-the-vote and it was `DotMapTimeLimit`'s, which is half
## of one.[/b] That half is real — it counts a fraction of the players and fires — and what
## it cannot do is offer a ballot, take nominations, break a tie, respect a cooldown, or
## give somebody the option to extend. dot-vote is fifty-five settings over exactly those,
## and the ad-hoc version is now the *time limit* under it rather than the vote itself.
##
## [b]The source is dot-map's catalogue, not dot-server's games.[/b] game-hungario votes
## over games because its modes are games; this one votes over **maps**, and
## `DotVoteMapSource` applies through the [DotMapSession] this game already drives. One
## engine, two sources, and neither this file nor that one names the other — which is the
## whole reason `DotVoteSource` exists.

const CHANNEL := "playground.vote"


## The vote picked something. The game is what changes to it.
signal change_due(map_id: StringName)

## Something a player should be told: the ballot, the tally, a warning.
signal announced(line: String)


var director: DotVoteDirector = null
var game: Playground = null

## How many people are playing. Every threshold in a vote needs it.
var player_count_fn: Callable = Callable()
var is_admin_fn: Callable = Callable()


## The vote's policy. Fifty-five settings, and these are the ones a sandbox changes.
static func vote_rules() -> DotVoteRules:
	var rules := DotVoteRules.new()
	rules.enabled = true
	rules.trigger = DotVoteRules.Trigger.TIME_LIMIT
	# Half an hour, which is dot-vote's default and is right here: a sandbox map is a place
	# people build in, and a fifteen-minute limit would throw away the thing they built.
	rules.duration_sec = 1800.0
	rules.vote_lead_sec = 120.0
	rules.vote_cooldown_sec = 60.0
	rules.vote_duration_sec = 30.0
	rules.max_options = 5
	rules.include_extend = true
	rules.include_current = false
	rules.method = DotVoteRules.Method.PLURALITY
	rules.tie_break = DotVoteRules.TieBreak.BALLOT_ORDER
	# [b]Off, and this is the setting dot-vote found a bug in.[/b] With it on, "extend" is
	# erased from a tie and the tie goes to the new map; with it off the ordinary tie-break
	# runs — and every pseudo-option sorts last in ballot order, so `BALLOT_ORDER` hands
	# the tie to the new map as well. Two documented policies, one behaviour. Set here so
	# somebody changing it is changing something.
	rules.extend_needs_majority = false
	# A sandbox is exactly the server where extending matters: people are mid-build.
	rules.extend_seconds = 900.0
	rules.max_extends = 4
	rules.rtv_enabled = true
	rules.rtv_fraction = 0.6
	rules.rtv_min_players = 2
	# [b]Measured against elapsed time, which is the other bug dot-vote found.[/b]
	# `DotVoteClock.running` used to mean "has a limit" rather than "has started", so a
	# server with no time limit never accumulated elapsed time and rocking the vote was
	# refused for ever — on exactly the deployment whose only way to change anything is
	# the vote.
	rules.rtv_delay_sec = 180.0
	rules.nominations_enabled = true
	rules.nominations_per_player = 1
	# [b]On, and it is the setting that makes `MOST_NOMINATED` mean anything.[/b] dot-vote
	# refused a second player nominating what somebody had already nominated, so every
	# count was exactly 1 and there was nothing to sort by.
	rules.nomination_seconding = true
	# A ballot filled by what people actually asked for, which is the fill that needs
	# seconding to work at all.
	rules.fill = DotVoteRules.Fill.MOST_NOMINATED
	rules.cooldown = 2
	rules.cooldown_mode = DotVoteRules.Cooldown.PLAYS
	rules.apply = DotVoteRules.Apply.IMMEDIATE
	rules.apply_delay_sec = 5.0
	return rules


func setup(p_game: Playground) -> DotResult:
	game = p_game

	var rules := vote_rules()
	var problem := rules.validate()

	if not problem.ok:
		return problem.wrap("The vote rules are not usable")

	director = DotVoteDirector.new()
	director.name = "Vote"
	director.rules = rules
	# [b]dot-map's own source, over the session this game already drives.[/b] Nothing here
	# loads a map: `DotVoteMapSource.apply` calls `DotMapSession.change_to`, which is the
	# path that already works — including the cloud fetch for a delivered map.
	director.source = DotVoteMapSource.from_session(game.maps)
	director.auto_apply = false
	# [b]Off, and this is dot-vote's fifth bug.[/b] With it on the director announces the
	# change it just made *and* the host announces the same change through its own map
	# signal — which fires for an operator typing `pg_map` too, and is therefore the one
	# that has to be connected. Both firing is two entries in the play history for one
	# play, and a "played in the last N" cooldown that is quietly half what it says.
	director.begin_on_apply = false
	director.self_advance = true
	director.register_service = false
	director.player_count_fn = _player_count
	director.is_admin_fn = _is_admin
	director.announce_fn = func(line: String) -> void: announced.emit(line)
	add_child(director)

	director.change_due.connect(func(id: StringName, _choice: DotVoteChoice) -> void:
		change_due.emit(id)
	)

	return DotResult.success(null)


## Somebody is playing something. The vote is told, once, from the one signal that fires
## for every change however it happened.
func note_playing(map_id: StringName) -> void:
	if director != null:
		director.begin(map_id)


func advance(delta: float) -> void:
	if director != null:
		director.advance(delta)


## Rock the vote, nominate, or cast one. The token comes off the wire.
func submit(voter: StringName, token: String) -> DotResult:
	if director == null:
		return DotResult.fail(DotError.CODE_STATE, "There is no vote here.")

	var parts := token.strip_edges().split(" ", false)

	if parts.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "Vote for what?")

	match parts[0].to_lower():
		"rtv":
			return director.rock_the_vote(voter)
		"unrtv":
			director.withdraw_nomination(voter, &"")
			return DotResult.success(null)
		"nominate":
			if parts.size() > 1:
				return director.nominate(voter, StringName(parts[1]))
		"vote":
			if parts.size() > 1:
				return director.cast_one(voter, StringName(parts[1]))
		"extend":
			return director.extend()

	return DotResult.fail(DotError.CODE_INVALID, "That is not something to vote.")


func next_in_rotation() -> StringName:
	return director.next_in_rotation() if director != null else &""


func _player_count() -> int:
	return int(player_count_fn.call()) if player_count_fn.is_valid() else 0


func _is_admin(voter: StringName) -> bool:
	return bool(is_admin_fn.call(voter)) if is_admin_fn.is_valid() else false


func describe_lines() -> PackedStringArray:
	return director.describe_lines() if director != null else PackedStringArray()
