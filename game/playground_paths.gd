extends RefCounted

## Where this game's own files are, wherever this copy of it happens to live.
##
## [b]A delivered pack does not mount at the path its content was authored at.[/b] It
## mounts at [code]res://dot_cloud/<id>/<version>/[/code], so every absolute
## [code]res://[/code] reference a game makes to its OWN files resolves against the
## host project root instead -- which holds another game's file, or nothing.
##
## A script knows where it is: [code]resource_path[/code] is the mounted path, not the
## authored one. So the game's root is this script's directory with the
## [code]game/[/code] segment taken off, and every other path hangs off that.
##
## [codeblock]
## load(PlaygroundPaths.rebase("res://npcs/brute.tscn"))
## [/codeblock]
##
## Built in, [method rebase] returns exactly what was passed to it, so nothing about
## today's behaviour changes. That is the point: one form that is right in both.

const _SELF := preload("playground_paths.gd")


## This game's content root: [code]res://[/code] built in, the mount prefix delivered.
static func root() -> String:
	# Through Resource, because a const-preloaded script is typed as its own class and
	# `resource_path` is not reachable on that -- "Cannot find member resource_path in
	# base res://...". The cast costs nothing and is the only spelling that compiles.
	var here: Resource = _SELF
	return here.resource_path.get_base_dir().get_base_dir()


## Moves one [code]res://[/code] path onto [method root].
##
## Anything that is not a [code]res://[/code] path is returned untouched, so this is
## safe to wrap around a value that may already be absolute or may be a user path.
##
## Format specifiers survive: only the prefix is replaced, so
## [code]rebase("res://maps/%s.json") % name[/code] works exactly as it read before.
static func rebase(path: String) -> String:
	if not path.begins_with("res://"):
		return path
	return root().path_join(path.substr(6))
