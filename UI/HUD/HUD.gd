# GameUI.gd
extends CanvasLayer

# CONFIGURATION
const HEALTH_ANIMATION_SPEED = 0.5  # Seconds for health bar to animate
const GHOST_HEALTH_DELAY = 0.4      # Seconds before the "damage taken" bar starts moving
const AMMO_POP_SPEED = 0.1          # Seconds for the ammo text to "pop"
const PROMPT_FADE_SPEED = 0.3       # Seconds for prompts to fade in/out

# NODE REFERENCES
@onready var health_bar: ProgressBar = %HealthBar
@onready var ghost_health_bar: ProgressBar = %GhostHealthBar # The "damage taken" bar
@onready var weapon_name_label: Label = %WeaponNameLabel
@onready var mag_ammo_label: Label = %MagAmmoLabel
@onready var reserve_ammo_label: Label = %ReserveAmmoLabel
@onready var prompt_panel: PanelContainer = %PromptPanel

@onready var crosshair: CrosshairDrawer = $CrosshairDrawer

# STATE VARIABLES
var current_weapon_name: String = ""
var current_mag_ammo: int = -1


func _ready():
	add_to_group("game-ui") # Can be accessed globally
	# Hide prompt initially, but with modulate so it can be faded in.
	prompt_panel.modulate.a = 0.0
	prompt_panel.hide()


# UI SETTER FUNCTIONS

## Updates the player's health bar with smooth animations.
func update_health(current_health: float, max_health: float, animate: bool = true):
	health_bar.max_value = max_health
	ghost_health_bar.max_value = max_health

	# Animate the main health bar
	if animate:
		var tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tween.tween_property(health_bar, "value", current_health, HEALTH_ANIMATION_SPEED)
	else:
		health_bar.value = current_health

	# Animate the "ghost" bar (damage taken indicator) after a delay
	if animate:
		var tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tween.set_parallel(false) # Run tweens sequentially
		tween.tween_interval(GHOST_HEALTH_DELAY)
		tween.tween_property(ghost_health_bar, "value", current_health, HEALTH_ANIMATION_SPEED * 1.5)
	else:
		ghost_health_bar.value = current_health


## Updates the weapon and ammo display with a "pop" animation.
func update_weapon(weapon_name: String, mag_ammo: int, reserve_ammo: int, animate: bool = true):
	# Only update weapon name if it has changed to prevent unnecessary animation
	if weapon_name != current_weapon_name:
		weapon_name_label.text = weapon_name.to_upper()
		current_weapon_name = weapon_name

	reserve_ammo_label.text = "/ " + str(reserve_ammo)
	
	# Animate the magazine count if it has changed
	if mag_ammo != current_mag_ammo:
		mag_ammo_label.text = str(mag_ammo)
		current_mag_ammo = mag_ammo
		
		if animate:
			var tween = create_tween().set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
			mag_ammo_label.pivot_offset = mag_ammo_label.size / 2
			tween.tween_property(mag_ammo_label, "scale", Vector2(1.4, 1.4), AMMO_POP_SPEED)
			tween.tween_property(mag_ammo_label, "scale", Vector2.ONE, AMMO_POP_SPEED * 1.5)


## Pinta el contador de balas en rojo cuando queda poca munición.
func set_low_ammo(low: bool) -> void:
	mag_ammo_label.add_theme_color_override("font_color",
		Color(1.0, 0.25, 0.2) if low else Color.WHITE)

## Displays an in-game prompt with a fade-in animation.
var prompt_tween: Tween

func show_prompt(text: String):
	crosshair.visible = false
	%PromptLabel.text = text
	prompt_panel.show()

	# Kill old tween if exists
	if prompt_tween and prompt_tween.is_valid():
		prompt_tween.kill()

	# Start new tween
	prompt_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	prompt_tween.tween_property(prompt_panel, "modulate:a", 1.0, PROMPT_FADE_SPEED)


func hide_prompt():
	crosshair.visible = true

	# Kill old tween if exists
	if prompt_tween and prompt_tween.is_valid():
		prompt_tween.kill()

	# Start new tween
	prompt_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	prompt_tween.tween_property(prompt_panel, "modulate:a", 0.0, PROMPT_FADE_SPEED)

	# Hide when finished
	prompt_tween.finished.connect(func ():
		if prompt_panel.modulate.a == 0.0:
			prompt_panel.hide()
	)
