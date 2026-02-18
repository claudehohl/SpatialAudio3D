@icon("icon.png")
class_name SpatialAudio3D extends AudioStreamPlayer3D
## A Godot 4 plugin that brings physically-informed 3D audio to your scenes
## - with distance-based delay, raycast-driven reverb, and dynamic occlusion, all derived from your level geometry at runtime.
##
## It consists of three components:
##   * Soundsource
##   * Reverber
##   * Soundplayer
##
## The *Soundsource* is the original audio emitter, it has a delay based on the player's distance to it.
## Soundsource also shoots raycasts in 8 different directions + up to determine where to create the Reverbers,
## and it measures the room size using additional measurement raycasts.
##
## The *Reverber* is a sound that is reflected on a wall, it has a delay and reverb effect, based on player's distance and room size.
##
## The *Soundplayer* is the entity that actually plays the audio. Why do I need an additional Soundplayer and not playing directly on Soundsource and Reverber?
## During development, I figured that setting the delay while playing sound generates audible cracks.
## To mitigate this, each Soundsource has two *Soundplayers*; one active playing a sound, and one in standby where I set delays.
## Every 10 meters, Soundsource does a crossfade between the active and inactive Soundplayer.
##
## A similar problem arises with the Reverber: Imagine it plays a sound in a big room with long reverb.
## Suddenly, you exit the room. The Reverber with the long reverb is repositioned 1m at the door, and the still playing reverb suddenly abrupts.
## To mitigate this, each Reverber also has two Soundplayers; one active playing a sound, and one in standby.
## If the player moves around and the reverber would be placed more than 10m away to it's former position, the standby Soundplayer is placed instead,
## letting the former reverber hall and fade out.

@export_category("Sound Properties")
@export var reverb_enabled: bool = true ## Enable reverb-effects with all its computations.[br][br]Disable if you just need it for occlusion detection, for example fading ambient rain when entering a house.
@export_range(-81, +80, 3.0, "suffix:dB") var reverb_volume_db: float = -6 ## Maximum volume of the reverbs.
@export_range(-1, 5, 0.05, "or_greater", "suffix:s") var reverb_fadeintime: float = 2.0 ## Fade-in time when a reverb is added at a wall.[br][br]The default of 2s is a good value where changes in environment merge well into the overall sound mix.[br]If you have small areas with little changes of distances, set this value to low (0.2s) so that repositioned reverbs don't get stuck for too long in a position. In a large area, when the raycast suddenly hits a close wall, the sudden appearing reverb can sound unnatural.[br][br]Set to -1 for dynamic fade time (based on wetness).
@export_range(-1, 8, 0.05, "or_greater", "suffix:s") var reverb_fadeouttime: float = 2.0 ## Fade-out time when a reverb is removed.[br][br]The default of 2s is a good value where changes in environment merge well into the overall sound mix.[br]If you have small areas with little changes of distances, set this value to low (0.2s) so that repositioned reverbs don't get stuck for too long in a position.[br][br]Set to -1 for dynamic fade time (based on wetness).
@export_range(1, 20_000, 0.1, "suffix:Hz") var occlusion_lp_cutoff: int = 600 ## Frequency when soundsource is occluded behind walls.
@export_range(0, 5, 0.05, "or_greater", "suffix:s") var occlusion_fadetime: float = 0.5 ## Fadetime when occlusion changes.
@export_range(0, 100, 0.1, "or_greater", "suffix:m") var bass_proximity: int = 50 ## The closer you are to a wall, the more bass you will hear.[br][br]The effect starts at this value (distance to the wall).[br][br]0 to disable.

@export_category("Physics")
@export_range(1, 100, 1, "or_greater", "suffix:m") var max_raycast_distance: int = 100 ## Maximum distance for the reverb raycasts.
@export_flags_3d_physics var collision_mask: int = 1 ## Mask for the raycast where to add reverb.
@export var roomsize_multiplicator: float = 6.0 ## How much hall to add compared to room size.[br]Sometimes you have a small room but you need a long reverb.
@export_range(1, 340, 1, "or_greater", "suffix:m/s") var speed_of_sound: int = 340 ## How fast sound travels through the air.

@export_category("System")
@export_range(1, 60, 0.1, "or_greater", "suffix:per second") var audiophysics_ticks: int = 10 ## The number of audio physics calculations per second.[br]Tied to _physics_process().[br][br]Use 30-60 for fast moving sounds like a motorcycle passing by.[br][br]Default: 10.
@export var loop: bool = false ## Loop audio indefinitely.
@export var shut_up: bool = false ## Mute output.
@export var debug: bool = false ## Visualize raycasts, measurement rays and reverb-audioplayers.

@onready var player_camera: Camera3D = get_viewport().get_camera_3d() # store reference to camera so that global_position is always up to date
@onready var raycasts_coords: Array = [
	Vector3(0, 0, max_raycast_distance),						# N
	Vector3(max_raycast_distance, 0, max_raycast_distance),		# NW
	Vector3(max_raycast_distance, 0, 0),						# W
	Vector3(max_raycast_distance, 0, -max_raycast_distance),	# SW
	Vector3(0, 0, -max_raycast_distance),						# S
	Vector3(-max_raycast_distance, 0, -max_raycast_distance),	# SE
	Vector3(-max_raycast_distance, 0, 0),						# E
	Vector3(-max_raycast_distance, 0, max_raycast_distance),	# NE
	Vector3(0, max_raycast_distance, 0),						# U
#	Vector3(0, max_raycast_distance, max_raycast_distance),		# U 45°
#	Vector3(0, -max_raycast_distance, 0),						# D
]

# this is the soundsource audioplayer.
var soundsource: Soundsource

# internal vars
var do_update: bool = false
var tick_interval: int
var _tick_counter: int = -1 # initialize the counter with enough time for the engine to initialize
var _debug: Dictionary
var debugsphere: Node3D
var fade_tween: Tween
var lowpass_tween: Tween
var xfadetime: float = 1.000
enum fx {delay, reverb, reverb_hipass, lowpass}


func _ready():
	# add soundsource
	soundsource = Soundsource.new() # @export variables are overridden on _init, so we pass them right after to have the actual values

	# @export vars
	soundsource.loop = loop
	soundsource.shut_up = shut_up
	soundsource.debug = debug
	soundsource.audiophysics_ticks = audiophysics_ticks
	soundsource.speed_of_sound = speed_of_sound
	soundsource.max_raycast_distance = max_raycast_distance
	soundsource.roomsize_multiplicator = roomsize_multiplicator
	soundsource.collision_mask = collision_mask
	soundsource.reverb_enabled = reverb_enabled
	soundsource.reverb_volume_db = reverb_volume_db
	soundsource.bass_proximity = bass_proximity
	soundsource.reverb_fadeintime = reverb_fadeintime
	soundsource.reverb_fadeouttime = reverb_fadeouttime
	soundsource.occlusion_lp_cutoff = occlusion_lp_cutoff
	soundsource.occlusion_fadetime = occlusion_fadetime

	# module vars
	soundsource.name = name
	soundsource.stream = stream
	soundsource.volume_db = volume_db
	soundsource.max_polyphony = max_polyphony
	soundsource.doppler_tracking = doppler_tracking
	soundsource.soundsource = soundsource

	add_child(soundsource) # this calls _ready(), so vars needs to be set before add_child()
	# but position can only be set when node is in tree, e.g. after add_child()

	# calculate how often (physics-frames) we run
	tick_interval = max(0, roundi(Engine.physics_ticks_per_second / max(1, audiophysics_ticks)))

	# start playing on autoplay
	if autoplay:
		stop()
		await get_tree().create_timer(0.1).timeout # reverbers aren't ready.
		soundsource.do_play()


func _physics_process(_delta):
	# keep rotation locked
	global_rotation = Vector3(0, 0, 0)

	if _tick_counter >= tick_interval:
		soundsource.update_run()
		_tick_counter = 0

	# update tick
	_tick_counter += 1


func do_play():
	soundsource.do_play()


func do_stop():
	soundsource.do_stop()


func do_set_stream(sound: AudioStream):
	soundsource.do_set_stream(sound)


func create_raycast(name_p, target_position) -> RayCast3D:
	var r = RayCast3D.new()
	r.name = name_p
	r.target_position = target_position
	r.collision_mask = collision_mask
	r.enabled = false
	return r


func create_raycast_sector(start_angle: int = 0, width_factor: float = 1.5, bearing_raycount: int = 20, heading_count: int = 7) -> Array[RayCast3D]:
	var rays: Array[RayCast3D] = []
	var i = 0
	for heading: float in range(0, heading_count, 1): # 0: ground, 7: above
		heading = heading/PI
		for bearing: float in range((bearing_raycount/2.0 * -1), (bearing_raycount/2.0)): # -7: right, 7: left
			bearing = bearing / bearing_raycount * width_factor
			var mr = RayCast3D.new()
			mr.name = "mray" + str(i)
			add_child(mr)
			mr.target_position = Vector3(max_raycast_distance, 0, 0)
			mr.collision_mask = collision_mask
			mr.debug_shape_custom_color = Color("#ff0")
			mr.debug_shape_thickness = 1
			mr.rotation = Vector3(0, bearing, heading) + Vector3(0, deg_to_rad(-start_angle), 0)
			mr.enabled = false

			if debug:
				var dray = Debugray.new()
				dray.visibility_range_end = max_raycast_distance
				dray.visibility_range_end_margin = max_raycast_distance / 10.0
				dray.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
				mr.add_child(dray)

			rays.append(mr)
			i += 1
	return rays


func create_soundplayer(name_p: String, with_reverb_fx: bool = true) -> Soundplayer:
	var soundplayer := Soundplayer.new()

	# @export vars
	soundplayer.loop = loop
	soundplayer.shut_up = shut_up
	soundplayer.debug = debug
	soundplayer.audiophysics_ticks = audiophysics_ticks
	soundplayer.speed_of_sound = speed_of_sound
	soundplayer.max_raycast_distance = max_raycast_distance
	soundplayer.roomsize_multiplicator = roomsize_multiplicator
	soundplayer.reverb_enabled = reverb_enabled
	soundplayer.reverb_volume_db = reverb_volume_db
	soundplayer.bass_proximity = bass_proximity
	soundplayer.reverb_fadeintime = reverb_fadeintime
	soundplayer.reverb_fadeouttime = reverb_fadeouttime
	soundplayer.occlusion_lp_cutoff = occlusion_lp_cutoff
	soundplayer.occlusion_fadetime = occlusion_fadetime

	# module vars
	soundplayer.name = name_p
	soundplayer.stream = stream
	soundplayer.volume_db = volume_db
	soundplayer.max_polyphony = max_polyphony

	# BUG: Doppler-tracking interferes with set_delay.
	# The delay only grows bigger and bigger when doppler-tracking is used, so we won't use it for now.
	soundplayer.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED

	soundplayer.with_reverb_fx = with_reverb_fx
	soundplayer.soundsource = soundsource

	return soundplayer


func create_audiobus(bus_name, vol_db = 0):
	var a = AudioServer.bus_count
	AudioServer.add_bus(a)
	AudioServer.set_bus_name(a, bus_name)
	AudioServer.set_bus_volume_db(a, vol_db)
	AudioServer.set_bus_send(a, "Master")


func remove_audiobus(bus_name: String):
	#print("removing bus ", bus_name)
	var a = AudioServer.get_bus_index(bus_name)
	AudioServer.remove_bus(a)


## sets the volume.
## if you provide fadetime, it will fade to volume using an internal tweener.
## if you need to fade more than one value at a time in this player, you can provide a tweener.
func set_audiobus_volume(bus_name, vol_db, fadetime: float = 0, tweenvar: Tween = null):
	#if debug: print("set_audiobus_volume(%s, %f, %f)" % [bus_name, vol_db, fadetime])
	var a = AudioServer.get_bus_index(bus_name)
	if fadetime == 0:
		AudioServer.set_bus_volume_db(a, vol_db)
	else:
		var current_volume = AudioServer.get_bus_volume_db(a)
		if tweenvar:
			tweenvar.play()
			tweenvar.tween_method(tweensetvol.bind(a), current_volume, vol_db, fadetime)
		else:
			if fade_tween:
				fade_tween.kill()
			fade_tween = create_tween()
			fade_tween.tween_method(tweensetvol.bind(a), current_volume, vol_db, fadetime)

# this is a little helper method for tweening.
# tween_method always tweens the first value.
# but the first value in set_bus_volume_db() is bus index, so we provide volume as the first value for tween_method.
func tweensetvol(vol, bus_index):
	AudioServer.set_bus_volume_db(bus_index, vol)


func add_audioeffect(bus_name, effect_type: fx):
	var a = AudioServer.get_bus_index(bus_name)
	match effect_type:

		fx.delay:
			var delay = AudioEffectDelay.new()
			delay.dry = 0
			delay.tap1_delay_ms = 0
			delay.tap1_level_db = 0
			delay.tap1_pan = 0
			delay.tap2_active = false
			AudioServer.add_bus_effect(a, delay, 0)

		fx.reverb:
			var reverb = AudioEffectReverb.new()
			reverb.dry = 0
			reverb.spread = 0
			reverb.hipass = 0.2
			reverb.dry = 0
			reverb.wet = 1
			reverb.predelay_feedback = 0
			AudioServer.add_bus_effect(a, reverb, 1)

		fx.lowpass:
			var lowpass = AudioEffectLowPassFilter.new()
			lowpass.cutoff_hz = 20500
			AudioServer.add_bus_effect(a, lowpass, 2)


func set_audioeffect(bus_name, effect_type: fx, params):
	#if debug: print("set_audioeffect(%s, %s, %s)" % [bus_name, effect_type, JSON.stringify(params)])
	var a = AudioServer.get_bus_index(bus_name)
	match effect_type:

		fx.delay:
			var delay_fx = AudioServer.get_bus_effect(a, 0)
			delay_fx.tap1_delay_ms = params.delay

		fx.reverb:
			var reverb_fx = AudioServer.get_bus_effect(a, 1)
			reverb_fx.room_size = params.room_size
			reverb_fx.wet = params.wetness
			reverb_fx.dry = 1 - params.wetness

		fx.reverb_hipass:
			var reverb_hipass_fx = AudioServer.get_bus_effect(a, 1)
			reverb_hipass_fx.hipass = params.hipass

		fx.lowpass:
			var lowpass_fx = AudioServer.get_bus_effect(a, 2)
			if params.fadetime == 0:
				lowpass_fx.cutoff_hz = params.lowpass
			else:
				if params.fadetime > 0:
					if lowpass_tween:
						lowpass_tween.kill()
					lowpass_tween = create_tween()
					# fading in higher frequencies (20'000 - 6'000) is less noticeable than fading in the lower frequencies.
					if params.lowpass < lowpass_fx.cutoff_hz: # fade fast through the higher frequencies
						lowpass_tween.set_ease(Tween.EASE_OUT)
					else:
						lowpass_tween.set_ease(Tween.EASE_IN) # we are low, start slowly
					lowpass_tween.set_trans(Tween.TRANS_QUINT)
					lowpass_tween.tween_property(lowpass_fx, "cutoff_hz", params.lowpass, float(params.fadetime)).from_current()
				else:
					push_error("ERROR: fadetime not set in SpatialAudioStreamPlayer3D --> set_audioeffect --> fx.lowpass!")


func toggle_audioeffect(bus_name, effect_type: fx, enabled):
	var a = AudioServer.get_bus_index(bus_name)
	match effect_type:

		fx.delay:
			AudioServer.set_bus_effect_enabled(a, 0, enabled)

		fx.reverb:
			AudioServer.set_bus_effect_enabled(a, 1, enabled)

		fx.lowpass:
			AudioServer.set_bus_effect_enabled(a, 2, enabled)


func calculate_delay(distance: float):
	return round(distance / speed_of_sound * 1000)


# Soundsource:
# responsible for: positions and distances
# room size and wetness (calc_reverb)
# performs calculations over all raycasts/reverbers every X (0.5) seconds
# reverber.update_position()
# spawns reverbers
class Soundsource extends SpatialAudio3D:

	var raycasts: Array[RayCast3D]
	var reverbers: Array[Reverber]
	var measurement_rays: Array[RayCast3D]
	var distances: Array[float]
	var distance_to_player: float
	var distance_to_player_since_last_delay_update: float
	var delay_ms:
		set(v):
			if delay_ms != v:
				delay_ms = v
				var _soundplayer_active := soundplayer_active
				var _soundplayer_standby := soundplayer_standby

				if soundplayer_active.state == soundplayer_active.ss.active:
					soundplayer_standby.delay_ms = v
					soundplayer_active.set_inactive(xfadetime)
					soundplayer_standby.set_active(xfadetime)

					soundplayer_active = _soundplayer_standby
					soundplayer_standby = _soundplayer_active
	var room_size = 0.0
	var wetness = 1.0
	var soundplayer_active: Soundplayer
	var soundplayer_standby: Soundplayer
	var _is_playing_starting: bool = false


	func _ready():

		if debug:
			#print("spawning soundsource: ", name)
			var ds = Debugsphere.new()
			ds.max_raycast_distance = max_raycast_distance
			ds.size = 0.0
			ds.label_offset = Vector3(0, 3, 0)
			ds.name = "Debugsphere " + name
			add_child(ds)
			debugsphere = ds
			ds.line1 = "☼ " + name


		# create soundplayers for delay-crossfading
		soundplayer_active = create_soundplayer(name + "-A", false)
		soundplayer_standby = create_soundplayer(name + "-B", false)
		add_child(soundplayer_active)
		add_child(soundplayer_standby)

		# set one active
		soundplayer_active.set_active()
		soundplayer_standby.set_inactive()

		# Only create raycasts, reverbers and measurement rays when reverb is enabled
		if reverb_enabled:

			# create raycasts
			var raycast_index = 0
			for c in raycasts_coords:
				var rc = create_raycast("ray " + name + "#" + str(raycast_index), c)

				var dray = Debugray.new()
				dray.visibility_range_end = max_raycast_distance * 1.3
				dray.visibility_range_end_margin = max_raycast_distance / 10.0
				dray.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
				rc.add_child(dray)

				var dray_normal = Debugray.new()
				rc.add_child(dray_normal)

				add_child(rc)
				raycasts.append(rc)

			# create reverbers
			raycast_index = 0
			for rc in raycasts:
				var reverber = create_reverber(name, raycast_index)
				get_tree().get_root().add_child.call_deferred(reverber)
				reverbers.append(reverber)
				raycast_index += 1

			# create measurement rays
			measurement_rays = create_raycast_sector(0, 2*PI, 12, 3)
			for mr in measurement_rays:
				distances.append(-1)


	func _physics_process(_delta):
		if debug:
			dump_debug()
			debugsphere.update_label()


	func _exit_tree():
		for r in reverbers:
			r.queue_free()
		for c in get_children():
			remove_child(c)


	func create_reverber(name_p, raycast_index: int) -> Reverber:
		var reverber := Reverber.new()

		# @export vars
		reverber.loop = loop
		reverber.shut_up = shut_up
		reverber.debug = debug
		reverber.audiophysics_ticks = audiophysics_ticks
		reverber.speed_of_sound = speed_of_sound
		reverber.max_raycast_distance = max_raycast_distance
		reverber.roomsize_multiplicator = roomsize_multiplicator
		reverber.reverb_enabled = reverb_enabled
		reverber.reverb_volume_db = reverb_volume_db
		reverber.bass_proximity = bass_proximity
		reverber.reverb_fadeintime = reverb_fadeintime
		reverber.reverb_fadeouttime = reverb_fadeouttime
		reverber.occlusion_lp_cutoff = occlusion_lp_cutoff
		reverber.occlusion_fadetime = occlusion_fadetime

		# module vars
		reverber.name = name_p
		reverber.stream = stream
		reverber.volume_db = volume_db
		reverber.max_polyphony = max_polyphony
		reverber.soundsource = soundsource

		# reverber vars
		reverber.raycast_index = raycast_index

		return reverber


	func do_set_stream(s: AudioStream):
		stream = s

		soundplayer_active.stream = s
		soundplayer_standby.stream = s

		if reverb_enabled:
			for r in reverbers:
				if r != null:
					r.soundplayer_active.stream = s
					r.soundplayer_standby.stream = s


	func do_play():
		if shut_up:
			return

		# when playing finishes, signals from all soundplayers are being emitted at the same time.
		# we just want to trigger ONE do_play() when looping is enabled.
		if _is_playing_starting:
			return

		_is_playing_starting = true
		call_deferred("_clear_play_lock")

		if reverb_enabled:
			for r in reverbers:
				r.do_play()

		# start play on both
		soundplayer_active.do_play()
		soundplayer_standby.do_play()


	func _clear_play_lock():
		_is_playing_starting = false


	func do_stop():
		if reverb_enabled:
			for r in reverbers:
				r.do_stop()

		soundplayer_active.do_stop()
		soundplayer_standby.do_stop()


	func update_run():
		distance_to_player = global_position.distance_to(player_camera.global_position)

		# only update delay when moved >5m since last update
		if abs(distance_to_player - distance_to_player_since_last_delay_update) > 5:
			delay_ms = calculate_delay(distance_to_player)
			distance_to_player_since_last_delay_update = distance_to_player

		# calculate my occlusion
		soundplayer_active.update_effect_params()

		if reverb_enabled:

			# update distances for all reverbers
			calculate_all_distances()

			# calculate room_size and wetness for reverbers
			calculate_reverb()


	func calculate_all_distances():
		var raycast_index = 0
		for reverber in reverbers:
			var rc := raycasts[raycast_index]
			var target_position: Vector3
			var colliding = false
			var dray: Debugray = rc.get_child(0)
			var dray_normal: Debugray = rc.get_child(1)

			# if raycast is colliding and the angle between raycast and normal is "over 2.5 radians" (3.14 == exact 180° reflection; 2.5 == somewhat 30° tolerance)
			rc.force_raycast_update()
			if rc.is_colliding() and (rc.get_collision_normal().angle_to(rc.target_position) > 2.5):
				# position reverber 10cm away from the collision/wall, otherwise occlusion detection doesn't work
				target_position = rc.get_collision_point() + rc.get_collision_normal() * 0.1
				colliding = true
				if debug: dray.draw(position, to_local(target_position), "#f00")
				if debug: dray_normal.draw(to_local(rc.get_collision_point() + rc.get_collision_normal() * 0.1), to_local(rc.get_collision_point() + rc.get_collision_normal()), "#0f0")

			else:
				target_position = rc.target_position * 100 # move the inactive point far far away
				if debug: dray.clear()
				if debug: dray_normal.clear()

			reverber.update_position(target_position, colliding)
			raycast_index += 1

		# measure room using measurement rays
		var ri = 0
		for mr in measurement_rays:
			mr.force_raycast_update()
			if mr.is_colliding():
				distances[ri] = global_position.distance_to(mr.get_collision_point())
				#if debug:
					#@warning_ignore("unsafe_method_access")
					#mr.get_child(0).draw(position, to_local(mr.target_position) + global_position, "#00f3")
			else:
				distances[ri] = -1
				#if debug:
					#@warning_ignore("unsafe_method_access")
					#mr.get_child(0).draw(position, to_local(mr.target_position) + global_position, "#ff01")
			ri += 1


	func calculate_reverb():
		# Find the reverb params
		var _room_size = 0.0
		var _wetness = 1.0

		var total_rays = distances.size()
		for distance in distances:
			if distance >= 0:
				# find the average room size based on the raycast distances that are valid
				_room_size += (distance / (max_raycast_distance / roomsize_multiplicator)) / float(total_rays)
				_room_size = snappedf(_room_size, 0.001)
				_room_size = min(_room_size, 1.0)
			else:
				# if a raycast did not hit anything we will reduce the reverb effect, almost no raycasts should hit when outdoors nowhere near buildings
				_wetness -= 1.0 / float(distances.size())
				_wetness = snappedf(_wetness, 0.001)
				_wetness = max(_wetness, 0.0)

		room_size = _room_size
		wetness = _wetness

		if debug:
			debugsphere.line2 = "Room size: %.3f" % room_size
			debugsphere.line3 = "Wetness: %.3f" % wetness


# Reverber:
# responsible for playing and positioning Soundplayers
class Reverber extends SpatialAudio3D:

	var raycast_index: int
	var distance_to_soundsource: float
	var distance_to_player: float
	var soundplayer_active: Soundplayer
	var soundplayer_standby: Soundplayer

	func _ready():
		name = name + "#" + str(raycast_index)

		# create reverb-soundplayers for AB-reverb
		soundplayer_active = create_soundplayer(name + "-A")
		soundplayer_standby = create_soundplayer(name + "-B")
		get_tree().get_root().add_child(soundplayer_active)
		get_tree().get_root().add_child(soundplayer_standby)


	func _exit_tree():
		soundplayer_active.queue_free()
		soundplayer_standby.queue_free()


	# don't inherit this from SpatialAudio3D
	func _physics_process(_delta):
		pass


	func do_play():
		soundplayer_active.do_play()
		soundplayer_standby.do_play()


	func do_stop():
		soundplayer_active.do_stop()
		soundplayer_standby.do_stop()


	func update_position(target_position: Vector3, colliding: bool):
		var _soundplayer_active := soundplayer_active
		var _soundplayer_standby := soundplayer_standby
		
		var fadeintime = 1 * soundsource.wetness if reverb_fadeintime < 0 else reverb_fadeintime
		var fadeouttime = 3 * soundsource.wetness if reverb_fadeouttime < 0 else reverb_fadeouttime

		# make sure inactive soundplayers stay silent
		soundplayer_standby.set_inactive()

		if global_position.distance_to(target_position) > 10:
			global_position = target_position

			soundplayer_active.set_inactive(fadeouttime)
			soundplayer_standby.target_position = target_position
			if colliding:
				soundplayer_standby.set_active(fadeintime)
				soundplayer_active = _soundplayer_standby
				soundplayer_standby = _soundplayer_active

		elif global_position.distance_to(target_position) > 0.3:
			global_position = target_position
			soundplayer_active.update_effect_params()
			soundplayer_active.target_position = target_position

		# update effects on colliding (active) soundplayers
		if colliding:
			soundplayer_active.update_effect_params()


# Soundplayer is the actual player that plays a sound.
# This is because the Soundsource as well as the reverbers need two players and fade between them,
# e.g. for letting the reverb hall playing out and not stopping abruptly, or for crossfading between different delays.
# responsible for setup and teardown audio bus, volume, effect parameters and occlusion detection.
class Soundplayer extends SpatialAudio3D:

	var ds = {0: "active", 1: "inactive", 2: "fading_to_active", 3: "fading_to_inactive"}
	enum ss {active, inactive, fading_to_active, fading_to_inactive}
	var with_reverb_fx: bool
	var state: ss:
		set(v):
			if state != v:
				state = v
				#if debug: debugsphere.line4 = ds[v]
				#if debug: print("%s: %s --> %s" % [name, ds[state], ds[v]])
	var distance_to_soundsource: float
	var distance_to_player: float
	var target_position: Vector3:
		set(v):
			if target_position != v:
				if state != ss.fading_to_inactive:
					target_position = v
					global_position = v
	var delay_ms: int:
		set(v):
			if abs(delay_ms - v) > 10 and (Time.get_ticks_msec() - delay_updated_at) > 1000:
				delay_ms = v
				delay_updated_at = Time.get_ticks_msec()
				if debug: debugsphere.line2 = "%s ms" % delay_ms
				if state != ss.fading_to_inactive:
					set_audioeffect(audiobus_name, fx.delay, {"delay": delay_ms})
	var delay_updated_at: int
	var room_size: float:
		set(v):
			if room_size != v:
				room_size = v
				if state != ss.fading_to_inactive:
					set_audioeffect(audiobus_name, fx.reverb, {"room_size": room_size, "wetness": wetness})
	var wetness: float:
		set(v):
			if wetness != v:
				wetness = v
				# audioeffect is already set together with room_size
	var proximity_volume: float:
		set(v):
			if abs(proximity_volume - v) > 0.1:
				proximity_volume = v
				if debug: debugsphere.line3 = "%d dB" % v
				if state == ss.active:
					set_audiobus_volume(audiobus_name, proximity_volume)
	var proximity_bass: float:
		set(v):
			if proximity_bass != v:
				proximity_bass = v
				if state != ss.fading_to_inactive:
					set_audioeffect(audiobus_name, fx.reverb_hipass, {"hipass": proximity_bass})
	var lp_cutoff: int:
		set(v):
			if abs(lp_cutoff - v) > 20:
				lp_cutoff = v
				if debug: debugsphere.line4 = "occluded" if v != 20500 else ""
				set_audioeffect(audiobus_name, fx.lowpass, {"lowpass": lp_cutoff, "fadetime": occlusion_fadetime})
	var occlusion_raycast: RayCast3D
	var audiobus_name: String


	func _ready():

		if debug:
			#print("spawning soundplayer: ", name)
			debugsphere = Debugsphere.new()
			debugsphere.max_raycast_distance = max_raycast_distance
			debugsphere.name = "Debugsphere " + name
			debugsphere.line1 = "♬"
			add_child(debugsphere)
			debugsphere.visible = false

		# ensure unique name for the mixer
		audiobus_name = "%s-%s" % [name, get_instance_id()]

		# create bus and add effects to it
		create_audiobus(audiobus_name)
		add_audioeffect(audiobus_name, fx.delay)
		add_audioeffect(audiobus_name, fx.reverb)
		if with_reverb_fx == false:
			toggle_audioeffect(audiobus_name, fx.reverb, false)
		add_audioeffect(audiobus_name, fx.lowpass)

		# set initial state to inactive and mute
		state = ss.inactive
		set_audiobus_volume(audiobus_name, -80)

		# set volume according to AudioStreamPlayer3D param
		proximity_volume = volume_db

		# set my bus to this newly created bus.
		bus = audiobus_name

		# create raycast for occlusion test
		occlusion_raycast = create_raycast("occray for " + name, position)
		add_child(occlusion_raycast)

		# connect signal (used to restart playing if loop is enabled)
		finished.connect(_on_finished)


	func _on_finished():
		if loop:
			soundsource.do_play()


	func _physics_process(_delta):
		if debug:
			dump_debug()
			debugsphere.update_label()


	func _exit_tree():
		for c in get_children():
			remove_child(c)
		remove_audiobus(audiobus_name)


	func do_play():
		#if debug: printerr(str(Time.get_ticks_msec()) + ": start playing on " + name + ", stream: " + str(stream))
		play()


	func do_stop():
		#if debug: printerr(str(Time.get_ticks_msec()) + ": stop playing on " + name + ", stream: " + str(stream))
		stop()


	func set_active(fadetime: float = 0, easing: Tween.EaseType = Tween.EASE_OUT, transition: Tween.TransitionType = Tween.TRANS_QUART):
		#if debug: print("SET ACTIVE: %s (state: %s, fadetime: %s)" % [name, ds[state], fadetime])
		if state == ss.inactive:
			if debug: debugsphere.visible = true
			update_effect_params()

			if fadetime > 0:
				state = ss.fading_to_active

				if fade_tween:
					fade_tween.kill()
				fade_tween = create_tween()
				fade_tween.stop()
				fade_tween.set_ease(easing)
				fade_tween.set_trans(transition)

				set_audiobus_volume(audiobus_name, proximity_volume, fadetime, fade_tween)
				await get_tree().create_timer(fadetime + 0.010).timeout

			else:
				set_audiobus_volume(audiobus_name, proximity_volume)

			state = ss.active


	func set_inactive(fadetime: float = 0, easing: Tween.EaseType = Tween.EASE_IN, transition: Tween.TransitionType = Tween.TRANS_QUINT):
		#if debug: print("SET INACTIVE: %s (state: %s, fadetime: %s)" % [name, ds[state], fadetime])
		if state == ss.active or state == ss.fading_to_active:

			if fadetime > 0:
				state = ss.fading_to_inactive

				if fade_tween:
					fade_tween.kill()
				fade_tween = create_tween()
				fade_tween.stop()
				fade_tween.set_ease(easing)
				fade_tween.set_trans(transition)

				set_audiobus_volume(audiobus_name, -80, fadetime, fade_tween)
				await get_tree().create_timer(fadetime + 0.010).timeout

			else:
				set_audiobus_volume(audiobus_name, -80)

			state = ss.inactive
			if debug: debugsphere.visible = false


	func update_effect_params():
		# update distance vars
		distance_to_soundsource = global_position.distance_to(soundsource.global_position)
		distance_to_player = global_position.distance_to(player_camera.global_position)

		# occlusion
		lp_cutoff = calculate_occlusion_lowpass()

		# only calculate reverb effects on reverbers, not soundsource soundplayers.
		# soundsource will set delay on soundsource-soundplayers.
		if with_reverb_fx:
			# calculate and set delay
			delay_ms = calculate_delay(distance_to_soundsource) + calculate_delay(distance_to_player)

			# roomsize & wetness
			room_size = soundsource.room_size
			wetness = soundsource.wetness

			# set volume. further away = louder.
			# (without tuning, in small rooms, reverb is overwhelming, but you can't hear echo far away)
			proximity_volume = calculate_proximity_volume()

			# set proximity bass
			# more bass if closer to the wall, effect begins at 50m to a wall
			# hipass = 0.2
			proximity_bass = calculate_proximity_bass()


	# turn down reverb volume by [reduction] dB when closer to the wall
	func calculate_proximity_volume():
		var proximity_reduction = 24
		var max_volume = reverb_volume_db + volume_db

		# calculate reduction based on the ratio player-to-max_raycast_distance and player-to-soundsource.
		# the closer you are to a wall, the less reverb should be heard. the further away you are, the more it should be audible.
		# the further away the soundsource is, the less reverb should be heard.
		var ratio_player_rc = min(1, distance_to_player / max_raycast_distance)
		var ratio_player_ss = min(1, distance_to_player / distance_to_soundsource)
		var prox_volume = (proximity_reduction * ratio_player_rc + proximity_reduction * ratio_player_ss) / 2 - proximity_reduction

		# add soundsource max_volume
		prox_volume = prox_volume + max_volume

		# limit maximum volume to max_volume
		prox_volume = min(prox_volume, max_volume)

		return prox_volume


	func calculate_proximity_bass():
		return snappedf(min(0.2 * distance_to_player / max(bass_proximity, 0.001), 0.2), 0.001)


	func calculate_occlusion_lowpass():
		var limited_distance_to_player = clamp(distance_to_player, 0, max_raycast_distance)
		occlusion_raycast.target_position = global_position.direction_to(player_camera.global_position) * max_raycast_distance * 10

		var _cutoff = 20500
		occlusion_raycast.force_raycast_update()
		if occlusion_raycast.is_colliding():
			var collision_point = occlusion_raycast.get_collision_point()
			var ray_distance = collision_point.distance_to(global_position)
			var wall_to_player_ratio = ray_distance / max(distance_to_player, 0.001)
			if ray_distance < distance_to_player:
				_cutoff = snappedf(occlusion_lp_cutoff * wall_to_player_ratio, 0.001)

		return _cutoff


class Debugsphere extends Node3D:

	var color: Color = "00f"
	var size: float = 0.5
	var max_raycast_distance: int
	var label = Label3D
	var line1: String
	var line2: String
	var line3: String
	var line4: String
	var label_offset: Vector3


	func _ready():
		var meshinstance = MeshInstance3D.new()
		var spheremesh = SphereMesh.new()
		var mat = StandardMaterial3D.new()
		mat.albedo_color = color
		#mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		#mat.fixed_size = true
		spheremesh.material = mat
		#meshinstance.cast_shadow = false
		spheremesh.radius = size / 2
		spheremesh.height = size
		meshinstance.mesh = spheremesh
		meshinstance.visibility_range_end = max_raycast_distance * 1.3
		meshinstance.visibility_range_end_margin = max_raycast_distance / 10.0
		meshinstance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(meshinstance)

		# create second sphere without depth-test, displayed when occluded
		var occluded_meshinstance = MeshInstance3D.new()
		var occluded_spheremesh = SphereMesh.new()
		var occluded_mat = StandardMaterial3D.new()
		occluded_mat.albedo_color = Color(color, 0.2)
		#occluded_mat.fixed_size = true
		occluded_mat.no_depth_test = true
		occluded_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		occluded_spheremesh.material = occluded_mat
		occluded_meshinstance.cast_shadow = false
		occluded_spheremesh.radius = size / 2
		occluded_spheremesh.height = size
		occluded_meshinstance.mesh = occluded_spheremesh
		occluded_meshinstance.visibility_range_end = max_raycast_distance * 1.3
		occluded_meshinstance.visibility_range_end_margin = max_raycast_distance / 10.0
		occluded_meshinstance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(occluded_meshinstance)

		# create label3d
		label = Label3D.new()
		label.position = label_offset
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.fixed_size = true
		label.no_depth_test = true
		label.pixel_size = 0.0005
		label.font_size = 50
		label.text = ""
		label.visibility_range_end = max_raycast_distance * 1.3
		label.visibility_range_end_margin = max_raycast_distance / 10.0
		label.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(label)


	func update_label():
		label.text = line1 + "\n" + line2 + "\n" + line3 + "\n" + line4


class Debugray extends MeshInstance3D:

	var immediate_mesh: ImmediateMesh
	var material: ORMMaterial3D


	func _ready():
		immediate_mesh = ImmediateMesh.new()
		material = ORMMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

		mesh = immediate_mesh
		cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


	func draw(pos1: Vector3, pos2: Vector3, color: Color):
		clear()
		immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
		immediate_mesh.surface_add_vertex(pos1)
		immediate_mesh.surface_add_vertex(pos2)
		immediate_mesh.surface_end()
		material.albedo_color = color
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA


	func clear():
		immediate_mesh.clear_surfaces()


func dump_debug():
	var _s = ""
	for key in _debug:
		_s += "%s: %s\n" % [key, JSON.stringify(_debug[key], "    ")]

	if _s != "":
		var ad = get_tree().get_root().find_child("AudioDebug")
		if ad:
			ad.text = _s


func print_r(obj):
	if obj is Object:
		obj = inst_to_dict(obj)
	print(JSON.stringify(obj, "    "))
