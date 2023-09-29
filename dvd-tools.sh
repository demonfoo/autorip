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

# Get title info with 'lsdvd'.
my_lsdvd_gettitles() {
    local MOUNTPOINT="${1}"

    # shellcheck disable=SC2016 # not supposed to expand
    lsdvd -Ox -c -v -a "${MOUNTPOINT}" 2> /dev/null | tail -n +2 | \
            sed -e 's/&/&amp;/g' -e 's/\xff\xff/  /g' | \
            xq --arg minlen "${MIN_TITLE_LEN}" '[.lsdvd.track[] |
                  # make sure the chapter property is always an array
                  .chapter |= if (. | type) == "object" then [.] else . end |
                  # same for audio
                  .audio? |= if (. | type) == "object" then [.] else . end |
                  # remove titles less than minimum length
                  select((.length | tonumber) > ($minlen | tonumber))]' 2> /dev/null
    return "${PIPESTATUS[0]}"
}

if [ "${0}" = "${BASH_SOURCE[0]}" ] ; then
    echo "This script is not an executable, it doesn't do anything."
fi
