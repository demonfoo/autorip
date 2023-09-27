#!/usr/bin/env bash

# If we're on a platform that MakeMKV supports, see if it's installed.
# shellcheck disable=SC2034
declare -A MAKEMKV_DEVMAP=()
can_makemkv() {
    MAKEMKV=''
    case "${BASH_VERSINFO[5]}" in
      *-linux-gnu)
        #echo "You're running Linux, let's see if you have MakeMKV..."
        MAKEMKV="$(command -v makemkvcon)"
        ;;
      *-apple-darwin*)
        #echo "You're running MacOS, let's see if you have MakeMKV..."
        if [ -d '/Applications/MakeMKV.app' ] ; then
            MAKEMKV='/Applications/MakeMKV.app/Contents/MacOS/makemkvcon'
        fi
        ;;
    #  *)
    #    echo "Sorry, no MakeMKV for you."
    #    ;;
    esac

    if [ -n "${MAKEMKV}" ] && [ -x "${MAKEMKV}" ] ; then
        #echo "Found MakeMKV at '${MAKEMKV}'"
        # we can't use the block device for ripping with makemkvcon later,
        # so let's query now and generate a map of disc devices that we can
        # reuse later on.
        declare -gA MAKEMKV_DEVMAP
        eval "$(echo 'MAKEMKV_DEVMAP=(' ; "${MAKEMKV}" --robot --cache=1 info disc:9999 | \
                awk '/^DRV:/ { n = $0; sub(/^DRV:/, "", n); sub(/,.*$/, "", n);
                     d = $0; sub(/"$/, "", d); sub(/^.*"/, "", d);
                     if (d != "") print "['\''" d "'\'']='\''" n "'\''"; }' ; echo ')')"
    fi
}

makemkv_get_titleinfo() {
    local DUMP_PATH="${1}"

    if [ -z "${MAKEMKV}" ] ; then
        return 1
    fi

    local BASEPATH
    BASEPATH="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
    # call the perl script that does the real work here
    "${MAKEMKV}" info --robot --noscan "file:${DUMP_PATH}" | \
            perl "${BASEPATH}/makemkv-get-titleinfo.pl" "${!ISO639_1[@]}" "${ISO639_1[@]}"
}

# this will extract a single title (by playlist name) as a .mkv file into
# the given directory, and makemkv will tell us what that file name will
# be (that's just how it do).
makemkv_extract_title() {
    local DUMP_PATH="${1}"
    # shellcheck disable=SC2034
    local TARGET_PATH="${2}"
    # shellcheck disable=SC2034
    local PLAYLIST="${3}"

    if [ -z "${MAKEMKV}" ] ; then
        return 1
    fi

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
                  select((.length | tonumber) > ($minlen | tonumber))]'
    return "${PIPESTATUS[0]}"
}

if [ "${0}" = "${BASH_SOURCE[0]}" ] ; then
    echo "This script is not an executable, it doesn't do anything."
fi
