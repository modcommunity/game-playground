# scenes/

What a **dedicated server** loads for this game, as opposed to `game/playground.tscn`,
which is what a **client** loads.

`pg_server.tscn` is deliberately almost empty: a `Playground` under a plain `Node`, with
nothing configured on it. `Playground._ready` registers itself under `playground` in
`DotRegistry`, which is what `playground_module.gd` looks it up by, and everything an
operator can change is a cvar or a layered configuration file. A scene full of exported
defaults would be a second copy of those values, and the copy nobody edits is the one
that goes stale.

It lives here rather than in `game/` because `dot-server-setup-test`'s `setup.sh` copies
`game/` into one shared directory and `scenes/*.tscn` into another, and the server scene
is the half a client never loads.
