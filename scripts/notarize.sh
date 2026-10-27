#!/usr/bin/env bash
# shellcheck disable=SC2034 # Sets DISPLAYPANEL_NOTARIZE for the scripts that source it.
# Sourced by package-release.sh and the CI credential check. Source signing.sh
# and run displaypanel_signing_configure first.

displaypanel_notary_configure() {
	local required=${DISPLAYPANEL_REQUIRE_NOTARIZATION:-0}
	local key=${DISPLAYPANEL_NOTARY_KEY_PATH:-}
	local key_id=${DISPLAYPANEL_NOTARY_KEY_ID:-}
	local issuer=${DISPLAYPANEL_NOTARY_ISSUER_ID:-}
	DISPLAYPANEL_NOTARIZE=0
	if [[ "$required" != 0 && "$required" != 1 ]]; then
		echo 'notarize: DISPLAYPANEL_REQUIRE_NOTARIZATION must be 0 or 1' >&2
		return 1
	fi
	if [[ -z "$key$key_id$issuer" ]]; then
		if [[ "$required" == 1 ]]; then
			echo 'notarize: release requires DISPLAYPANEL_NOTARY_KEY_PATH, DISPLAYPANEL_NOTARY_KEY_ID and DISPLAYPANEL_NOTARY_ISSUER_ID' >&2
			return 1
		fi
		echo 'NOTE: notarization skipped; set DISPLAYPANEL_NOTARY_KEY_PATH, DISPLAYPANEL_NOTARY_KEY_ID and DISPLAYPANEL_NOTARY_ISSUER_ID.' >&2
		return 0
	fi
	if [[ -z "$key" || -z "$key_id" || -z "$issuer" ]]; then
		echo 'notarize: set all of DISPLAYPANEL_NOTARY_KEY_PATH, DISPLAYPANEL_NOTARY_KEY_ID and DISPLAYPANEL_NOTARY_ISSUER_ID' >&2
		return 1
	fi
	if [[ ! -f "$key" ]]; then
		echo "notarize: API key not found: $key" >&2
		return 1
	fi
	if [[ "${DISPLAYPANEL_SIGNING_IDENTITY:--}" == - ]]; then
		echo 'notarize: notarization requires Developer ID signing' >&2
		return 1
	fi
	DISPLAYPANEL_NOTARIZE=1
	DISPLAYPANEL_NOTARY_ARGS=(--key "$key" --key-id "$key_id" --issuer "$issuer")
}

# Validates credentials without submitting anything.
displaypanel_notary_check() {
	xcrun notarytool history "${DISPLAYPANEL_NOTARY_ARGS[@]}" --output-format json >/dev/null
	echo 'Notary credentials are valid'
}

# Submits and waits. Anything but Accepted prints the notary log and fails.
displaypanel_notarize() {
	local archive=$1
	local result status id
	echo "Notarizing $(basename "$archive")"
	result=$(xcrun notarytool submit "$archive" "${DISPLAYPANEL_NOTARY_ARGS[@]}" \
		--wait --output-format json) || true
	status=$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null) || status=
	id=$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null) || id=
	if [[ "$status" == Accepted ]]; then
		echo "Notarization accepted: $id"
		return 0
	fi
	echo "notarize: $(basename "$archive") was not accepted (status: ${status:-unknown})" >&2
	printf '%s\n' "$result" >&2
	if [[ -n "$id" ]]; then
		xcrun notarytool log "$id" "${DISPLAYPANEL_NOTARY_ARGS[@]}" >&2 || true
	fi
	return 1
}

displaypanel_verify_notarized_app() {
	local app=$1
	local assessment
	xcrun stapler validate "$app"
	codesign --verify --deep --strict "$app"
	assessment=$(spctl -a -vv -t exec "$app" 2>&1) || {
		printf '%s\n' "$assessment" >&2
		return 1
	}
	printf '%s\n' "$assessment"
	if [[ "$assessment" != *"source=Notarized Developer ID"* ]]; then
		echo "notarize: Gatekeeper does not report $app as notarized" >&2
		return 1
	fi
}
