extends VBoxContainer
class_name HubSidebar
## HubSidebar — a vertical rail of OrbitNodes down one edge of the hub.
##
## The extensibility requirement, in one place. Adding a destination is:
##
##     sidebar.add_node("progress", "Progress")
##
## No offsets to recompute, no anchors to re-derive, no scene edit. The rail
## is a VBoxContainer pinned to its edge and vertically centred, so entries
## stack and re-centre themselves as the list grows from one to four.
##
## WHY A CONTAINER AND NOT ANCHORED CHILDREN
## Every layout bug in this project's history came from hand-computed
## positions: shard markers placed 269px from where the eye actually was, an
## Iris pinned to a fixed 520px inside a shrinking band, action buttons at a
## fixed 296px on a 360px screen. A container cannot make those mistakes —
## it measures its children and places them, every frame, for free.
##
## CAPACITY
## MAX_NODES exists so the rail fails loudly rather than silently running off
## the screen. At the design height a rail holds four comfortably; a fifth
## would collide with the header or the hint, and a caller adding one should
## be told at once rather than discovering it on a device.

## Beyond this the rail overflows the vertical space the hub has.
const MAX_NODES: int = 4

## Gap between stacked nodes.
const NODE_SPACING: float = 26.0

## Emitted when any node on this rail is pressed. The rail knows route names;
## it does not know what a route means, so the hub still owns navigation.
signal node_pressed(route: String)

var _nodes: Array[OrbitNode] = []


func _ready() -> void:
	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override("separation", int(NODE_SPACING))
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Append a destination. Returns the node so a caller can disable or restyle
## it, or null when the rail is full.
func add_node(route: String, label_text: String) -> OrbitNode:
	if not Log.must(_nodes.size() < MAX_NODES, "HubSidebar",
			"rail is full (%d); a fifth node would overflow the hub"
			% MAX_NODES):
		return null

	var wrapper := VBoxContainer.new()
	wrapper.alignment = BoxContainer.ALIGNMENT_CENTER
	# Palette is read through the resolved node rather than by name.
	#
	# A --script MainLoop (tools/polish_audit.gd) compiles BEFORE autoloads
	# attach, so naming `Palette` directly makes it resolve to a scriptless
	# Node and every access throws. add_node() then died on its first line
	# and the rail stayed empty — the audit reported "the settings node
	# exists: FAIL" for a rail that works perfectly in the real game.
	wrapper.add_theme_constant_override("separation", int(_space_xxs()))
	wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapper.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	var node := OrbitNode.new()
	node.name = "Orbit_%s" % route
	node.configure(route, label_text)
	node.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	node.pressed.connect(_on_node_pressed.bind(route))
	wrapper.add_child(node)

	var label := Label.new()
	label.name = "Caption_%s" % route
	label.text = label_text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wrapper.add_child(label)

	add_child(wrapper)
	_nodes.append(node)
	_style_caption(label)
	return node


## Restyle every caption. Called on a palette change so the rail follows a
## rank-up with the rest of the app.
func restyle() -> void:
	for child: Node in get_children():
		for grandchild: Node in child.get_children():
			if grandchild is Label:
				_style_caption(grandchild as Label)
	for node: OrbitNode in _nodes:
		node.queue_redraw()


func node_count() -> int:
	return _nodes.size()


func nodes() -> Array[OrbitNode]:
	return _nodes


## Palette.SPACE_XXS, safe under a --script MainLoop.
func _space_xxs() -> float:
	var pal: Node = get_tree().root.get_node_or_null("Palette")
	if pal == null or pal.get_script() == null:
		return 4.0
	var consts: Dictionary = (pal.get_script() as GDScript).get_script_constant_map()
	return float(consts.get("SPACE_XXS", 4.0))


func _style_caption(label: Label) -> void:
	# Same reason as _space_xxs(): under a --script MainLoop the Palette
	# autoload has no script, so Palette.font() throws and takes add_node()
	# down with it before the node is ever appended.
	var pal: Node = get_tree().root.get_node_or_null("Palette")
	# Absent under a --script MainLoop; leaving the caption at theme defaults
	# is correct there, not a failure worth reporting.
	if pal != null and pal.get_script() != null:
		var consts: Dictionary = (pal.get_script() as GDScript).get_script_constant_map()
		label.add_theme_color_override("font_color",
			consts.get("COLOR_TEXT_DIM", Color.WHITE))
		label.add_theme_font_size_override("font_size",
			int(pal.call("font", consts.get("FONT_MICRO", 15))))


func _on_node_pressed(route: String) -> void:
	AudioManager.play_sfx(&"ui_tap")
	HapticsManager.pulse(&"ui_tap")
	node_pressed.emit(route)
