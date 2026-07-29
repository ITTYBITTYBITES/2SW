extends Node

func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	var vp := get_viewport()
	if vp == null:
		print("CAPTURE_ERROR: No viewport found")
		get_tree().quit()
		return

	var tex := vp.get_texture()
	if tex == null:
		print("CAPTURE_ERROR: No texture")
		get_tree().quit()
		return

	var img: Image = tex.get_image()
	if img == null:
		print("CAPTURE_ERROR: Failed to get image")
		get_tree().quit()
		return

	# Determine filename based on current scene
	var scene_path := ""
	if get_tree().current_scene:
		scene_path = get_tree().current_scene.scene_file_path

	var filename := "hub_actual.png"
	if "settings" in scene_path.to_lower():
		filename = "settings_actual.png"
	elif "wardrobe" in scene_path.to_lower():
		filename = "wardrobe_actual.png"

	var save_path := "res://previews/" + filename

	# Make sure directory exists
	DirAccess.make_dir_recursive_absolute("res://previews")

	var err := img.save_png(save_path)
	if err == OK:
		print("CAPTURE_SUCCESS: Saved " + save_path)
	else:
		print("CAPTURE_ERROR: Failed to save (code %d)" % err)

	get_tree().quit()
