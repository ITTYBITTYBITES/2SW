extends Control

@onready var iris_view: Control = %IrisView
@onready var pupil_slider: HSlider = %PupilDilation
@onready var fiber_slider: HSlider = %FiberDensity
@onready var limbal_slider: HSlider = %LimbalDarkness
@onready var specular_slider: HSlider = %Specular
@onready var parallax_slider: HSlider = %Parallax
@onready var status_label: Label = %Status

func _ready() -> void:
	pupil_slider.value_changed.connect(_update_shader)
	fiber_slider.value_changed.connect(_update_shader)
	limbal_slider.value_changed.connect(_update_shader)
	specular_slider.value_changed.connect(_update_shader)
	parallax_slider.value_changed.connect(_update_shader)

	# Initial sync
	_update_shader(0.5)
	status_label.text = "Iris Inspector Ready - F6 to run"

func _update_shader(_value: float) -> void:
	if not iris_view or not iris_view.has_method("apply_state"):
		return

	# We push values directly to the shader material
	var mat = iris_view.get_node("%CoreEye").material as ShaderMaterial
	if mat == null:
		return

	mat.set_shader_parameter("pupil_dilation", pupil_slider.value)
	mat.set_shader_parameter("complexity_factor", fiber_slider.value)
	mat.set_shader_parameter("limbal_color", Color(0.02, 0.05, 0.09) * (1.0 - limbal_slider.value * 0.6))
	mat.set_shader_parameter("glow", specular_slider.value)
	mat.set_shader_parameter("refraction_strength", parallax_slider.value)

	status_label.text = "Updated"