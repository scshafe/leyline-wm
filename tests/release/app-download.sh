#!/usr/bin/env bash
# Download an explicitly selected release, verify its universal app archive and
# test native no-start installation in temporary paths. Starts no resident.
# Requires gh authentication via GH_TOKEN and GH_REPO. Usage: app-download.sh TAG
set -euo pipefail
[[ $# -eq 1 && "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 64
app_version="${1#v}"
app_fixture="$(mktemp -d -t leyline-download-check)"
trap 'rm -rf "$app_fixture"' EXIT
gh release download "$1" --pattern "leyline-$app_version-macos-universal.zip" --pattern SHA256SUMS --dir "$app_fixture"
python3 - "$app_fixture" "$app_version" <<'PY'
from pathlib import Path
import hashlib,sys,zipfile
root=Path(sys.argv[1]);name=f'leyline-{sys.argv[2]}-macos-universal.zip'
rows=[row.split('  ',1) for row in (root/'SHA256SUMS').read_text().splitlines()]
expected=[value for value,filename in rows if filename==name];assert len(expected)==1
assert hashlib.sha256((root/name).read_bytes()).hexdigest()==expected[0]
with zipfile.ZipFile(root/name) as archive:
    assert all(not e.filename.startswith('/') and '..' not in Path(e.filename).parts for e in archive.infolist())
PY
/usr/bin/ditto -x -k "$app_fixture/leyline-$app_version-macos-universal.zip" "$app_fixture"
app_home="$app_fixture/leyline-$app_version"
for bundle in 'Leyline.app' 'Leyline Recovery.app'; do
  /usr/bin/codesign --verify --strict --deep "$app_home/$bundle"
done
native_executable="$app_home/Leyline.app/Contents/MacOS/leylined"
[[ "$("$native_executable" version)" == "leylined $app_version" ]]
"$app_home/Leyline Recovery.app/Contents/MacOS/leyline-recovery" --bounce --plan
/usr/bin/env -u LEYLINE_HOME "$native_executable" install --no-start \
  --root "$app_fixture/resident" --launch-agents "$app_fixture/LaunchAgents" > "$app_fixture/receipt.json"
python3 - "$app_fixture/receipt.json" <<'PY'
from pathlib import Path
import json,sys
receipt=json.loads(Path(sys.argv[1]).read_text());assert receipt['error'] is None
assert receipt['data']['applied'] and not receipt['data']['registered']
print(json.dumps({'downloaded_app_verified':True,'native_no_start_install':True,'live_service_mutations':0}))
PY
