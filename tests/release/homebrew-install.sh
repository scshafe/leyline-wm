#!/usr/bin/env bash
# Verify a real Homebrew source install from prepared assets, without starting a
# resident. Creates a local CI-only tap and an unlinked Cellar package; native
# installation writes only temporary configuration/LaunchAgent paths.
# Usage: homebrew-install.sh ARTIFACT_DIRECTORY
set -euo pipefail
[[ $# -eq 1 ]] || exit 64
artifact_directory="$(cd "$1" && pwd -P)"
tap_name=leyline-verification/local
brew tap-new "$tap_name"
tap_directory="$(brew --repository "$tap_name")"
python3 - "$artifact_directory" "$tap_directory" <<'PY'
from pathlib import Path
import re,sys
artifacts,tap=map(Path,sys.argv[1:])
recipes=list(artifacts.glob('leyline.rb*'));archives=list(artifacts.glob('leyline-*-source.tar.gz'))
assert len(recipes)==len(archives)==1
recipe=recipes[0].read_text()
recipe,count=re.subn(r'^  url "[^"]+"$',f'  url "{archives[0].resolve().as_uri()}"',recipe,flags=re.M)
assert count==1
(tap/'Formula/leyline.rb').write_text(recipe)
PY
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_ASK=1
brew install --build-from-source --skip-link --skip-post-install "$tap_name/leyline"
brew test --force "$tap_name/leyline"
package_prefix="$(brew --prefix "$tap_name/leyline")"
"$package_prefix/bin/ley" --version
for bundle in 'Leyline.app' 'Leyline Recovery.app'; do
  /usr/bin/codesign --verify --strict --deep "$package_prefix/libexec/$bundle"
done
installation_fixture="$(mktemp -d -t leyline-brew-install)"
trap 'rm -rf "$installation_fixture"' EXIT
/usr/bin/ditto "$package_prefix/libexec/Leyline.app" "$installation_fixture/Leyline.app"
native_executable="$installation_fixture/Leyline.app/Contents/MacOS/leylined"
/usr/bin/env -u LEYLINE_HOME "$native_executable" install --no-start \
  --root "$installation_fixture/resident" --launch-agents "$installation_fixture/LaunchAgents" \
  > "$installation_fixture/receipt.json"
python3 - "$installation_fixture" <<'PY'
from pathlib import Path
import json,sys
fixture=Path(sys.argv[1]);receipt=json.loads((fixture/'receipt.json').read_text())
assert receipt['error'] is None and receipt['data']['registered'] is False
assert receipt['data']['applied'] is True
print(json.dumps({'homebrew_source_install':True,'native_no_start_install':True,'live_service_mutations':0}))
PY
