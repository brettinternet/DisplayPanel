#!/usr/bin/env bash
set -euo pipefail
set -o noclobber

usage() {
	cat >&2 <<'EOF'
Usage: scripts/package-release.sh TAG [OUTPUT_DIR]

Builds arm64 and x86_64 release products, then creates universal CLI and
DisplayPanel.app archives with SHA-256 checksums.
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
	usage
	exit 2
fi

tag=$1
output_dir=${2:-dist}
# shellcheck source=signing.sh
source "$(dirname "${BASH_SOURCE[0]}")/signing.sh"
displaypanel_signing_configure
# shellcheck source=release-version.sh
source "$(dirname "${BASH_SOURCE[0]}")/release-version.sh"
if ! release_version_parse "$tag"; then
	echo "package-release.sh: tag must be a semantic version such as v1.2.3 or v1.2.3-beta.1: $tag" >&2
	exit 1
fi
marketing_version=$RELEASE_MARKETING_VERSION

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_version=$(
	sed -n 's/.*public static let version = "dp \([^"]*\)".*/\1/p' \
		"$repo_root/Sources/DisplayPanelCore/CLIHelp.swift"
)
if [[ "$source_version" != "$marketing_version" ]]; then
	echo "package-release.sh: tag $tag does not match dp $source_version" >&2
	exit 1
fi
output_dir=$(mkdir -p "$output_dir" && cd "$output_dir" && pwd)
cli_archive="dp-cli-${tag}-macos-universal.zip"
app_archive="DisplayPanel-${tag}-macos-universal.zip"
for output in "$output_dir/$cli_archive" "$output_dir/$cli_archive.sha256" \
	"$output_dir/$app_archive" "$output_dir/$app_archive.sha256"; do
	if [[ -e "$output" ]]; then
		echo "package-release.sh: refusing to overwrite existing output: $output" >&2
		exit 1
	fi
done

arm64_scratch="$repo_root/.build/package-release-arm64"
x86_64_scratch="$repo_root/.build/package-release-x86_64"

# SwiftPM can link through clang without -isysroot. clang then records the
# deployment target as the SDK version, and macOS gives the app macOS 13
# behaviour, such as Settings rows that cut off their text.
sdk_path=$(xcrun --show-sdk-path)

build_product() {
	local product=$1
	local triple=$2
	local scratch=$3
	swift build --disable-sandbox --configuration release --product "$product" \
		--triple "$triple" --scratch-path "$scratch" \
		-Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$sdk_path"
}

build_product DisplayPanelApp arm64-apple-macosx13.0 "$arm64_scratch"
build_product dp arm64-apple-macosx13.0 "$arm64_scratch"
build_product DisplayPanelApp x86_64-apple-macosx13.0 "$x86_64_scratch"
build_product dp x86_64-apple-macosx13.0 "$x86_64_scratch"

# Where SwiftPM writes products depends on its build system, so ask it.
bin_path() {
	local triple=$1
	local scratch=$2
	swift build --disable-sandbox --configuration release \
		--triple "$triple" --scratch-path "$scratch" --show-bin-path
}

arm64_bin=$(bin_path arm64-apple-macosx13.0 "$arm64_scratch")
x86_64_bin=$(bin_path x86_64-apple-macosx13.0 "$x86_64_scratch")
arm64_ui="$arm64_bin/DisplayPanelApp"
x86_64_ui="$x86_64_bin/DisplayPanelApp"
arm64_cli="$arm64_bin/dp"
x86_64_cli="$x86_64_bin/dp"
for binary in "$arm64_ui" "$x86_64_ui" "$arm64_cli" "$x86_64_cli"; do
	if [[ ! -f "$binary" || ! -x "$binary" ]]; then
		echo "package-release.sh: release executable not found: $binary" >&2
		exit 1
	fi
done

universal_staging=$(mktemp -d "${TMPDIR:-/tmp}/displaypanel-release.XXXXXX")
: > "$universal_staging/.displaypanel-release-owned"
cleanup() {
	local cleanup_root cleanup_staging
	cleanup_root=$(cd "${TMPDIR:-/tmp}" && pwd -P) || return
	cleanup_staging=$(cd "$universal_staging" && pwd -P) || return
	if [[ -x /usr/bin/trash && "$cleanup_staging" == "$cleanup_root"/displaypanel-release.* &&
		-f "$cleanup_staging/.displaypanel-release-owned" ]]; then
		/usr/bin/trash "$cleanup_staging" || true
	fi
}
trap cleanup EXIT

lipo -create "$arm64_cli" "$x86_64_cli" -output "$universal_staging/dp"
chmod 0755 "$universal_staging/dp"
displaypanel_sign "$universal_staging/dp" "com.brettinternet.displaypanel.cli"
codesign --verify --strict "$universal_staging/dp"
lipo -info "$universal_staging/dp"

zip -q -j "$output_dir/$cli_archive" \
	"$universal_staging/dp" "$repo_root/README.md"
(
	cd "$repo_root"
	zip -q "$output_dir/$cli_archive" examples/com.brettinternet.displaypanel.blackout.plist
)
(
	cd "$output_dir"
	shasum -a 256 "$cli_archive" > "$cli_archive.sha256"
)

"$repo_root/scripts/package-app.sh" "$tag" "$arm64_ui" "$x86_64_ui" "$arm64_cli" "$x86_64_cli" \
	"$universal_staging/DisplayPanel.app"
app_archive_staging="$universal_staging/archive"
mkdir "$app_archive_staging"
ditto "$universal_staging/DisplayPanel.app" "$app_archive_staging/DisplayPanel.app"
cp "$repo_root/README.md" "$app_archive_staging/"
ditto -c -k --sequesterRsrc "$app_archive_staging" "$output_dir/$app_archive"
(
	cd "$output_dir"
	shasum -a 256 "$app_archive" > "$app_archive.sha256"
)

echo "Created $output_dir/$cli_archive"
echo "Created $output_dir/$app_archive"
