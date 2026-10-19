---
id: TASK-85
title: Share blackout UUID list validation
status: Done
assignee: []
created_date: '2026-10-19 10:29'
updated_date: '2026-10-19 10:31'
labels: []
dependencies: []
type: chore
ordinal: 72010
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
BlackoutOptions validates hidden-display and sibling-display UUID lists with duplicated normalization, UUID parsing, and uniqueness checks. Keeping these rules in sync avoids subtle validation drift as internal blackout options evolve.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Both lists use one shared UUID normalization and uniqueness check.
- [x] #2 Existing list-specific constraints and CLI rejection behavior remain unchanged.
- [x] #3 Focused blackout CLI parser tests pass.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extract a shared helper that normalizes UUIDs and rejects invalid or duplicate values. 2. Keep the watcher, selection, and cross-list disjointness checks in their existing property-specific validation. 3. Run the focused CLI parser tests and review the diff.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Extracted normalizedUniqueUUIDKeys for shared case normalization, UUID parsing, and duplicate rejection. Hidden/selected exclusion, watcher ownership, and sibling/hidden disjointness remain property-specific. Verification: swift test --disable-sandbox --filter CLIParserTests passed (26 tests); git diff --check passed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Shared blackout hidden/sibling UUID list normalization and validation without changing their distinct safety rules. Existing CLI parser regressions pass (26 tests), and git diff --check is clean.
<!-- SECTION:FINAL_SUMMARY:END -->
