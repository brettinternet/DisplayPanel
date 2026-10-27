#!/usr/bin/env bash
# Sourced by both packagers. Never fall back after a configured identity fails.

# Expected Developer ID team. A different team's certificate fails signing.
DISPLAYPANEL_SIGNING_TEAM_ID=4NQM9EVPZ3

displaypanel_signing_configure() {
	local required=${DISPLAYPANEL_REQUIRE_SIGNING:-0}
	DISPLAYPANEL_SIGNING_IDENTITY=${DISPLAYPANEL_SIGNING_IDENTITY:--}
	if [[ "$required" != 0 && "$required" != 1 ]]; then
		echo 'signing: DISPLAYPANEL_REQUIRE_SIGNING must be 0 or 1' >&2
		return 1
	fi
	if [[ "$DISPLAYPANEL_SIGNING_IDENTITY" == - ]]; then
		if [[ "$required" == 1 ]]; then
			echo 'signing: release requires DISPLAYPANEL_SIGNING_IDENTITY (certificate SHA-1)' >&2
			return 1
		fi
		echo 'WARNING: ad-hoc signing; privacy grants will not survive updates. Set DISPLAYPANEL_SIGNING_IDENTITY.' >&2
	elif [[ ! "$DISPLAYPANEL_SIGNING_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
		echo 'signing: DISPLAYPANEL_SIGNING_IDENTITY must be the 40-character certificate SHA-1, not a name' >&2
		return 1
	fi
}

# codesign's default designated requirement for a Developer ID Application
# certificate: Apple anchor plus Team ID, so it survives certificate renewal.
displaypanel_developer_id_requirement() {
	local identifier=$1
	echo "designated => identifier \"$identifier\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = \"$DISPLAYPANEL_SIGNING_TEAM_ID\""
}

displaypanel_check_requirement() {
	local code_path=$1
	local identifier=$2
	local requirement
	requirement=$(codesign -d -r- "$code_path" 2>/dev/null) || return 1
	if [[ "$requirement" != "$(displaypanel_developer_id_requirement "$identifier")" ]]; then
		echo "signing: $code_path is not Developer ID signed as $identifier for team $DISPLAYPANEL_SIGNING_TEAM_ID: $requirement" >&2
		return 1
	fi
}

displaypanel_sign() {
	local code_path=$1
	local identifier=$2
	local args=(--force --sign "$DISPLAYPANEL_SIGNING_IDENTITY" --identifier "$identifier")
	if [[ "$DISPLAYPANEL_SIGNING_IDENTITY" != - ]]; then
		# The SHA-1 only selects the identity; the requirement is codesign's default.
		args+=(--options runtime --timestamp)
		if [[ -n "${DISPLAYPANEL_SIGNING_KEYCHAIN:-}" ]]; then
			args+=(--keychain "$DISPLAYPANEL_SIGNING_KEYCHAIN")
		fi
	fi
	codesign "${args[@]}" "$code_path"
	if [[ "$DISPLAYPANEL_SIGNING_IDENTITY" != - ]]; then
		displaypanel_check_requirement "$code_path" "$identifier"
	fi
}
