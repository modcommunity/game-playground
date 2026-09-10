# game-playground

**A sandbox first**, in the classic physics-sandbox shape: hold Q, pick a prop, an
NPC or a
weapon, click it and it is yours; hold a prop with a physics gun, freeze it, throw it,
undo it. With map support, and with dot-timer kept — on a jump course in the corner of
the sandbox rather than only on the surf and bhop maps, because that is what says the
timer is not a surf-and-bhop thing.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first, and
each addon's own `CLAUDE.md` before working in it. This file is only about the joins.

## What this project is for

**It is the only place dot-fps-controller, dot-timer, dot-map, dot-props, dot-npc and
dot-leaderboard run together**, and by the family's own repeated lesson that is where
everything is found. Every one of those addons has a suite, every suite passes with
the others absent, and that proves very little: the bugs that have cost days here were
all in seams — a bridge reconciling on top of another bridge, a message keyed on the
wrong id, a value computed and consumed by nothing.

`examples/headless_playground.tscn` is the point of the repository. It boots the whole
game, drives a bot down a surf map, finishes a run, files it, ranks it, spawns props
and checks their bodies were built from their definitions, opens the spawn menu on a
real `DotScreenStack` and clicks a prop in it, runs the sandbox's own course and falls
off it, spawns NPCs and watches one walk toward the player, fires a weapon loaded from a
script path, and changes the map underneath all of it. **183 checks, and it has now
found nine real bugs — three of them in other repositories.** Three more were found by
a screenshot, which no assertion could have.

It is also playable: `game/playground.tscn` is a first-person client with a spawn
menu, a crosshair and a HUD.

## Layout

```
game/
  playground.gd          the simulation: maps, timers, props, boards. Headless
  playground_config.gd   what an operator configures, layered
  playground_module.gd   the DotServer bridge: every console command
  playground_client.gd   one local player, a camera, a HUD, the keys. Not headless
  playground_player.gd   the bridge: movement, timer, style, tools
  playground_spawn_menu.gd  the Q menu: three tabs, categories, search, icon cards
  playground_icons.gd    icons drawn from a definition, because this ships no art
  playground_spawnables.gd  the catalogue, and what "kind" a definition is
  playground_prop.gd     one prop, built from its DotPropDef. One scene, fourteen props
  playground_weapons.gd  the arsenal, and how a script becomes a weapon
  entities/
    playground_entity.gd   a prop with a script, ticked by the simulation
    npc_*.gd               the shipped NPCs. `extends` a PATH, deliberately
  weapons/
    playground_weapon_def.gd  one weapon, as a document
    playground_weapon.gd      the base: two buttons and a tick. Extends DotPropTool
    swep_*.gd                 the shipped weapons. `extends` a PATH, deliberately
  playground_hud.gd      the clock, the speed, the crosshair, what is in your hands
  playground_geometry.gd dev-textured boxes and ramps, in code
  playground_map.gd      base for the built-in maps
  prop.tscn / entity.tscn  one scene for every prop, one for every entity
maps/
  pg_lobby.gd            the sandbox, and a jump course on bonus 1
  pg_surf_intro.gd       two ramps and a valley
  pg_bhop_intro.gd       blocks with widening gaps
  *.zones.json           generated from the maps, and checked against them
tools/
  export_zones.gd        writes those files. Run it after changing a map
examples/
  headless_playground.gd the integration suite
  dedicated.gd           a real DotServer, the module, and its commands
```

## The joins, and what each one gets wrong first

### The game owns the tick loop

`DotFpsController.Drive.EXTERNAL`, not `LOCAL`, even in single player.

In `LOCAL` the controller accumulates frame time and ticks itself, so the timer would
be fed from a signal fired inside somebody else's loop — and a bot could not be driven
at all. `Playground._simulate_tick` owns it instead, which makes the order explicit:

1. `props.advance(step)`
2. every player: sample (if local), then `controller.simulate_tick`
3. every player: `timers.tick_player` with the position the move **just produced**

**Step 3 must come after step 2.** The timer works out whether the player crossed a
line during this tick from where they were and where they now are; ticking it first
shifts every run by exactly one tick, and by a *different* amount at each tickrate —
which is precisely the tickrate dependence dot-timer's sub-tick fractions exist to
remove.

It is also the same shape a dot-net bridge and a dedicated server use, so nothing has
to be rearranged when one arrives.

### `body_ref` must not be `of_self()`

`DotNodeRef.of_self()` on the controller resolves to the **controller**, which is a
plain `Node`. `setup()` then refuses with "the player body must be a Node3D", the
controller never starts, `motor` stays null, and the player simply never moves. Leave
it unset: it defaults to the parent, which is the `Node3D` the movement drives.

This cost the first run of the integration suite nine failures, all of which pointed
somewhere else — no movement, no run, no statistics, no style effect.

### A style has two halves and they move together

`DotFpsStyle` transforms the tunables and filters the command; `DotTimerStyle` says
whether the run counts and what it is worth. `PlaygroundPlayer.set_style` applies
both. Applying one alone gives a run timed as "normal" while the player is actually
sideways, or the reverse — and nothing errors either way.

`DotFpsController.set_style` **rebuilds the motor**, which assigning the property
alone does not; the suite checks that specifically, because it is the way this is most
likely to be used wrongly.

### The timer decides and the game acts

`DotTimer` never moves a player. `Playground._on_effect_requested` turns a
`RESPAWN`, `TELEPORT` or `SLAY` zone into something that happens, because what those
mean is different in a first-person game, a 2D game and a replay being scrubbed.

The effects that change *where the player ends up* — a prespeed clamp, a speed-limit
zone — are read straight off the timer inside `PlaygroundPlayer._on_simulated`, on the
tick, rather than from a signal. Clamping a player's velocity is part of the
simulation, and doing it when a signal happens to arrive puts it a tick late.

### Statistics land when the run ends, which is when it is no longer active

`DotTimerManager.note_stats` originally guarded on "only while the run is active",
which silently discarded the one call that matters — the natural moment to fold in a
run's statistics is the moment it finishes. The suite caught it as a record whose
`stats` dictionary was empty, with no error anywhere, because refusing to write a
statistic is a legitimate thing for a timer with no run to do. Fixed in dot-timer.

### A map change happens with everything in flight

`_on_map_changing` runs **before** anything is torn down: it stops every run, makes
every tool let go, and clears the props — all of which are parented to, or standing
on, geometry that is about to be freed. dot-map's own ordering then loads the new
scene before freeing the old one, so a failure leaves the server on a working map.

**The prespeed clamp was dead.** `PlaygroundPlayer` asked
`timer.is_inside(DotTimerZone.Kind.START)`, which answers only for *effect* zones —
speed limits, freestyle, easy-bhop — and is always false for START, so a player could
carry any speed out of the pad. `in_zone` is the membership query. game-g2gfast had the
same line, its netcode suite found it, and the fix landed in both on the same day. The
lesson is the family's usual one: a guard that never fires looks exactly like a guard
that was never needed.

## What building the sandbox found

Three, all in other repositories, and all three the family's own recurring shape. Every
one parsed cleanly and none produced an error where it was written.

- **`DotTimer.effect_requested` was emitted by nothing at all.** The signal was
  declared, `DotTimerManager` forwarded it, and both this game and game-g2gfast
  connected a handler — so `RESPAWN`, `SLAY` and `TELEPORT` zones did nothing,
  anywhere, and a player who fell off a surf map fell for ever. Nothing errored,
  because a zone kind the timer has no rule for is a legitimate thing to find and the
  whole design says the timer must not act on one itself. It is the family's commonest
  pattern with the ends swapped: not a value produced and consumed by nothing, but a
  value **consumed by two games and produced by nobody**. Fixed in dot-timer, which now
  fires it once on entry, track-filtered, after the tick is complete.

  It was found by needing a course a player could fall off. It also **quietly invalidated
  a passing test**: game-g2gfast's "most of the descent is spent not grounded, which is
  surf" counted 1500 ticks of a bot that had missed the ramps and was falling through
  the void, none of which was surfing. With the respawn working, the bot is put back
  after ~500 ticks and is airborne for 94% of them, which is what the check was always
  meant to say.

- **`DotPropDef.mass` was not put on the body.** See "One scene, fourteen props" below.
  Only visible in a project where every prop is the same scene.

- **`set_anchors_preset` does not set offsets, and dot-ui had five of them.** The
  family's own CLAUDE.md has warned about this since dot-ui was written — "a `Control`
  built in code keeps the zero size it was created with, so the whole interface lays out
  inside nothing and is invisible while being, by every property, correctly configured"
  — and `DotScreenStack` itself, plus `DotCrosshair`, `DotHud` and `DotTableView`, all
  still had it. Nothing in dot-ui's own suite measured a size. The spawn menu here was
  the first screen anybody built on a stack whose parent is a plain `Node`, and it came
  out 0 × 0. All five now use `set_anchors_and_offsets_preset`, and both suites check a
  size rather than a property.

And two here, both of which say the same thing about signals:

- **A signal is not a state.** `PlaygroundClient` waited for the playground to finish
  booting with `await playground.ready_for_players`, and `Playground.change_map` can
  complete **without ever suspending** — a built-in map is a scene already in the
  build — so the playground finished booting inside `add_child` and the signal had
  already been emitted by the time the client reached its `await`. The client then
  waited for ever. **The symptom is a black screen with no error at all**: no camera,
  no HUD, no player, no failed load, nothing in the log. It is the family's own
  GDScript fan-out trap in its smallest form, and the fix is the same one:
  `if not playground.booted: await playground.ready_for_players`. No test caught it,
  because every test drives `Playground` directly; a screenshot caught it in one look.
- **A GDScript lambda captures locals by value**, which is already in the family's
  conventions: the first version of the respawn fix above broke out of a loop on a
  `bool` set inside a signal handler and reported "468 of 1500". Capture an `Array`.

**Two of the four wanted a screenshot rather than a test.** The 0 × 0 menu and the
black screen were both invisible to every assertion available — one because every
property was right, the other because nothing had failed. `tools/screenshot.sh` in
`game-dev/` renders this project on a machine with no display; it is not optional
after touching the client.

Building the entities, the weapons and the icon cards on top of that found three more,
and **every one of the three was a screenshot again**:

- **`TabBar.clip_tabs` defaults to on**, so the bar reported a minimum width of about
  one tab, hid the other two behind scroll arrows, and let the `HBoxContainer` lay the
  heading out underneath it. Two of the three tabs were unreachable and "Spawn" was
  drawn through "Props". Every property was correct.
- **The entity icon's torso covered its head.** The torso spanned the full height at
  0.62 of the half-width and the head sat at 0.42 of it, entirely inside — so every
  NPC in the menu was a coloured bar. A head has to be wider than the body and the body
  has to start below it.
- **A bot keeps the last command it was given.** `DotFpsController.apply_command` sets
  the pending command and it stays set, so the bot arrived in the entity test still
  holding forward and jump from the bhop test several tests earlier and auto-hopped
  across the sandbox for the whole of it. "Does the chaser close the distance" was
  measuring a player running away. Not a product bug — but a test that drives a bot and
  then stops driving it is a test with a bot that is still driving.

## The sandbox half

### One scene, fourteen props

`game/prop.tscn` is the only prop scene in the project and it has no shape, no mesh and
no mass in it. What makes a plank a plank is three fields of its `DotPropDef.meta` —
`shape`, `extent`, `colour` — which `PlaygroundProp.configure` turns into a collision
shape and an unshaded box. A server with real content points `scene_path` at its own
scenes and never loads this file at all, which is the seam `DotPropDef` was designed
around: the definition is checkable without loading anything, and the scene is fetched
only when something is actually created.

**The body is built by `configure`, not by `_ready`.** `DotPropSpawner` instantiates
the scene, places it, adds it to the world and *then* emits `spawned` — so the
definition is not available until after the node is in the tree, and a `_ready` that
built a default box would build one that is immediately thrown away. A prop nobody
configured has no collision shape and no mesh: it falls through the floor, is
invisible, and cannot be grabbed, which is three symptoms all pointing somewhere else.
So `_ready` schedules a deferred check that says so, loudly, once.

**`DotPropDef.mass` used to be a number nothing simulated.** It is read in exactly one
place in dot-props — `DotPropTool.may_act_on`, against `grab_mass_limit` — and the body
kept whatever mass its scene was saved with. A catalogue that says 900 kg over a scene
saved at 20 kg gives a prop a physics gun refuses for being too heavy and a gravity gun
throws like a beach ball, with nothing erroring and the two numbers only ever compared
by a player wondering why. `DotPropSpawner` now puts it on the body before the body
enters the tree — earlier than the first physics step, because dot-props' own suite
already found that a mass set *after* an impulse divides that impulse by the old mass.
Fixed in dot-props; this repository is where it showed, because every prop here is the
same scene and the mass is the only thing distinguishing them.

### An entity is a prop with a script, and the script is named by a PATH

This is the division every sandbox of this kind makes, and it is the right one: a
crate is a shape with a
mass and needs no code, and a thing that walks about needs code. dot-props knows
nothing of the difference — it instantiates a scene, places it and counts it against a
budget — so the difference is two fields of `DotPropDef.meta`:

```json
{ "kind": "entity", "script": "res://game/entities/npc_wanderer.gd" }
```

`Playground._configure_entity` loads it and attaches it to the bare `RigidBody3D` that
`entity.tscn` is. That is the whole mechanism.

**The script is named by a path, and that is not a style choice.** A game delivered
through dot-cloud is a mounted `.pck`, and **a mounted pack's `class_name` globals are
not registered in the host** — measured, and written down in the family's own
CLAUDE.md. Every cross-file type reference inside a pack fails to compile; `preload`
and `extends` by path both work. A catalogue that named a class could therefore only
ever ship inside the build. The shipped entities are written the same way —
`extends "res://game/entities/playground_entity.gd"` — because they are the template a
pack copies, and if that path ever stopped working they would stop with it.

**`_ready` has already run by the time the script is attached.** The spawner adds the
body to the world and *then* emits `spawned`, so nothing in an entity may rely on
`_ready`; the base has `_entity_ready` and `bind` instead. This is the same ordering
`PlaygroundProp.configure` exists for.

**A failure removes the prop rather than leaving it.** A body whose script did not load
sits there being a crate, which is indistinguishable from an NPC that has nothing to
do — and "the NPC does not move" sends the next person to the movement code. Both
failure shapes are checked and both are loud: a path that is not there, and a path that
is a real script which is not an entity. The second is the one a copy-paste actually
produces.

**An entity extends `PlaygroundProp`, so it is a prop to everything else.** It counts
against a budget, it can be undone, it goes when its owner leaves, a physics gun can
pick it up and a gravity gun can punt it. An NPC you cannot pick up is the first thing
a sandbox player will try.

**A held entity stops driving itself.** Otherwise it fights the physics gun's spring —
the gun writes a velocity toward the goal, the NPC writes one toward wherever it was
walking, the prop shudders between them and the player concludes the gun is broken.

**Entities tick before players**, from `Playground._simulate_tick`, at the simulation's
fixed rate. Not `_process`, which would make an NPC's speed a function of the frame
rate; not after the players, which would leave a chaser visibly a tick behind its
target at exactly the rate the server ticks.

### Perception is dot-npc's; being a prop is still dot-props'

The entities were ported onto **dot-npc** for the half they were getting wrong, and
deliberately *not* onto its spawner.

**What moved.** The chaser called `nearest_player()` on every one of the 128 ticks a
second this game runs at. That is the classic broken NPC and both of its failures are
reachable in a sandbox in about ten seconds: two players standing a metre apart make it
turn back and forth for ever, and one who steps out of range makes it forget instantly
and walk away mid-stride. `DotNpcSenses` acquires at one threshold, drops at a weaker
one, and keeps chasing for a grace period measured from the **last sighting** rather
than from acquisition. `PlaygroundEntity.target()` is the whole interface;
`nearest_player()` is still there and still correct for what it says, which is what the
spinner wants.

The perception envelope is a catalogue field — `sight`, `sight_angle`, `hearing`,
`line_of_sight` in `meta` — for the reason `tune` exists. It replaced a `give_up_range`
the chaser applied by hand, and giving up is now what happens when a target leaves the
envelope and the grace expires.

**What did not move, and why.** An entity here is a `DotPropInstance` first: it counts
against a prop budget, it can be undone, it goes when its owner leaves, a physics gun
can pick it up and a gravity gun can punt it across the map. Spawning these through
`DotNpcSpawner` would have taken all of that away in exchange for a second population
system this game does not need. **An NPC you cannot pick up is the first thing a sandbox
player will try.** So dot-npc is installed here for its senses and its instance row, and
`dot-npc-ai` and `dot-npc-ai-director` are not installed at all — a sandbox has no
pacing to direct.

**The candidate list is built once per tick, before the entities run.** Once per tick
and not once per entity, because twenty NPCs each building their own list of eight
players is a hundred and sixty allocations a tick for a list that does not differ
between them. Before rather than after, because a list built at the end of a tick is a
list of where everybody *was*, which is the one-tick lag the entity ordering already
exists to avoid.

**A target who disconnects is dropped immediately** rather than being left to the grace
period. The grace exists so a doorway is not a perfect escape; a player who has left has
no position at all, and steering at their last one walks the NPC into an empty corner for
two and a half seconds.

### A weapon is a script too, and it is not in the prop catalogue

Same mechanism, different registry. `PlaygroundWeapons.make` loads a path, instantiates
it, and checks the result actually *is* a `PlaygroundWeapon` — because a script that is
valid GDScript but extends the wrong thing constructs perfectly and then has none of
the methods the client calls, and the first symptom is a crash inside a mouse handler.

**Weapons are deliberately not `DotPropDef`s.** dot-props' catalogue is "things you
spawn into the world" and requires a `scene_path`, because that is what a spawn needs.
A weapon is never spawned and has no body. Giving one a scene path so it would fit is
the sort of lie that becomes "why does this crate have no collision". The player sees
three tabs; underneath, one of them is a different system, and it is different for a
reason.

**`PlaygroundWeapon` extends `DotPropTool`**, which is most of the work: the spawner,
the wielder, the reach, a `target()` that resolves a ray to a prop, and a
`may_act_on()` that asks the *host* the ownership question rather than answering it.
A physics gun and a gravity gun are the two dot-props ships; these are the game's own,
and they are the same kind of object — not a node, no camera, handed an origin and a
direction so the same weapon works for a player, a bot, a replay and a headless test.

**A muzzle velocity is not an impulse, and the arsenal uses both on purpose.**
`PlaygroundWeapon.launch` writes a velocity: an impulse is divided by the mass, which
is right for a punt and exactly wrong for a launcher, whose boulder would otherwise
leave at a fortieth of the speed of its ball. `swep_impulse` does the opposite for the
opposite reason — a shockwave *should* throw a beach ball further than a boulder.

**Tuning lives in the definition, not in the script.** It is what lets one script serve
three catalogue entries — `npc_wanderer` and `npc_hopper` are the same file at
different speeds — and it is the only half of an entity an operator editing a JSON
catalogue can reach.

### The Q menu

`PlaygroundSpawnMenu` is a `DotScreen` on a `DotScreenStack`, and dot-props is right
that it belongs here: "a menu of four hundred props with icons and a search box is a
game's own design". What the addon does provide is everything the menu needs **without
loading a single scene** — `categories()`, `in_category()` and `search()` all read
fields of a `DotPropDef`.

Three behaviours come straight from the sandboxes this copies, and each is a decision:

- **Hold to browse, tap to pin.** One key, two behaviours, and not a toggle: holding
  shows the menu for as long as you hold it, which is a glance with your place kept;
  tapping leaves it up, which is what you want while building. A plain toggle loses the
  glance and a plain hold means you cannot let go of the mouse.
- **Clicking a prop spawns it**, and the menu stays open. A menu that only *selects*
  means every prop costs two actions and a wall is nine open-and-closes.
- **The menu never spawns anything itself.** It emits and the client asks the server,
  which is the same division the tools make and the reason the file works unchanged
  when a dot-net bridge arrives and a spawn becomes a message.

**Three tabs — props, entities, weapons — and switching one clears the filter.**
Carrying "containers" onto the weapons tab shows nothing and reads as the tab being
broken. The search reaches across the whole tab but not across tabs: a player typing
"barrel" wants the barrel and not "you are on the Toys tab", and a weapon turning up in
a prop search is not a result, it is a surprise.

**The grid is the single source of what is on screen.** `shown()` and `card_for()` read
the buttons' own metadata rather than re-running the filter, because a second copy of a
filter is a second thing that can disagree with the first — and the copy that would be
wrong is the one nobody is looking at.

**A card is a `Button`, not a container.** A Button is focusable and a `VBoxContainer`
is not, so Godot's own focus neighbours make the whole grid navigable with a gamepad or
the arrow keys for free — and a menu that cannot be used without a mouse is exactly the
failure dot-ui's `initial_focus` exists to prevent. Icon above text is
`vertical_icon_alignment`, which is what that property is for.

**The first card takes focus, not the search box, and `/` is what reaches the search.**
Focusing the search box on open sends W, A, S and D into it: the player stands still
typing "wasd" while the menu looks exactly as it should. This is a menu you can walk
around with, so the search needs a key that is not a movement key — and Enter puts the
keyboard back, because otherwise there is no way out of the box that is not the mouse.

**An empty grid says why it is empty.** A search with no results and a tab with nothing
on it look identical when both are blank, and the player's next move is different.

### The icons are drawn from the definition

`DotPropDef.icon_path` is honoured first and almost never set here: a server with
content points it at a thumbnail and that is what the menu shows. This project ships no
art, and a grid of forty identical grey squares is worse than a grid of names — so when
the field is empty `PlaygroundIcons` draws one from **the same three fields the body is
built from**. A barrel is a green cylinder in the world and a green cylinder in the
menu, at the right aspect ratio, because both read `meta` through
`PlaygroundProp.shape_of` / `extent_of` / `colour_of`. A second copy of "what does meta
mean" is a second thing that can disagree with the first.

**Cached by what is drawn, not by prop id.** Fourteen props share four silhouettes and
eleven colours, and a four-hundred-prop catalogue shares far more. A menu that built
four hundred images on open would hitch every time somebody pressed Q.

**An entity is drawn at a fixed, person-shaped aspect rather than its body's.** A
wanderer is a 0.8 by 1.7 box, and at that ratio the head is three pixels across and the
icon reads as a coloured bar.

### The tools are two, and they behave differently

`1` and `2`, and both mouse buttons mean something different depending on which is in
hand. That is dot-props' own division — a physics gun is a building tool with arbitrary
distance, free rotation and a soft spring; a gravity gun is a weapon with one carrying
position, a stiff hold and a punt — and shipping one and calling it both gives a
building tool that cannot throw.

**Switching tools lets go of everything first.** `DotPropInstance.held_by` allows one
holder, so a gravity gun still carrying a crate makes the physics gun's grab do
nothing — with nothing on screen to say why.

**Opening the menu lets go too.** The mouse is about to become a cursor, and a physics
gun still holding a crate would drag it round the world following a pointer the player
is aiming at buttons with.

## The timer is not a surf-and-bhop thing, and `pg_lobby` is where that is said

`pg_lobby` is a sandbox on the **main** track, a nine-platform jump course on
**bonus 1** and a sixteen-platform spiral tower on **bonus 2**, and all three are
deliberate.

The main track has no start zone and no end zone, so a player building on the plate is
on a map with no timer — which is what `pg_lobby` has always been for, and the one
thing proving the rest of the game does not quietly require one. Putting the course on
a bonus track keeps that *and* adds a minigame, and the mixed case is a better test than
the empty one because it is the case a real sandbox server is in.

Nothing about a jump course is a movement genre. It is zones drawn round platforms, and
the same sub-tick fractions, styles, records and replays apply to it — which is the
whole claim `dot-timer` makes by depending on nothing but dot-core.

**The reset volume is on the bonus track, and that track filter is what makes it
usable.** It is the air just above the sandbox floor under the course: a player on
bonus 1 who falls off touches it and goes back to the start pad, and a player on the
main track walking through the same corner with a physics gun is not touched at all.
`DotTimer` filters zones by the run's track before it acts on any of them.

### Bonus 2 is a different skill, not a longer bonus 1

A second route through a map players already know is worth more than a fifth map nobody
has learned, and the two courses are deliberately asking different questions. Bonus 1 is
a straight line with widening gaps: **how far can you jump.** Bonus 2 is a spiral
climbing a pillar, so every jump is a turning one: **can you keep your speed round a
corner**, which in a Quake-style controller is air-strafing and is the thing the movement
is actually about.

Three things about it that are not visible in any count, and one of them was a real bug:

- **The splits are height bands, not lines.** A vertical line across a spiral is crossed
  twice per turn, so a stage drawn the way bonus 1's is would fire on the way round as
  well as on the way up. The thing that only happens once on a tower is reaching a
  height, so that is what is measured.
- **The pillar starts at the top of the pad, not at the floor.** The first version ran it
  from `y = 0`, which put a 2.4 m column straight up through the middle of the start pad
  — so the player spawned *inside* it and could not move. Every count passed: the pad was
  there, the platforms were there, the zones were right. What found it was a bot that
  reported it had not gone anywhere.
- **The tower's start pad is smaller than the jump course's**, because an 8 m pad reaches
  5.66 m at its corners and the first platform's inner edge is at 4.9 m — so the two
  overlap and the first jump of a jumping course is a walk. Nothing about that is visible
  from above.

**The spawn yaw is derived, and the sign convention bit.** `DotFpsMotor._view_basis`
builds forward as `(-sin(yaw), 0, -cos(yaw))`, so facing a direction is
`atan2(-dx, -dz)`; the obvious `atan2(dx, dz)` is 180 degrees out *and* mirrored. A
spiral has no obvious forward, so a player spawning with their back to it has to find the
course before they can start it — the bot caught it as a dot product of exactly -1.

**`Playground.tracks_on_this_map()` is derived from the zones, not declared.** A second
list of tracks is a second thing that can disagree with the zone file — and it is the
zone file a *delivered* map ships, so the declaration would be the half that is missing
exactly when it matters. `MAIN` is always in the result even with no zones on it,
because a sandbox is a legitimate track and a player has to be able to get back to it.

## Bonus 3 is a circuit, and a track now says whether it is driven

`pg_lobby` gained a **driving circuit** round the outside of the plate: a rounded
rectangle 387 m round, 12 m wide, with kerbs down both sides and its corners on a 26 m
radius, running clear of the jump course, the tower and the movement corner. It is the
first map in this family built at a **car's** scale rather than a player's, and the first
time anything here has put a vehicle through dot-timer.

**A loop whose start and finish are the same place finishes on the tick it starts**, so
the grid is at `s = 0` and the finish line is 12 m *behind* it. A car leaves the grid
driving away from the line, goes all the way round, and crosses it on the way back to
where it started. That is what a real circuit does by putting the timing loop somewhere
other than the front row, and it is the only reason a lap here is a lap.

Everything comes from one function. `PgLobby.circuit_point(s)` answers with a position
and a direction of travel, and the road, the kerbs, the grid, the finish, the three
splits and the spawn yaw are all derived from it — the same rule the two foot courses
follow, for the same reason: a start line half a metre off the tarmac is a leaderboard
nobody can compare, and on a track a car crosses at 25 m/s that half metre is two ticks.

### Getting into a car used to cancel every run

`Playground._on_seated` stopped the timer unconditionally, and that was right when every
course was a foot course: a jump course driven round in a buggy is not a time anybody can
compare with one that was jumped, and dot-timer has no idea a vehicle exists. It is
exactly wrong on a circuit, and **a rule that cannot tell the two apart is why there was
not one**.

`PlaygroundMap.track_is_driven(track)` is the seam, defaulting to false — so every map
that existed before there were cars behaves exactly as it did. The map answers because
the map is the only thing that knows. The rule is symmetric and the second half matters
as much: on a driven track, **getting out** ends the run, because the rest of the lap on
foot is not the same lap.

### What building it found

- **`Basis.looking_at(dir)` aims -Z at `dir`, and a vehicle's forward IS -Z.** Negating
  the argument — which is the natural thing to write when the vehicle notes say "a
  positive `engine_force` drives +Z" — put the car on the grid facing backwards. It
  reversed 12 m into the finish line and reported a lap of 0.36 seconds with no splits,
  which is a perfectly plausible-looking pass if the only assertion is "it finished".
- **A car parked on the road cannot be got out of.** `max_exit_speed` refuses an exit
  above walking pace, correctly, and a test that coasts to a stop is not stopped. The
  brake is `BUTTON_CROUCH`.
- **`dedicated.tscn` had been carrying state between runs for weeks.**
  `DotAchievementStoreFile` writes under `user://`, so each run added sixty prop spawns
  to whatever the last one left; after about nine runs the "fifty unlocks the first tier
  and not the second" check crossed 500 and began failing on a tree with no changes in
  it. **A suite whose result depends on how many times it has been run is not a suite.**
  It wipes the player's stored progress first now. This was not found by the circuit; it
  was found by running the suite twice, which is what this family's own notes say to do
  before blaming a change.

And one that is a harness artefact rather than a bug, worth knowing before reading a
failure here: **`headless_net`'s "it drives forwards" check is flaky.** Both games are
plain nodes in one scene tree and therefore share one physics space, and the reading is
whatever the two cars happened to be doing. It failed once at -0.16 m/s and passed twice
straight after with nothing changed. Run it again before believing it.

## The tick rate comes from `server.cfg`, and every link in the chain is silent

```
server.cfg:  sv_tickrate 100
      ↓      dot-server, _apply_tickrate()
Engine.physics_ticks_per_second
      ↓      Playground._resolve_tick_rate()
Playground.tick_rate  →  DotTimerConfig.tick_rate = 0 ("ask the engine")
      ↓
DotTimerManager.tick_rate  →  DotTimerRecord.tick_rate
```

A timer counting 128 a second on a server stepping 100 reports every run 28% long, and
**nothing about the run looks unusual** — it finishes, it files, and it sits on a
leaderboard shared with servers that got it right.
`examples/dedicated.gd::_test_tickrate_reaches_the_timer` walks the whole chain in one
test, with the server configured for 100 precisely because the project's own default is
128: a test using the same number at both ends would pass with the chain disconnected.

`sv_tickrate` goes in **`server.cfg`, not `autoexec.cfg`** — it is startup-only, and
dot-server execs the first before the listener and the second after.

## Chat is dot-chat's, and there is still exactly one path

`DotChatRouter` has the rules: four channels, one of them a **radius**, a backlog for
whoever just joined, a `/me`, and a gag that survives a reconnect. `PlaygroundModule` hooks
`player_chat` with `hook_pre` and **cancels** it, so dot-server's own broadcast never
happens, and its join and leave announcements are turned off in the same place.

Two paths would be two sets of rules to keep in step, and the one that skipped the filter
would be the one that leaked admin chat. `dedicated` asserts the cancel.

**An unclaimed `!command` goes into dot-server's own console with the player's
permissions.** Not a second command table — this game's console surface is the largest in
the family and a second table would be the larger half unaudited.

**The chat key is the session id, not the account uid.** dot-chat's `key_fn` and
dot-moderation's `key_for_peer` are separate seams because they answer different questions:
a punishment is against a person who will come back; a chat line is attributed to somebody
standing here now. Two guests behind one device id share a uid, which game-simple-lobby
found by running two clients in one process — with every count matching throughout.

## Voice is the whole server, and the near channel is text's

Three games, three answers, and each is right for what it is. A lobby is a room you can see
all of, so its voice is the room. An arena is bigger than a screen, so game-hungario's is
proximity. **A sandbox is both at once** — people build together in one corner and run the
course in another — so text has a near channel and voice does not, which is what every
sandbox server has ever shipped with: a builder shouting for a hand should be heard, and
somebody in the corner reading should be able to stop reading the shouting.

The rest is the lobby's reasoning: one `unreliable` RPC on its own channel serves a UDP
desktop client and a TCP browser one; push-to-talk closes when a screen takes the keyboard;
and playback goes into a **buffer** when there is no audio device, which is what makes the
receiving half checkable at all.

## The arena: dot-combat, dot-match and dot-loadout, off by default

**A sandbox is not a deathmatch.** `pg_arena 1` is the switch, and everything behind it is
inert until then — for the same reason `pg_waves` is: a server where somebody can shoot you
while you are building is a *different server*, and turning one into the other silently
because an addon was installed is exactly what a cvar exists to prevent.

- **dot-combat** is health, damage types, hitboxes and the resolution — and the part that
  matters is not the arithmetic. Friendly fire, self damage, falloff, hit groups and
  clamping are **policy** on a resource rather than `if`s in a file, so an operator can
  change any of them.
- **dot-match** is warmup, countdown, rounds, scoring, respawning. Counted in ticks and
  driven by one call, so it runs at whatever `sv_tickrate` says.
- **dot-loadout** is what you spawn with, as a document of **ids** validated against a
  schema and an entitlement set without loading any content.

**The loadout catalogue is built FROM `PlaygroundWeapons`**, not beside it. The arsenal is
already declared once — an id, a name, a script path — and what a `DotItem` adds is the two
things a weapon definition has no business knowing: what it costs and what unlocks it. A
second list is the bug this tree has now shipped four times.

**The required slot has a default, and dot-loadout refuses a schema without one.** That
refusal is right: a loadout missing a required slot cannot be *repaired*, so it can only be
refused — and a player who has never chosen could then never spawn. The default is derived
from the catalogue rather than written in.

### The bug the arena found on its first run

**A `DotDamage` with no `tick` is refused by spawn protection for ever.** `DotHealth.apply`
refuses anything whose `tick` is at or before `invulnerable_until_tick`, and a `DotDamage`
starts at tick 0 — so an event that was never stamped is refused on every player, with
`refused` set, and nothing erroring anywhere. Every shot on the server does nothing and the
only symptom is that combat does not work. One line; found by the suite's very first hit.

## Waves: a second population, with a different owner

`dot-npc-ai-director` releases NPCs the **server** owns, and they are deliberately *not*
prop entities.

This project's own rule — an entity is a `DotPropInstance` first, because *an NPC you
cannot pick up is the first thing a sandbox player will try* — is about NPCs a **player**
put there. A wave is not one: nobody spawned it, nobody owns it, and it is reclaimed when
the players walk away from it, none of which a prop budget can express. So there are two
populations with two owners and two reasons, and `pg_waves 1` is the only thing that makes
the second exist.

**Line of sight is ON here and off in the other two games**, which is the point of the
flag: a sandbox has walls, pillars and whatever somebody built, and an NPC that saw through
all of it would make cover meaningless. The other two are open arenas with nothing to be
occluded by.

**Spawn points come from the map's own `DotSpawnPoint`s.** A director inventing its own
would be a director putting a brute in a wall; a ring around the origin is the fallback, and
it says so in the log.

## `npc_hunter` is `npc_chaser` with a decision, and both are in the catalogue

The cheap one is for filling a room with and the expensive one is for the arena, and
**keeping both is the only honest way to say what dot-npc-ai actually bought**:

- a **reaction time**, so an NPC cannot commit on the tick it first perceives you — which
  is the difference between a bot and a target;
- a **character per NPC**, seeded from the instance id, so twenty of them do not react at
  the same moment (which reads as a firing squad);
- **separation**, so a pack converging on one player comes apart rather than climbing
  itself into a tower that chases perfectly at a dead stop;
- a **machine**, because there are four states and the transitions between them are the
  whole design — a tree here would be four leaves under a selector pretending to be a
  hierarchy. `wave_brain.gd` is a tree, for the opposite reason, and the two files together
  are what dot-npc-ai's "which is which" note looks like in practice.

### The bug it found in dot-npc-ai

**`has_reacted()` was false for ever.** It measured from `DotNpcInstance.engaged_at`, which
dot-npc refreshes on **every pass in which the target is perceived** — that is what the
field is for, because it is what a reclaim asks about. So the gate every "act on what you
see" branch belongs behind never opened, on any NPC that could currently see somebody,
which is every NPC that would ever act on one.

Nothing errored. **A bot that never acts on what it sees looks like a bot that is bad
rather than like one that is broken**, which is why it survived a suite that tests
`DotNpcAiCharacter.has_reacted` directly and correctly — the arithmetic was right the whole
time and the field being handed to it was the wrong one. `DotNpcInstance.target_since` was
added to dot-npc for it. This file had the same line and the same bug, which is the
confirmation that the fix belonged in the addon.

## Statistics, achievements and the vote

**dot-stats and dot-achievements sit under the boards this game already had.** The boards
held three orderings and there was nothing to put on them but times; what was missing was
the *counts*. Every stat is recorded from a signal the game already fires — a second count
of anything is a second number that can disagree with the first — and
`DotAchievementStatsLink` is a signal connection over that rather than twenty call sites.

`dedicated` checks that **every stat an achievement watches is one the game declares**. An
achievement watching a stat nothing reports never unlocks, nothing errors, and the only
symptom is a player who did the thing and was not told.

**dot-vote replaced half a rock-the-vote.** `DotMapTimeLimit` counts a fraction of the
players and fires, which is real and is half of one: it cannot offer a ballot, take
nominations, break a tie, respect a cooldown or offer an extend. The time limit is now the
clock *under* dot-vote rather than the vote itself, and the source is
`DotVoteMapSource` over the `DotMapSession` this game already drives — one engine, two
sources, and game-hungario's votes over *games* without either file naming the other.

Three of dot-vote's own five bugs are settings set **explicitly** here rather than left:
`extend_needs_majority` (two documented policies, one behaviour), `nomination_seconding`
(without it every nomination count is exactly 1 and `MOST_NOMINATED` can never do
anything), and `begin_on_apply` (both the director and the host announcing one play halves
every cooldown — the host's `DotMapSession.changed` is the one signal that fires for every
change however it happened, so it is the only connection).

## Identity, and why a sandbox needs it at all

`PlaygroundPlatform` builds dot-user, dot-user-avatar and `DotPlatformHub`, and
`examples/dedicated.tscn` loads `DotPlatformModule` beside `PlaygroundModule`. It is
optional: a LAN sandbox has no accounts and that is the most common deployment there is, so
the module duck-types against it rather than naming it.

**The reason it is here is dot-stats.** A statistic has to be filed under a key, and
dot-stats refuses an account id as one before it leaves the server — so the scoped
pseudonymous id dot-user derives is what a board and an achievement are keyed by.
`PlaygroundPlatform.key_for_session` is the one function that decides, and without an
identity stack it files under something that lasts exactly as long as the session, which is
honest.

**Name changes are off here and on in the lobby.** A sandbox has a leaderboard on it: a
name that can change is a record whose owner cannot be recognised.

## The server module

`game/playground_module.gd` is the only file here that names dot-server, which is where
the family's own documentation says such a bridge belongs. It is also where the game
becomes administrable:

| | |
| --- | --- |
| `pg_timer` `pg_restart` `pg_style` `pg_track` `pg_top` | the run |
| `pg_cp` `pg_tp` `pg_cp_clear` | practice mode |
| `pg_zone` `pg_zone_mark` `pg_zone_spawn` `pg_zone_list` `pg_zone_undo` `pg_zone_save` | drawing zones, the `sm_zones` workflow |
| `pg_map` `pg_nextmap` `pg_rtv` `pg_extend` | maps |
| `pg_prop` `pg_undo` `pg_props_clear` | props |
| `pg_status` | everything at once |
| `pg_services` `pg_gag` `pg_mute` | chat, voice and moderation |
| `pg_arena` | the fight, off by default |
| `pg_waves` | the director's NPCs, off by default |
| `pg_vote` | what plays next |
| `pg_achievements` | what somebody has earned |

**The zone commands are `CHANGEMAP`, not `GENERIC`.** Drawing a start line is editing
the map's rules, and somebody who can do it can invalidate every record on it.

**One painter per admin.** Two admins drawing at once would otherwise share a first
corner, and the failure is a zone spanning the distance between them — saved, with
nothing to say it was not meant.

**A zone is live the moment it is drawn** (`set_zones` right after the second mark). An
admin who had to reload the map to test a start line would test it once.

**Saving a set with a problem is refused, not warned about.** A zone file with a start
and no end is playable and unfinishable, and the moment it is on disk somebody else has
a copy.

There is deliberately **no `pg_tickrate` cvar**. A second cvar for the same number is a
second number that can disagree with the first.

## Maps are content, not projects

Three maps, one game. See [dot-map's CLAUDE.md](../dot-map/CLAUDE.md) for why a
project per map falls apart at map forty.

**The built-in maps build their geometry and their zones from the same constants**, in
one script, so a start line cannot drift half a metre from where the ramps actually
are — which would be a leaderboard nobody can compare with anybody else's.

A **delivered** map cannot do that: it ships geometry and a zone file. So
`tools/export_zones.gd` writes those files from the same source, they are committed,
and `examples/headless_playground.gd::_test_zone_file_matches_the_map` checks that the
file still matches what the map builds. A hand-copied zone file is correct exactly
once.

**Run the tool after changing a map**, or the check fails:

```bash
godot --headless --path . --script tools/export_zones.gd
```

`pg_lobby`'s **main track** has no timer, and that is not filler: it is the one place
that proves the rest of the game does not quietly require one. Its bonus track does —
see above.

## The movement is a bhop server's, not the addon's defaults

`PlaygroundPlayer._tunables` differs from `DotFpsTunables`'s defaults in five places
and every one is the genre:

| | Default | Here | Why |
| --- | --- | --- | --- |
| `auto_hop` | off | **on** | Otherwise the skill is a keyboard-hardware contest, not an aiming one |
| `bhop_speed_cap_scale` | 0 | 0 | Kept at 0 explicitly. A cap is what those shooters added to *stop* bunny-hopping |
| `crease_slide` | on | on | Kept explicitly: a surf map is made of seams |
| `coyote_time` | 0.1 | **0** | Free speed on a timed map, and a run set with it is not comparable |
| `jump_buffer_time` | 0.1 | **0** | The same |

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . --script tools/export_zones.gd
godot --headless --path . res://examples/headless_playground.tscn   # 275 checks
godot --headless --path . res://examples/headless_net.tscn          # 109 checks
godot --headless --path . res://examples/dedicated.tscn             # 126 checks
```

**Run the check-only pass first.** A script that fails to parse makes the scene fail
to load and the process then **hangs** rather than exiting.

**And read the suite's own stderr even when it exits 0.** A script error inside a test
aborts *that test* and not the run, so the checks after it never execute and the total
goes down rather than the suite failing. It happened here: a call to a method
`DotTimerZone` does not have took two checks out of a run that reported 201 passed and 0
failed.

**`tools/screenshot.sh <map>` renders a map so a person can look at it.** It needs
`xvfb-run` — `--headless` gives a null renderer and saves empty frames, which is worse
than no screenshot because it looks like one. Copied from `game-arena`'s rather than
shared with it, because these are separate repositories. Two of the three problems above
were found by a bot; the finish cap being invisible behind its own pillar was found by
looking at the picture.

Every addon's own suite still has to pass too — this one exercises the joins and
deliberately does not re-test what they cover.

## A vehicle is a prop with seats in it

`dot-vehicle` is installed here for the same reason `dot-npc` is: for the half this game
was going to get wrong. What it is **not** used for is spawning.

**Every vehicle arrives through `DotPropSpawner` and is handed over with
`DotVehicleSpawner.adopt()`.** That is the whole design and it is the same call the
entities make one paragraph up: a vehicle is a `DotPropInstance` first — it counts against
the prop budget, it is on the undo stack, it goes when its owner leaves, a physics gun can
pick it up and a gravity gun can punt it. `adopt()` did not exist before this; it was added
to dot-vehicle for exactly this deployment, and its CLAUDE.md says why.

The join is one field of `meta`, exactly as an entity's script path is:

```json
{ "kind": "vehicle", "vehicle": "buggy" }
```

`PlaygroundVehicles` is the second catalogue and it is deliberately not merged with the
prop one: `DotPropCatalogue` says what may be put in the world and what it costs, and
`DotVehicleCatalogue` says how a thing drives. **The prop rows are derived from the vehicle
rows**, so the mass a physics gun checks and the mass the chassis puts on the rigid body
are the same number read once — the two-hand-kept-copies shape that already gave dot-props
a prop a gun refused for being too heavy and a gravity gun threw like a beach ball.

### What building it found

- **A wheel above the chassis box is a car that does not move.** `PlaygroundProp` builds a
  collision box centred on the origin, so a 0.9 m body reaches 0.45 m down; wheels at
  `wheel_y = 0.15` with a 0.42 m radius contact at 0.27 and never reach the floor. The box
  rests on the ground, the wheels hang in the air, and a raycast vehicle with nothing in
  contact has no traction, no steering and no brakes. **Every number in the tunables reads
  correctly** and the car sits there at full throttle. `wheel_y` is negative here for that
  reason and the suite counts the wheels separately from measuring the drive, because "no
  wheels" and "wheels that touch nothing" are the same symptom.
- **`configure` must run before `adopt`.** `DotVehicleWheeled` walks the body's direct
  children for `VehicleWheel3D` once, at bind time, and caches what it finds. The other
  order gives four wheels nothing drives.
- **`continuous_cd` is turned back off for a vehicle.** `PlaygroundProp` turns it on
  because a sandbox throws things; on a body with wheel raycasts under it, it fights the
  wheel solver and the car judders at speed — which reads as bad suspension.
- **A rider's node is carried and their movement state is not.** dot-vehicle reparents the
  rider into the seat, which is what puts a client's camera on the vehicle without a line
  about cameras anywhere. But the timer, the NPC candidate list, the HUD and
  `PlaygroundPlayerNet` all read `controller.state.position`, and nothing was writing it —
  so a passenger is drawn on every **other** machine at the spot where they got in, for the
  whole journey, while being perfectly correct on their own. `Playground._carry_riders`
  copies it back, after the vehicles tick and before the timers are fed, which is the same
  ordering rule the players already follow.
- **The controller is turned off, not ignored.** `PlaygroundPlayer.riding` skips
  `simulate_tick` while still sampling, because those same keys are what the car is driven
  with — `Playground.drive_command` is the whole mapping and it is static so a test can
  reach it without a player.
- **A riding client must stop predicting.** `PlaygroundPlayerNet` has two new branches: no
  `simulate_tick` while riding, and the server's position IS written onto the node even on
  a predicted entity, because there is no replay to spoil.

### The suites, and the one thing that is a harness artefact

`headless_playground` drives it in one process; `headless_net` drives it over the socket,
which is the only place `DotVehicleNetSync` has ever been. **In `headless_net` the client's
mirror is taken out of the physics world for the drive.** Both halves are plain nodes in
one scene tree, so they share one physics space and the frozen mirror sits at exactly the
coordinates the server's car is trying to leave — the first version of that test measured a
car reversing at half a metre a second, which was the server's buggy wedged against its own
reflection. On two machines there is no such body.

**Also worth knowing before writing a test here: a car crosses this sandbox in seconds.**
The first version drove into the scenery at (24, 24) and then measured a stationary vehicle
at full throttle. The corner at (-60, -60) is the flat, empty one.

`F` gets in and out. Not `E`, which already spawns here — and the day this game gains a use
verb, the two want swapping together.

## A price list, a camera, and being picked up

Three addons joined in one pass, and each one is the answer to something this project had
been asking without a way to say it.

### `pg_shop`: a sandbox with prices

**Off by default, and the cvar is the whole argument.** A sandbox where everything is free
is a sandbox; a sandbox where a jeep costs four hundred credits is a *game*, and turning
one into the other because an addon was installed is exactly what this family's rule about
cvars exists to prevent.

A free spawn menu has no pacing: the first thing anybody does is fill the map with the
most expensive thing in it. A price list makes the wave mode worth playing — a wave pays,
a jeep costs, a player who spent everything on turrets has to earn the next one — and it
needs no new mechanic, because everything it wants is already here.

**The price list is derived, not authored.** `PlaygroundShop.catalogue()` walks the prop
catalogue and the weapon list and prices each entry from its mass, its size and its budget
cost. A hand-written list of fourteen props is a list that goes stale the first time
somebody adds a fifteenth, and this tree has shipped that bug four times in shell scripts
alone.

**Money is not the budget.** `DotPropLimits` still caps how much one player may have in
the world, because a filled map is a server nobody else can play on, and credits must not
be a way round that.

The charge happens through `PlaygroundNetBridge.charge_fn` — a callable, not a reference to
the shop, because the bridge is dot-net's half of this game and knows nothing about prices.
Unset, everything is free, so no call site has to branch on whether a shop exists.

### `pg_spec`: a sandbox is where watching is not about being dead

The interesting thing on a server like this is usually what somebody else is *making*, and
the answer to "what is that noise in the corner" is a camera. So the policy is the loosest
of the three games that have one — anybody, alive or dead, may watch anybody, and roaming
is on, because a free camera is how you look at a contraption from the outside.

It tightens the moment `pg_arena` goes on. A living player watching a living one while they
are shooting at each other is a wallhack, and that is exactly the moment this stops being a
sandbox.

### `pg_waves` also turns on being picked up

**The wave mode is the only co-operative thing in this family, and this is what makes it
one.** Until now a player killed by a wave respawned on a timer, so the other players
carried on shooting and nothing about the wave was harder for having dropped somebody.
Left 4 Dead's answer is the one every co-operative shooter since has copied: at zero health
you go **down**, you bleed out over ninety seconds, and picking you up costs somebody five
seconds of not shooting.

**One place decides.** `PlaygroundArena.death_rule_fn` is asked before a death is reported,
and a downed player is not reported to dot-match at all — the scoreboard has not lost
anybody, the respawn queue must not start counting, and the kill feed would be announcing a
death that did not happen. A game that asks "are we in a mode with incapacitation" at every
damage site has as many copies of the rule as it has damage sites, and the copies drift.

It shares the `pg_waves` cvar rather than having its own, because being killed by a wave is
what being downed is *for*: a separate switch is an operator who turned the waves on and
wonders why nobody is being picked up.

### The bug the suite found

**Two unknown players are zero metres apart.** `PlaygroundDowns._position_of` answers with a
sentinel far away for somebody it does not know — which is right — but *two* unknown ids
then sit at the **same** sentinel, so every distance check between them passes. A rescuer
who does not exist revived a casualty who did not exist, and the only symptom was a player
who should have bled out standing back up. `begin_revive` now refuses unless both are real
players. It is this family's usual shape: a guard that is correct for one argument and
wrong for two.

## Things deliberately not here

- **A vehicle a client predicts, and a smoothing pass in the renderer.** dot-vehicle's
  reasoning is that a rigid body is not reproducible across machines, so a predicted
  vehicle is a corrected one and a correction on something a player is steering reads
  worse than the latency. Interpolation is asked for on every positional spec; whether a
  driver still feels the round trip is a thing to MEASURE on a real link before writing
  anything, which has not been done.
- **Old note, kept because the shape is still true — networking.** dot-net's bridge is the next piece, and it is now the only thing
  between this and a server people can join: `examples/dedicated.tscn` boots a real
  `DotServer` with a listener, a console and the module, and what is missing is the
  per-player replication. The shape is ready — the timer and the prop spawner are
  authoritative in one place, the game owns the tick, and every controller is already
  `EXTERNAL`. **Props will not be predicted when it arrives** — rigid-body simulation is
  not reproducible across machines, so the bridge replicates transforms rather than
  replaying inputs. The sandbox half is already shaped for that: the spawn menu emits
  rather than spawning, and the tools send intent.
- **A scoreboard and a vote UI.** dot-ui has the screen stack; the spawn menu and the
  server browser are built on it, and a scoreboard and a vote panel are the same shape and
  are not written. The data behind both exists — `DotScoreboard` and
  `DotVoteDirector.build_options` — which is what makes this an omission rather than a gap.
- **A wardrobe screen.** The avatar schema, the entitlement check and the storage are all
  here and a player cannot yet *choose*: `DotAvatarSchema.choices_for` is the call.
- **Art.** `DotPropDef.icon_path` is read and nothing here sets it: the icons are drawn
  from the definition, which is honest for a project with no models. A server with
  content sets the field and gets its own thumbnails with no code change.
- **NPCs that fight.** They walk, chase, shove and are chased; dot-combat is installed and
  the arena gives *players* health, and giving it to an NPC as well is a `DotHealth` on a
  `DotNpcInstance` and a decision about what a wave is worth. Deliberate, because "the
  hunters can hurt you" is a different game from "the hunters are in the way", and this
  server has a cvar for turning the first one on and nothing yet for the second.
- **Welding, ropes, thrusters, duplicators.** dot-props says why: constraints are a much
  larger surface than spawning, they interact with each other, and a half-built
  constraint system is worse than none. `DotPropTool` is the hook.
- **Saving a build.** A save format has to survive the catalogue changing under it,
  which is a versioning problem rather than a physics one.
- **Real maps.** These three are test fixtures that happen to be playable. A real map
  is authored in the editor and zoned with `DotTimerZonePainter`.
- **Sound, art, animation.** The maps are unshaded grey boxes on purpose.
- **Replay playback.** dot-timer records and stores them; drawing a ghost is a game's
  own decision and every game's is different.
