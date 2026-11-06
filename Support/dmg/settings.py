# dmgbuild settings for Downstream's installer window.
# Used by scripts/release.sh:  dmgbuild -s Support/dmg/settings.py -D app=build/Downstream.app "Downstream 1.2.0" out.dmg
# The background (scripts/make-dmg-background.swift) is drawn for these icon positions.
import os.path

application = defines.get("app", "build/Downstream.app")  # noqa: F821 (dmgbuild provides `defines`)
appname = os.path.basename(application)
# dmgbuild runs this file without __file__; paths are relative to the repository root (where release.sh runs).
root = defines.get("root", ".")  # noqa: F821
here = os.path.join(root, "Support", "dmg")

format = "UDZO"
filesystem = "HFS+"
compression_level = 9

files = [application]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(os.path.dirname(here), "AppIcon.icns")  # the mounted volume's icon

background = os.path.join(here, "background.tiff")
window_rect = ((200, 140), (660, 430))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 120
hide_extensions = [appname]
text_size = 13
arrange_by = None
icon_locations = {
    appname: (170, 205),
    "Applications": (490, 205),
}
