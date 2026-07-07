# AimPose.gd
# SkeletonModifier3D que levanta el brazo derecho a una pose de "apuntar con
# arma" DESPUÉS de la animación (idle/walk/run tienen el brazo caído). Así el
# personaje sostiene la pistola al frente en vez de apuntar al piso, y hace
# un retroceso visible al disparar. Corre en todos los peers (bots incluidos).
extends SkeletonModifier3D
class_name AimPose

var shoulder_idx := -1
var arm_idx := -1
var forearm_idx := -1
var spine_idx := -1

# Rotaciones locales aditivas (ajustadas para el rig del mascot): brazo
# levantado y apuntando al FRENTE, codo semi-extendido (pose de disparo).
var _arm_rot := Quaternion.from_euler(Vector3(deg_to_rad(-88), 0, deg_to_rad(-6)))
var _forearm_rot := Quaternion.from_euler(Vector3(deg_to_rad(-8), deg_to_rad(-8), 0))
var _shoulder_rot := Quaternion.from_euler(Vector3(deg_to_rad(-14), 0, 0))
var _spine_rot := Quaternion.from_euler(Vector3(deg_to_rad(8), 0, 0))

var recoil := 0.0 # 0..1, lo sube quien dispara; decae solo

func setup(skel: Skeleton3D) -> void:
	shoulder_idx = skel.find_bone("RightShoulder")
	arm_idx = skel.find_bone("RightArm")
	forearm_idx = skel.find_bone("RightForeArm")
	spine_idx = skel.find_bone("Spine02")

func _process(delta: float) -> void:
	if recoil > 0.0:
		recoil = maxf(0.0, recoil - delta * 6.0)

func kick() -> void:
	recoil = 1.0

func _process_modification() -> void:
	var skel := get_skeleton()
	if skel == null:
		return
	var recoil_rot := Quaternion.from_euler(Vector3(deg_to_rad(18.0 * recoil), 0, 0))
	if spine_idx >= 0:
		skel.set_bone_pose_rotation(spine_idx, skel.get_bone_pose_rotation(spine_idx) * _spine_rot)
	if shoulder_idx >= 0:
		skel.set_bone_pose_rotation(shoulder_idx, skel.get_bone_pose_rotation(shoulder_idx) * _shoulder_rot)
	if arm_idx >= 0:
		skel.set_bone_pose_rotation(arm_idx, skel.get_bone_pose_rotation(arm_idx) * _arm_rot * recoil_rot)
	if forearm_idx >= 0:
		skel.set_bone_pose_rotation(forearm_idx, skel.get_bone_pose_rotation(forearm_idx) * _forearm_rot)
