extends Node

const Playground := preload("playground.gd")

## Per-player statistics, and what they are worth: dot-stats and dot-achievements.
##
## [b]This game already had boards and had nothing to put on them but times.[/b]
## `DotLeaderboardManager` is in `Playground` and holds three orderings; what was missing
## is the layer under it — the *counts*. How many props somebody has spawned, how many runs
## they have finished, how far they have fallen. dot-stats declares those once and reports
## them to the backbone as coalesced deltas; dot-achievements is rules over the same
## readings, which is the whole point of `DotAchievementStatsLink`.
##
## [b]Neither addon is given a new source of truth.[/b] A second count of anything is a
## second number that can disagree with the first, and the one that is wrong is always the
## one nobody is looking at. Every stat here is recorded from a signal the game already
## fires.
##
## [b]The player key is the scoped pseudonymous one, never an account id.[/b] dot-stats
## refuses an account id as a player key before it leaves the server, and a board is
## exactly the same kind of record.

const CHANNEL := "playground.progress"

const PROGRESS_DIR := "user://playground_achievements"


## Somebody earned something. Server side; the module tells everybody.
signal earned(player_key: String, id: StringName, title: String, points: int)


var stats: DotStatsTracker = null
var achievements: DotAchievementTracker = null
var link: DotAchievementStatsLink = null

var game: Playground = null

## The backbone, when an operator has configured one. Null on a LAN server.
var backbone: Object = null

var progress_dir: String = PROGRESS_DIR


# --- What is counted -------------------------------------------------------

## Every number this game reports about a player, declared once.
##
## [b]Declared, not discovered.[/b] dot-stats' whole shape is that a game says what it
## counts at boot and then reports deltas against it — so a typo'd stat id is refused when
## the schema is built rather than silently accumulating under a name nothing reads.
static func stats_schema() -> DotStatsSchema:
	var schema := DotStatsSchema.new()

	for id in [&"props", &"undos", &"runs", &"finishes", &"falls", &"kills", &"deaths"]:
		schema.define(id).publish = true

	var best := schema.define(&"best_speed", DotStatsDef.Kind.BEST, "Fastest")
	best.publish = true
	best.decimals = 1

	var fastest := schema.define(&"fastest_run", DotStatsDef.Kind.LOWEST, "Best time")
	fastest.publish = true
	fastest.decimals = 3

	return schema


## What a player can earn.
##
## [b]Every stat named here is one [method stats_schema] declares.[/b] An achievement
## watching a stat nothing reports never unlocks, nothing errors, and the only symptom is a
## player who did the thing and was not told — this family's most repeated bug wearing a
## rosette. `examples/dedicated.tscn` checks the two lists against each other.
static func catalogue() -> DotAchievementCatalogue:
	var out := DotAchievementCatalogue.new()
	var made: Array[DotAchievement] = []

	# A tier series: the same stat at three thresholds, which is what `series` and `tier`
	# are for. Three separate achievements would each have to be kept in step by hand.
	made.append(_counter(
		&"build_50", "Getting started", "Spawn fifty things.", &"props", 50.0, 10,
		&"builder", 1
	))
	made.append(_counter(
		&"build_500", "Builder", "Spawn five hundred things.", &"props", 500.0, 25,
		&"builder", 2
	))
	made.append(_counter(
		&"build_5000", "Architect", "Spawn five thousand things.", &"props", 5000.0, 50,
		&"builder", 3
	))

	made.append(_counter(
		&"first_run", "On the clock", "Finish a run.", &"finishes", 1.0, 10, &"", 0
	))
	made.append(_counter(
		&"run_100", "Regular", "Finish a hundred runs.", &"finishes", 100.0, 30, &"", 0
	))

	# A BEST rather than a COUNTER. `best_speed` is the biggest reading ever seen rather
	# than a running total, and an achievement that summed it would unlock for somebody
	# who was moderately quick often.
	var quick := DotAchievement.make(
		&"speed_30", "Quick",
		[_rule(&"best_speed", 30.0, DotAchievementRule.Merge.HIGHEST)]
	)
	quick.description = "Reach thirty metres a second."
	quick.points = 30
	made.append(quick)

	# A LOWEST, so the other end of the merge table is exercised rather than only
	# described — `DotAchievementRule.Merge` is dot-stats' four kinds again, and the two
	# would otherwise disagree about what a new reading does to an old one.
	var swift := DotAchievement.make(
		&"under_20", "Swift",
		[_rule(&"fastest_run", 20.0, DotAchievementRule.Merge.LOWEST)]
	)
	swift.description = "Finish a course in under twenty seconds."
	swift.points = 40
	swift.requirements[0].op = DotAchievementRule.Op.AT_MOST
	made.append(swift)

	# Secret: falling off the course is a thing a player will do before they know there is
	# anything to earn for it. Secret rather than hidden, because the difference is whether
	# the name is shown beforehand and this one is a joke that only works afterwards.
	var gravity := DotAchievement.make(
		&"fell_10", "Gravity works",
		[_rule(&"falls", 10.0, DotAchievementRule.Merge.SUM)]
	)
	gravity.description = "Fall off the course ten times."
	gravity.points = 15
	gravity.secret = true
	made.append(gravity)

	out.achievements = made
	return out


static func _counter(
	id: StringName,
	name: String,
	description: String,
	stat: StringName,
	target: float,
	points: int,
	series: StringName,
	tier: int
) -> DotAchievement:
	var out := DotAchievement.make(
		id, name, [_rule(stat, target, DotAchievementRule.Merge.SUM)]
	)
	out.description = description
	out.points = points
	out.series = series
	out.tier = tier
	return out


static func _rule(
	stat: StringName, target: float, merge: DotAchievementRule.Merge
) -> DotAchievementRule:
	return DotAchievementRule.make(
		stat, target, DotAchievementRule.Op.AT_LEAST, merge
	)


# --- Lifecycle -------------------------------------------------------------

func setup(p_game: Playground) -> DotResult:
	game = p_game

	stats = DotStatsTracker.new()
	stats.name = "Stats"
	stats.schema = stats_schema()
	stats.report_to_backbone = backbone != null
	add_child(stats)

	if backbone != null:
		stats.reporter.client = backbone

	achievements = DotAchievementTracker.new()
	achievements.name = "Achievements"
	achievements.catalogue = catalogue()
	achievements.catalogue_file = ""
	achievements.store = DotAchievementStoreFile.new(progress_dir)
	achievements.report_to_backbone = backbone != null
	add_child(achievements)

	var started := achievements.start()

	if not started.ok:
		return started.wrap("The achievement tracker could not start")

	achievements.unlocked.connect(func(player: String, got: DotAchievement) -> void:
		earned.emit(player, got.id, got.display_name, got.points)
	)

	# [b]The link is the whole integration and it is a signal connection.[/b] A tracker fed
	# by hand from twenty call sites is twenty places to forget one.
	link = DotAchievementStatsLink.new()
	link.name = "StatsLink"
	link.tracker = achievements
	link.stats = stats
	add_child(link)

	var linked := link.start()

	if not linked.ok:
		return linked.wrap("The achievement stats link could not start")

	_watch_game()
	return DotResult.success(null)


## Every signal this game already fires, turned into a reading.
##
## [b]Nothing here counts anything itself.[/b] The prop spawner already announces a spawn,
## the timer already announces a finish, and the arena already announces a kill — a second
## count would be a second number that can disagree with the first.
func _watch_game() -> void:
	if game.props != null:
		game.props.spawned.connect(func(prop: DotPropInstance) -> void:
			_record(prop.owner_id, &"props", 1.0)
		)
		game.props.removed.connect(func(
			prop: DotPropInstance, reason: StringName
		) -> void:
			if reason == DotPropSpawner.REASON_UNDO:
				_record(prop.owner_id, &"undos", 1.0)
		)

	game.run_filed.connect(_on_run_filed)


func _on_run_filed(
	player_id: StringName, run: DotTimerRun, _rank: int, _reason: String
) -> void:
	if run == null:
		return

	_record(player_id, &"finishes", 1.0)
	# A LOWEST: the tracker keeps the smaller reading, which is what a best time is. A
	# COUNTER here would sum every run somebody ever did into one enormous number and the
	# achievement would unlock for persistence rather than for speed.
	_record(player_id, &"fastest_run", run.time())


## One reading, under the key this player is filed as.
##
## [b]The tracker's key, never the account id.[/b] dot-stats refuses one before it leaves
## the server, and a stat is exactly the kind of record dot-user's per-scope ids exist for.
func _record(player_id: StringName, stat: StringName, value: float) -> void:
	var key: String = str(key_for.call(player_id)) if key_for.is_valid() \
		else String(player_id)

	if key == "":
		return

	stats.record(StringName(key), stat, value)


## How a world player id becomes a stats key.
##
## `func(id: StringName) -> String`. Unset means the player id itself, which is right for
## a LAN server and wrong for one with dot-platform — where the scoped pseudonymous key is
## what a stat has to be filed under.
var key_for: Callable = Callable()


## Starts counting for somebody, and reads back what they already had.
func begin(player_key: String) -> void:
	if player_key == "":
		return

	stats.begin(player_key)
	achievements.begin(player_key)


func end(player_key: String) -> void:
	if player_key == "":
		return

	stats.end(player_key)
	achievements.end(player_key)


## A reading nothing else fires: the arena's kills, the timer's falls.
func note(player_id: StringName, stat: StringName, value: float = 1.0) -> void:
	_record(player_id, stat, value)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if stats != null:
		out.append_array(stats.describe_lines())

	if achievements != null:
		out.append_array(achievements.describe_lines())

	return out
