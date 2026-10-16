#!/usr/bin/env python3
"""Upload the approved Nuvio icon PNG from Fedora Downloads without cloning."""
import base64
import json
import subprocess
import sys
from pathlib import Path

REPO = "Cb541/plezynuvio"
BRANCH = "standalone-native-tvos-player"
DEST = "standalone_tvos/AppIconSource.png"
BASE = "repos/" + REPO + "/contents/" + DEST
folder = Path.home() / "Downloads"
# The user approved this specific image after removing the gray top-left panel.
# Require its filename instead of silently uploading an older mockup.
src = Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else folder / "neon_blue_glass_play_icon.png"
if not src.is_file():
    sys.exit(f"Approved icon not found: {src}. Download neon_blue_glass_play_icon.png to ~/Downloads or pass its path.")
if src.suffix.lower() != ".png":
    sys.exit("The app icon source must be a PNG.")
print("Uploading:", src)
check = subprocess.run(["gh", "api", BASE + "?ref=" + BRANCH],
                       capture_output=True, text=True)
if check.returncode == 0:
    existing_sha = json.loads(check.stdout)["sha"]
elif "404" in check.stderr or "Not Found" in check.stderr:
    existing_sha = None
else:
    sys.exit("Unable to read the repository: " + check.stderr)
payload = {
    "message": "Install approved black and neon-blue Nuvio Apple TV app icon",
    "branch": BRANCH,
    "content": base64.b64encode(src.read_bytes()).decode("ascii"),
}
if existing_sha:
    payload["sha"] = existing_sha
run = subprocess.run(["gh", "api", "-X", "PUT", BASE, "--input", "-"],
                     input=json.dumps(payload), capture_output=True, text=True)
if run.returncode != 0:
    sys.exit("GitHub upload failed: " + run.stderr)
result = json.loads(run.stdout)
print("Icon committed:", result["commit"]["sha"])
print("Actions: https://github.com/" + REPO + "/actions")
