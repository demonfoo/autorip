#!/usr/bin/env bash


# this will extract a single title as a series of VOB files under a VIDEO_TS
# subdirectory.
dvdbackup_extract_title() {
    local DUMP_PATH="${1}"
    local TARGET_PATH="${2}"
    local TITLENUM="${3}"

    "${CMDPREFIX[@]}" dvdbackup --input="${DUMP_PATH}" --title="${TITLENUM}" \
            --output="${TARGET_PATH}" --name='.' >& /dev/null
}

if [ "${0}" = "${BASH_SOURCE[0]}" ] ; then
    echo "This script is not an executable, it doesn't do anything."
fi
