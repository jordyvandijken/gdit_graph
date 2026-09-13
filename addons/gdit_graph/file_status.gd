# Shared file-status presentation used by both panels.
#
# The side panel file rows, the commit-details file list, and the comparison
# view all paint the same status-letter colors. This file owns that mapping
# so the call sites cannot drift apart. Panel-specific variants stay local:
# the side panel "?" -> "U" display letter and the workpanel status words.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/file_status.gd").
extends RefCounted


static func status_color(code: String) -> Color:
	match code:
		"M":
			return Color(0.9, 0.7, 0.1)
		"A":
			return Color(0.2, 0.8, 0.2)
		"U", "?":
			return Color(0.55, 0.6, 0.55)
		"D":
			return Color(0.9, 0.2, 0.2)
		"R", "C":
			return Color(0.2, 0.5, 0.9)
	return Color.WHITE
