extends SceneTree
## Dump the LIVE measured geometry of each screen to JSON, for
## tools/render_layout.py to draw at true viewport proportions.
##
## Reads the real tree after layout settles — not the .tscn, which only says
## what was authored, not what the container pass produced.

const TARGETS: Array[Dictionary] = [
	{"name": "hub_portal", "path": "res://screens/hub_portal.tscn", "payload": {}},
	{"name": "trial_host", "path": "res://screens/trial_host.tscn",
		"payload": {"trial_id": "false_witness"}},
	{"name": "trial_results", "path": "res://screens/trial_results.tscn", "payload": {}},
]

const VIEWPORTS: Array[Vector2i] = [Vector2i(1059, 1884), Vector2i(360, 640)]


func _init() -> void:
	_run.call_deferred()


func _collect(node: Node, out: Array, origin: Vector2) -> void:
	if node is Control:
		var c: Control = node as Control
		var text: String = ""
		if c is Label:
			text = (c as Label).text
		elif c is Button:
			text = (c as Button).text
		out.append({
			"name": String(c.name),
			"cls": c.get_class(),
			"pos": [c.global_position.x - origin.x, c.global_position.y - origin.y],
			"size": [c.size.x, c.size.y],
			"visible": c.is_visible_in_tree(),
			"text": text,
		})
	for child: Node in node.get_children():
		_collect(child, out, origin)


func _run() -> void:
	await process_frame
	var save: Node = root.get_node_or_null("Save")
	if save != null:
		save.call("wipe")

	var dump: Array = []
	for target: Dictionary in TARGETS:
		for viewport: Vector2i in VIEWPORTS:
			root.content_scale_size = viewport
			root.size = viewport
			await process_frame
			var screen: Control = (load(str(target["path"])) as PackedScene).instantiate()
			screen.call("configure", target["payload"])
			root.add_child(screen)
			for _i: int in range(14):
				await process_frame
			var nodes: Array = []
			_collect(screen, nodes, screen.global_position)
			dump.append({
				"name": str(target["name"]),
				"viewport": [viewport.x, viewport.y],
				"nodes": nodes,
			})
			screen.free()
			await process_frame

	var file: FileAccess = FileAccess.open("/tmp/layout_dump.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(dump))
	file.close()
	print("wrote /tmp/layout_dump.json  (%d screen/viewport pairs)" % dump.size())
	quit()
