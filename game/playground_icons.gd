class_name PlaygroundIcons
extends RefCounted

## Icons for the spawn menu, drawn from the definition when there is no artwork.
##
## [b]`DotPropDef.icon_path` is honoured first and almost never set here.[/b] A server
## with content points it at a rendered thumbnail and that is what the menu shows. This
## project ships no art, and a grid of forty identical grey squares is worse than a
## grid of names — so when the field is empty the icon is [i]derived from the same
## three fields the body is built from[/i]: the shape, the extent and the colour. A
## barrel is a green cylinder in the world and a green cylinder in the menu, at the
## right aspect ratio, because both come from `meta`.
##
## [b]Cached by what is drawn, not by prop id.[/b] Fourteen props here share four
## silhouettes and eleven colours; a four-hundred-prop catalogue shares far more. The
## key is the drawing, so two crates of the same colour and aspect are one texture —
## which matters because a menu that built four hundred images on open would hitch
## every time somebody pressed Q.

const CHANNEL := "playground.icons"

## Edge of the icon, in pixels. Square, because a grid of mixed sizes does not read.
const SIZE := 48

## How much of the icon the silhouette may fill, leaving a margin so shapes of
## different aspect ratios still look like a set.
const FILL := 0.78

## The proportions every entity is drawn at, whatever its body is. See [method for_def].
const ENTITY_ASPECT := 0.70

## Silhouettes. Not the same enum as [enum PlaygroundProp.Shape]: an entity and a
## weapon are not shapes in the world, and drawing them as boxes would make the menu's
## three kinds indistinguishable at a glance, which is the one thing an icon is for.
enum Glyph {
	BOX,
	SPHERE,
	CYLINDER,
	ENTITY,
	WEAPON,
}

static var _cache: Dictionary = {}


## The icon for one definition: its own artwork if it has any, else a drawn one.
static func for_def(def: DotPropDef) -> Texture2D:
	if def == null:
		return null

	if def.icon_path != "":
		var loaded := _load_artwork(def)

		if loaded != null:
			return loaded

	var glyph := _glyph_for(def)

	# An entity is drawn at a fixed, person-shaped aspect rather than its body's.
	# A wanderer is a 0.8 by 1.7 box, and at that ratio the capsule's head is three
	# pixels across and the icon reads as a coloured bar — which is what every entity
	# looked like in the first screenshot of the menu.
	var aspect := ENTITY_ASPECT if glyph == Glyph.ENTITY else _aspect_for(def)

	return generated(glyph, aspect, PlaygroundProp.colour_of(def))


## Artwork from `icon_path`, or null with a warning if it is not usable.
##
## Warned about rather than passed over: an operator who set the field and got a drawn
## icon would conclude the field does nothing, and the two failures — a path that is
## not mounted and a path that is not an image — need different fixes.
static func _load_artwork(def: DotPropDef) -> Texture2D:
	if not ResourceLoader.exists(def.icon_path):
		DotLog.warn(CHANNEL, "a prop's icon is not there", {
			"prop": String(def.id), "icon": def.icon_path
		})
		return null

	var res: Resource = load(def.icon_path)

	if not (res is Texture2D):
		DotLog.warn(CHANNEL, "a prop's icon is not a texture", {
			"prop": String(def.id), "icon": def.icon_path
		})
		return null

	return res as Texture2D


## The icon for a weapon. Always drawn: a weapon has no body to take a shape from.
static func for_weapon(def: PlaygroundWeaponDef) -> Texture2D:
	if def == null:
		return null

	return generated(Glyph.WEAPON, 1.0, def.colour)


static func _glyph_for(def: DotPropDef) -> Glyph:
	if PlaygroundSpawnables.kind_of(def) == PlaygroundSpawnables.Kind.ENTITY:
		return Glyph.ENTITY

	match PlaygroundProp.shape_of(def):
		PlaygroundProp.Shape.SPHERE:
			return Glyph.SPHERE
		PlaygroundProp.Shape.CYLINDER:
			return Glyph.CYLINDER
		_:
			return Glyph.BOX


## Width over height of the silhouette, from the prop's own extent.
##
## Clamped to a factor of four either way. A plank is 3 m by 15 cm, which drawn to
## scale is a line: the icon has to say "long and thin" without becoming invisible.
static func _aspect_for(def: DotPropDef) -> float:
	var extent := PlaygroundProp.extent_of(def)

	if extent.y <= 0.0:
		return 1.0

	return clampf(extent.x / extent.y, 0.25, 4.0)


## A drawn icon. Cached by everything that affects the drawing.
static func generated(glyph: Glyph, aspect: float, colour: Color) -> Texture2D:
	# Quantised into the key: two planks whose aspect differs in the fourth decimal
	# are one drawing, and without the rounding the cache would never hit.
	var key := "%d:%.2f:%s" % [glyph, aspect, colour.to_html(false)]

	if _cache.has(key):
		return _cache[key]

	var texture := ImageTexture.create_from_image(_draw(glyph, aspect, colour))
	_cache[key] = texture

	return texture


static func _draw(glyph: Glyph, aspect: float, colour: Color) -> Image:
	var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))

	var centre := Vector2(SIZE, SIZE) * 0.5

	# The silhouette's half-extent in pixels, fitted inside FILL of the icon at the
	# requested aspect ratio: the long axis takes the space and the short one gives
	# it up, so every glyph occupies the same area whatever its proportions.
	var half := Vector2(SIZE, SIZE) * FILL * 0.5

	if aspect >= 1.0:
		half.y /= aspect
	else:
		half.x *= aspect

	var edge := colour.darkened(0.45)

	for y in range(SIZE):
		for x in range(SIZE):
			var at := Vector2(float(x) + 0.5, float(y) + 0.5) - centre
			var depth := _inside(glyph, at, half)

			if depth <= 0.0:
				continue

			# A one-pixel darker rim, and a slight vertical lift, so the shapes read
			# as objects rather than as flat swatches. Cheap, and it is the whole
			# difference between "a coloured square" and "an icon".
			var lit := colour.lerp(Color.WHITE, 0.16 * (1.0 - float(y) / float(SIZE)))

			image.set_pixel(x, y, edge if depth < 1.4 else lit)

	return image


## How far inside the glyph a point is, in pixels. Zero or less is outside.
static func _inside(glyph: Glyph, at: Vector2, half: Vector2) -> float:
	match glyph:
		Glyph.SPHERE:
			var radius := minf(half.x, half.y)
			return radius - at.length()

		Glyph.CYLINDER:
			# A rectangle with elliptical caps: the body is the rectangle and the top
			# and bottom bulge, which is what makes a barrel not a crate at 48 px.
			var cap := half.x * 0.32
			var body := half.y - cap

			if absf(at.y) <= body:
				return half.x - absf(at.x)

			var over := (absf(at.y) - body) / cap
			var width := half.x * sqrt(maxf(1.0 - over * over, 0.0))

			return width - absf(at.x)

		Glyph.ENTITY:
			# A head and a narrower body under it, which is the shortest thing that
			# reads as "somebody" rather than "something".
			#
			# [b]The head has to be WIDER than the torso and the torso has to start
			# BELOW it.[/b] The first version had a torso spanning the full height at
			# 0.62 of the half-width and a head at 0.42 of it — so the head was drawn
			# entirely inside the body and every entity in the menu was a coloured
			# bar. It is obvious in a screenshot and invisible in every property.
			var head_r := half.x * 0.60
			var head_y := -half.y + head_r
			var head := head_r - (at - Vector2(0.0, head_y)).length()

			var shoulders := head_y + head_r * 0.55
			var torso := minf(
				half.x * 0.40 - absf(at.x),
				minf(at.y - shoulders, half.y - at.y)
			)

			return maxf(head, torso)

		Glyph.WEAPON:
			# An L: a barrel along the top and a grip below it.
			var barrel := minf(
				half.x - absf(at.x),
				half.y * 0.34 - absf(at.y + half.y * 0.42)
			)
			var grip := minf(
				half.x * 0.30 - absf(at.x + half.x * 0.34),
				half.y * 0.58 - absf(at.y - half.y * 0.30)
			)
			return maxf(barrel, grip)

		_:
			# A box, with the corners taken off. A square silhouette at 48 px next to
			# a circle is legible; a square next to another square is not, which is
			# why the aspect ratio above is doing the work here.
			var inset := minf(half.x, half.y) * 0.18
			var corner := Vector2(
				absf(at.x) - (half.x - inset), absf(at.y) - (half.y - inset)
			)

			if corner.x > 0.0 and corner.y > 0.0:
				return inset - corner.length()

			return minf(half.x - absf(at.x), half.y - absf(at.y))
