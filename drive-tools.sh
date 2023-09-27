#!/usr/bin/env bash

# Find the optical drives on the system we're running on.
discover_drives() {
    # figure out what the devices are, and the raw devices for OSes that
    # care about such stuff...
    declare -g -a CDDEVS=()
    declare -g -A VENDOR=() MODEL=() REV=() RAWDEVS=() MOUNTDEVS=()
    local dev index
    case "${BASH_VERSINFO[5]}" in
      *-linux-gnu)
        readarray -t CDDEVS <<<"$(find /sys/class/block -mindepth 1 -maxdepth 1 -name 'sr*')"
        if [ -z "${CDDEVS[0]:-}" ] ; then
            unset 'CDDEVS[0]'
        fi
        # strip leading path
        CDDEVS=("${CDDEVS[@]##*/}")
        for dev in "${CDDEVS[@]}" ; do
            # shellcheck disable=SC2034
            VENDOR["${dev}"]="$(cat "/sys/class/block/${dev}/device/vendor")"
            # shellcheck disable=SC2034
            MODEL["${dev}"]="$(cat "/sys/class/block/${dev}/device/model")"
            # shellcheck disable=SC2034
            REV["${dev}"]="$(cat "/sys/class/block/${dev}/device/rev")"
            # shellcheck disable=SC2034
            RAWDEVS["${dev}"]="/dev/${dev}"
            # shellcheck disable=SC2034
            MOUNTDEVS["${dev}"]="/dev/${dev}"
        done
        ;;
      *-apple-darwin*)
        echo "FATAL: Not sure how to do this on MacOS yet..." 1>&2
        exit 1
        ;;
      *-freebsd*|*-dragonfly*)
        while read -r LINE ; do
            case "${dev}" in
              cd*|acd*)
                CDDEVS+=("${dev}")
                eval "$("${CMDPREFIX[@]}" camcontrol inquiry "${LINE}" | sed -n 's/^.*<\([^[:space:]]*\)[[:space:]]*\(.*\)[[:space:]]*[[:space:]]\([^[:space:]]*\)>.*$/VENDOR["'"${LINE}"'"]="\1"\
MODEL["'"${LINE}"'"]="\2"\
REV["'"${LINE}"'"]="\3"')"
                RAWDEVS["${LINE}"]="/dev/${dev}"
                MOUNTDEVS["${LINE}"]="/dev/${dev}"
                ;;
              # no default case here, it's fine
            esac
        done <<<"$("${CMDPREFIX[@]}" camcontrol devlist | awk '{ if $NF ~ /cd[0-9]+/) { sub(/^\(/, "", $NF); gsub(/,/, "\n", $NF); print $NF; print " "; } }')"
        ;;
      *-netbsd)
        for dev in $("${CMDPREFIX[@]}" sysctl hw.disknames | sed 's/^.*=[[:space:]]*//') ; do
            case "${dev}" in
              cd*)
                CDDEVS+=("${dev}")
                eval "$("${CMDPREFIX[@]}" scsictl "/dev/${dev}" identify | sed -n 's/^.*<\([^,]*\), \([^,]*\), \([^>]*\)>.*$/VENDOR["'"${dev}"'"]="\1"\
MODEL["'"${dev}"'"]="\2"\
REV["'"${dev}"'"]="\3"/p')"
                RAWDEVS["${dev}"]="/dev/r${dev}d"
                MOUNTDEVS["${dev}"]="/dev/${dev}d"
                ;;
              # no default case here, it's fine
            esac
        done
        ;;
      *-openbsd*)
        for dev in $("${CMDPREFIX[@]}" sysctl hw.disknames | sed 's/^.*=[[:space:]]*//') ; do
            case "${dev}" in
              cd*:*)
                CDDEVS+=("${dev%:*}")
                eval "$("${CMDPREFIX[@]}" smartctl -d scsi -T permissive --all "/dev/r${dev%:*}c" 2> /dev/null | sed -n -e 's/^Vendor:[[:space:]]*(.*?)[[:space:]]*$/VENDOR["'"${dev%:*}"'"]="\1"/p' -e 's/^Product:[[:space:]]*(.*?)[[:space:]]*$/MODEL["'"${dev%:*}"'"]="\1"' -e 's/^Revision:[[:space:]]*(.*?)[[:space:]]*$/REV["'"${dev%:*}"'"]="\1"/p')"
                RAWDEVS["${dev}"]="/dev/r${dev}c"
                MOUNTDEVS["${dev}"]="/dev/${dev}c"
                ;;
              # no default case here, it's fine
            esac
        done
        ;;
      *-haiku)
        local -a DISKDEVS
        # list all the local disk devices
        readarray -t DISKDEVS <<<"$(find /dev/disk -not -type d -and -not -name 'control')"

        local -a MOUNTEDDEVS
        # get everything that's not mounted as UDF (because that _could_ be
        # an optical drive... maybe?)
        readarray -t MOUNTEDDEVS <<<"$(df -b | awk '{ if ($NF ~ /^\/dev\//) { if ($(NF-4) != "udf") print $NF; } }')"
        for dev in "${MOUNTEDDEVS[@]}" ; do
            # this should strip off the slice number...
            dev="${dev%/[0-9]}"
            for index in "${!DISKDEVS[@]}" ; do
                if [[ "${DISKDEVS[${index}]}" = "${dev}"/* ]] ; then
                    unset "DISKDEVS[${index}]"
                fi
            done
            RAWDEVS["${dev}"]="/dev/${dev}"
            # shellcheck disable=SC2034
            MOUNTDEVS["${dev}"]="/dev/${dev}"
        done
        CDDEVS=("${DISKDEVS[@]}")
        # Not sure how to get vendor/model/rev info, and there's no 'dmesg'
        # on Haiku to 'grep' through...
        ;;
      *)
        echo "FATAL: Machine type ${BASH_VERSINFO[5]} isn't known to me." 1>&2
        exit 1
        ;;
    esac
}

# Determine which of the found drives are (likely) ones we can use.
validate_drives() {
    local key
    for key in "${!CDDEVS[@]}" ; do
        case "${MODEL[${CDDEVS[${key}]}]}" in
          DVD-RAM\ *|DVD-RW\ *|DVD-R\ *|DVD+RW\ *|DVD+R\ *)
            echo "Device ${CDDEVS[${key}]} is DVD"
            ;;
          BD-RE\ *|BD-R\ *|BD-ROM\ *|BD-MLT\ *|BDDVD*)
            echo "Device ${CDDEVS[${key}]} is BD, can also read DVDs"
            ;;
          *)
            echo "Device ${CDDEVS[${key}]} doesn't appear to support media we care about"
            unset "CDDEVS[${key}]"
            ;;
        esac
    done
}

# Check to see if there's a disc in the given drive, and if so, try to
# comprehend what kind it is and get its volume label.
check_drive_for_media() {
    local DEVICE="${1}"
    case "${BASH_VERSINFO[5]}" in
      *-linux-gnu)
        udfinfo "${RAWDEVS[${DEVICE}]}" 2> /dev/null | sed -n 's/^\(udfrev\|label\)=\(.*\)$/\1="\2"/p'
        ;;
      *-freebsd*|*-dragonfly*|*-netbsd|*-openbsd*)
        "${CMDPREFIX[@]}" file -Ls "${RAWDEVS[${DEVICE}]}" 2> /dev/null | \
                sed -n 's/^.*UDF filesystem data (version \([0-9\.]*\)) '\''\([^'\'']*[^[:space:]]\)[[:space:]]*'\''[[:space:]]*$/label="\2"\
udfrev="\1"/p'
        ;;
      *-haiku)
        file -Ls "${RAWDEVS[${DEVICE}]}" 2> /dev/null | \
                sed -n 's/^.*UDF filesystem data (version \([0-9\.]*\)) '\''\([^'\'']*[^[:space:]]\)[[:space:]]*'\''[[:space:]]*$/label="\2"\
udfrev="\1"/p'
        ;;
      *-apple-darwin*)
        echo "ERROR: Don't know how to do this on MacOS yet." 1>&2
        ;;
    esac
    return "${PIPESTATUS[0]}"
}

# Get the total block device size so we can track progress.
get_blkdev_size() {
    local DEVICE="${1}"

    case "${BASH_VERSINFO[5]}" in
      *-linux-gnu)
        echo "$(( $(cat "/sys/class/block/${DEVICE}/size") * 512 ))"
        ;;
      *-freebsd*)
        diskinfo "${RAWDEVS[${DEVICE}]}" | awk '{ print $3 }'
        ;;
      *-dragonfly*)
        printf '%d\n' "$(diskinfo "${RAWDEVS[${DEVICE}]}" | awk '{ sub(/^size=/, "", $4); print $4; }')"
        ;;
      *-netbsd|*-openbsd*)
        # ghetto, but it works
        smartctl -d scsi --all "${RAWDEVS[${DEVICE}]}" | sed -n 's/^User Capacity:[[:space:]]*\([[:digit:],]*\) bytes .*$/\1/p' | tr -d ','
        ;;
      *-haiku)
        ;;
#      *-apple-darwin*)
#        ;;
    esac
}

if [ "${0}" = "${BASH_SOURCE[0]}" ] ; then
    echo "This script is not an executable, it doesn't do anything."
fi
