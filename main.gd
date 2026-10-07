extends Node2D

const GRADIENT_FOLDER := "res://gradients/"
const GRADIENT_PREVIEW_WIDTH := 96
const GRADIENT_PREVIEW_HEIGHT := 16
@onready var option_button : OptionButton = %OptionButtonGradients
var gradient_resources : Array = []

var slider_bindings = {
	"%SliderSimMix": "mix_t",
	"%SliderSpeed": "dt",
	"%SliderDampen": "damping",
	"%SliderSenseRadius": "species_interaction_radius",
	"%SliderForceSoftenMultiplier": "force_softening_mul",
	"%SliderCenterPull": "center_attraction",
	"%SliderMaxForce": "max_force",
	"%SliderMinDistance": "min_distance",
	"%SliderVisionRadius": "boid_vision_radius",
	"%SliderAlignmentForce": "alignment_force",
	"%SliderCohesionForce": "cohesion_force",
	"%SliderSeparationForce": "separation_force",
	"%SliderMinSpeed": "min_speed",
	"%SliderMaxSpeed": "max_speed",
	"%SliderMovementRandomness": "movement_randomness",
	"%SliderMovementScaling": "movement_scaling",
	
	"%SliderSensorDistance": "sensor_distance",
	"%SliderSensorAngle": "sensor_angle",
	"%SliderTurnStrength": "sensor_strength",
	"%SliderDepositAmount": "deposit_amount",
	"%SliderDiffusionRate": "diffusion_rate",
	"%SliderEvaporationRate": "evaporation_rate",
}

func _ready():
	# Connect all sliders and set defaults
	for slider_path in slider_bindings.keys():
		var slider = get_node(slider_path)
		var property = slider_bindings[slider_path]
		slider.value = %ParticleBoidsSlime.get(property)
		slider.connect("value_changed", Callable(self, "_on_slider_changed").bind(property))
	
	# Option dropdown default values
	%OptionStartInteractionRange.selected = int(%ParticleBoidsSlime.rand_start_interaction_range)
	%OptionStartRadiusMultiplier.selected =  int(%ParticleBoidsSlime.rand_start_radius_mul)
	%OptionStartSpeciesCount.selected = %ParticleBoidsSlime.start_species_count
	%OptionStartMethod.selected = %ParticleBoidsSlime.starting_method
	%OptionStartPointCount.selected = 2
	
	# Load color gradients for the trail field
	_load_gradients()
	%OptionButtonGradients.selected = 4
	_on_option_button_gradients_item_selected(4)
	
func _process(_delta):
	# SET READOUT VALUES
	%LabelPointsValue.text = str(snapped(%ParticleBoidsSlime.agent_count,1))
	%LabelSpeciesValue.text = str(snapped(%ParticleBoidsSlime.species_count,1))
	%LabelSpeedValue.text = str(snapped(%ParticleBoidsSlime.dt,.1))
	%LabelDampingValue.text = str(snapped(%ParticleBoidsSlime.damping,.01))
	%LabelSenseRadiusValue.text = str(snapped(%ParticleBoidsSlime.species_interaction_radius,.01))
	%LabelForceSoftenMultiplierValue.text = str(snapped(%ParticleBoidsSlime.force_softening_mul,.1))
	%LabelForceSoftenValue.text = str(snapped(%ParticleBoidsSlime.force_softening,.01))
	%LabelCenterPullValue.text = str(snapped(%ParticleBoidsSlime.center_attraction,.01))
	%LabelMaxForceValue.text = str(snapped(%ParticleBoidsSlime.max_force,.01))
	%LabelMinDistanceValue.text = str(snapped(%ParticleBoidsSlime.min_distance,1))
	%LabelCamCenterValue.text = "("+str(snapped(%ParticleBoidsSlime.camera_center.x,.1))+ ", " + str(snapped(%ParticleBoidsSlime.camera_center.y,.1)) + ")"
	%LabelZoomValue.text = str(snapped(%ParticleBoidsSlime.zoom,.01))
	%LabelVisionRadiusValue.text = str(snapped(%ParticleBoidsSlime.boid_vision_radius,1))
	%LabelAlignmentForceValue.text = str(snapped(%ParticleBoidsSlime.alignment_force,.1))
	%LabelCohesionForceValue.text = str(snapped(%ParticleBoidsSlime.cohesion_force,.1))
	%LabelSeparationForceValue.text = str(snapped(%ParticleBoidsSlime.separation_force,.1))
	%LabelMinSpeedValue.text = str(snapped(%ParticleBoidsSlime.min_speed,.1))
	%LabelMaxSpeedValue.text = str(snapped(%ParticleBoidsSlime.max_speed,.1))
	%LabelSliderMovementRandomnessValue.text = str(snapped(%ParticleBoidsSlime.movement_randomness,.01))
	%LabelSliderMovementScalingValue.text = str(snapped(%ParticleBoidsSlime.movement_scaling,.1))
	
	%LabelSensorDistanceValue.text = str(snapped(%ParticleBoidsSlime.sensor_distance,.1))
	%LabelSensorAngleValue.text = str(snapped(%ParticleBoidsSlime.sensor_angle,1))
	%LabelTurnStrengthValue.text = str(snapped(%ParticleBoidsSlime.sensor_strength,.1))
	%LabelDepositAmountValue.text = str(snapped(%ParticleBoidsSlime.deposit_amount,.1))
	%LabelDiffusionRateValue.text = str(snapped(%ParticleBoidsSlime.diffusion_rate,.1))
	%LabelEvaporationRateValue.text = str(snapped(%ParticleBoidsSlime.evaporation_rate,.001))
	
	# SET INTERACTION MATRIX TEXT
	var species_count = %ParticleBoidsSlime.species_count
	var interaction_matrix = %ParticleBoidsSlime.interaction_matrix
	var lines := []
	for i in range(species_count):
		var line = str(i + 1) + ": "
		for j in range(species_count):
			var val = snapped(interaction_matrix[i * species_count + j], 0.01)
			line += "%5.2f" % val
			if j < species_count - 1:
				line += " | "
		lines.append(line)
	%LabelIntMatrix.text = "INTERACTION MATRIX\n" + "\n".join(lines)

	# HANDLE PAUSE/RESUME
	if Input.is_action_just_pressed("pause_resume"):
		pause_resume()

func pause_resume():
	if %ParticleBoidsSlime.dt == 0.0:
		%ParticleBoidsSlime.dt = %ParticleBoidsSlime.paused_dt  # resume
		%ButtonPauseResume.text = "PAUSE"
	else:
		%ParticleBoidsSlime.paused_dt = %ParticleBoidsSlime.dt  # store current
		%ParticleBoidsSlime.dt = 0.0       # pause
		%ButtonPauseResume.text = "RESUME"

func _load_gradients():
	option_button.clear()
	gradient_resources.clear()

	var dir := DirAccess.open(GRADIENT_FOLDER)
	if dir == null:
		push_error("Gradient folder not found: " + GRADIENT_FOLDER)
		return

	var files : Array[String] = []
	dir.list_dir_begin()
	var file := dir.get_next()
	while file != "":
		if !dir.current_is_dir():
			if file.get_extension() == "tres":
				files.append(file)
		file = dir.get_next()
	dir.list_dir_end()

	# Sort alphabetically
	files.sort()
	for file_name in files:

		var path := GRADIENT_FOLDER + file_name
		var res := load(path)

		if res is GradientTexture1D:

			var gradient_tex : GradientTexture1D = res
			var preview := _generate_color_preview(gradient_tex)

			var index := gradient_resources.size()

			gradient_resources.append(gradient_tex)

			option_button.add_icon_item(
				preview,
				file_name.get_basename(),
				index
			)

	# Preselect first gradient
	if gradient_resources.size() > 0:
		option_button.select(0)
		_apply_gradient(0)

func _generate_color_preview(gradient_tex:GradientTexture1D) -> Texture2D:

	var img := Image.create(GRADIENT_PREVIEW_WIDTH, GRADIENT_PREVIEW_HEIGHT, false, Image.FORMAT_RGBA8)

	for x in GRADIENT_PREVIEW_WIDTH:

		var t := float(x) / float(GRADIENT_PREVIEW_WIDTH - 1)
		var col : Color = gradient_tex.gradient.sample(t)

		for y in GRADIENT_PREVIEW_HEIGHT:
			img.set_pixel(x, y, col)

	var tex := ImageTexture.create_from_image(img)

	return tex

func _apply_gradient(index:int):
	if index < 0 or index >= gradient_resources.size():
		return
	var gradient_tex : GradientTexture1D = gradient_resources[index]
	var mat := %ParticleBoidsSlime.material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("gradient_texture", gradient_tex)

func _on_slider_changed(value: float, property: String):
	%ParticleBoidsSlime.set(property, value)

func _on_button_restart_pressed() -> void:
	%ParticleBoidsSlime.restart_simulation()

func _on_button_pause_resume_pressed() -> void:
	pause_resume()

func _on_option_start_method_item_selected(index: int) -> void:
	%ParticleBoidsSlime.starting_method=index

func _on_option_start_interaction_range_item_selected(index: int) -> void:
	%ParticleBoidsSlime.rand_start_interaction_range=index

func _on_option_start_radius_multiplier_item_selected(index: int) -> void:
	%ParticleBoidsSlime.rand_start_radius_mul=index

func _on_option_start_point_count_item_selected(index: int) -> void:
	%ParticleBoidsSlime.start_agent_count=int(%OptionStartPointCount.get_item_text(index))

func _on_option_start_species_count_item_selected(index: int) -> void:
	%ParticleBoidsSlime.start_species_count=index
	%CheckBoxLockMatrix.disabled=false
	if (%ParticleBoidsSlime.start_species_count != %ParticleBoidsSlime.species_count):
			%CheckBoxLockMatrix.disabled=true

func _on_slider_sim_mix_value_changed(value: float) -> void:
	var plife_perc = int(value * 100)
	var boids_perc = 100 - plife_perc
	%LabelSimSplit.text = str(boids_perc)+"% Boids - "+str(plife_perc)+"% Particle Life"
	
# HANDLE MOUSE INPUTS
var dragging := false
var last_mouse_pos := Vector2()
func _unhandled_input(event):
	#if (%ParticleBoids.texture != null):
		#return

	if event is InputEventMouseButton:
		# Handle zoom
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			%ParticleBoidsSlime.zoom = clamp(%ParticleBoidsSlime.zoom * 1.05, %ParticleBoidsSlime.MIN_ZOOM, %ParticleBoidsSlime.MAX_ZOOM)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			%ParticleBoidsSlime.zoom = clamp(%ParticleBoidsSlime.zoom / 1.05, %ParticleBoidsSlime.MIN_ZOOM, %ParticleBoidsSlime.MAX_ZOOM)

		# Start/stop panning with right mouse button
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			dragging = event.pressed
			last_mouse_pos = event.position

	elif event is InputEventMouseMotion and dragging:
		# Convert drag delta to world space based on zoom
		var delta :Vector2= (event.position - last_mouse_pos) / %ParticleBoidsSlime.zoom
		last_mouse_pos = event.position
		%ParticleBoidsSlime.camera_center -= delta

func _on_check_box_show_particles_pressed() -> void:
	if %MMI.visible:
		%MMI.visible = false
	else:
		%MMI.visible = true

func _on_check_box_2_show_field_pressed() -> void:
	if %ParticleBoidsSlime.visible:
		%ParticleBoidsSlime.visible = false
	else:
		%ParticleBoidsSlime.visible = true

func _on_option_button_gradients_item_selected(index: int) -> void:
	_apply_gradient(index)
