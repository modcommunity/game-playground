class_name PlaygroundConfig
extends DotConfig

## Everything the playground is configured with, layered like every [DotConfig]:
## exported defaults, then a JSON file, then [code]PLAYGROUND_*[/code] environment
## variables, then [code]--pg-*[/code] arguments.
##
## [b]The tick rate is the one that matters, and it is deliberately not here.[/b] It
## lives in [DotTimerConfig] and defaults to "take it from the engine", which on a
## dot-server is whatever [code]sv_tickrate[/code] was set to. One number, in
## [code]server.cfg[/code], with everything else — rather than a second copy in a
## second file that can disagree with the first and produce plausible, wrong,
## permanently-filed times.
##
## [codeblock]
## ./game --pg-map=pg_surf_intro --pg-records=/srv/records --timer-tick-rate=128
## [/codeblock]

@export_group("Content")

## The map to load on boot.
@export var initial_map: StringName = &"pg_lobby"

## A map catalogue JSON file. Empty uses the three maps this build ships.
##
## The seam between "a game with its own maps" and "a server with a map pool": an
## operator points this at a file and the built-in list is not used at all.
@export var catalogue_path: String = ""

## A prop catalogue JSON file. Empty uses the fourteen props this build ships.
##
## Loaded INSTEAD of the built-in list, not layered over it. A catalogue that merged
## would give every server these fourteen whether it wanted them or not, and there
## would be no way to remove one. See [method Playground.built_in_props].
@export var props_path: String = ""

@export_group("Rules")

## Whether this instance times, ranks and spawns — the authority.
##
## A client sets this false, runs its own timer for its HUD, and files nothing.
@export var authoritative: bool = true

## Seconds a map runs before the session asks for the next one. 0 disables it.
@export_range(0.0, 86400.0, 30.0) var map_seconds: float = 1800.0

## Fraction of the players who must rock the vote to end a map early.
@export_range(0.0, 1.0, 0.05) var rtv_fraction: float = 0.6

@export_group("Records")

## Where records are kept. Empty keeps them in memory only.
@export var records_directory: String = "user://playground/records"

@export var record_replays: bool = true

## Whether published boards are reported to the TMC backbone.
##
## Off by default: publishing sends player names and times off the server, and that
## is an operator's decision rather than something that happens because a default was
## permissive.
@export var report_to_backbone: bool = false

@export_group("Props")

## Whether props can be spawned at all. Off makes it a pure movement server.
@export var allow_props: bool = true

## Props one player may have at once, counted in cost. 0 = unlimited.
@export_range(0, 1000, 1) var prop_budget: int = 64

## Whether a player may move, freeze or remove somebody else's props.
##
## [b]dot-props deliberately refuses to decide this[/b] — "a build server says no, a
## sandbox says yes, a competitive one says only for admins, and hard-coding either
## answer means the other needs a fork" — so it is passed to every tool call as
## `can_touch_others`. On by default, because this is a sandbox.
@export var touch_others_props: bool = true

## Props in the world at once, from everybody. 0 = unlimited.
@export_range(0, 10000, 1) var prop_world_budget: int = 1024

## Seconds between one player's spawns.
##
## [b]A budget alone does not stop a held key.[/b] Reach the cap, remove one, spawn
## another — that is a spawn and a free every frame, which costs the server more than
## the props do. dot-props' own default is 0.15 s; this is looser because a sandwich
## of planks is built by spawning a dozen quickly, and it is a [DotConfig] field so an
## operator who is being spammed can tighten it without a build.
@export_range(0.0, 10.0, 0.01) var prop_spawn_interval: float = 0.1


func env_prefix() -> String:
	return "PLAYGROUND_"


func cli_prefix() -> String:
	return "--pg-"


func validate() -> DotResult:
	if initial_map == &"":
		return DotResult.fail(
			DotError.CODE_INVALID, "There has to be a map to start on."
		)

	if rtv_fraction <= 0.0 or rtv_fraction > 1.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"rtv_fraction must be above 0 and at most 1.",
			"%.2f" % rtv_fraction
		)

	return DotResult.success(null)


func describe_summary() -> String:
	return "map %s, %s, props %s" % [
		String(initial_map),
		("records " + (records_directory if records_directory != "" else "in memory")),
		(("on, %s" % (props_path if props_path != "" else "built in"))
			if allow_props else "off"),
	]
