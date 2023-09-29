#!/usr/bin/env bash

BASEPATH="$(dirname "$(realpath "${0}")")"
if [ "${BASEPATH##*/}" = 'bin' ] ; then
    BASEPATH="${BASEPATH/%\/bin/\/lib}"
fi
. "${BASEPATH}/tvdb-tools.sh"
. "${BASEPATH}/iso639-info.sh"
. "${BASEPATH}/drive-tools.sh"
. "${BASEPATH}/dvd-tools.sh"
. "${BASEPATH}/makemkv-tools.sh"
. "${BASEPATH}/mapping-tools.sh"

usage() {
    cat 1>&2 <<_EOT_
${0##*/}: Dump TV series from DVD (or BD/UHD-BD) automatically and
transcode/prepare for media server use

    ${0##*/} [OPTIONS]

    OPTIONS:
        -l/--audio-lang [langcode]      Specify the audio language to keep
                                        from the dumped content. If audio
                                        is not available in that language,
                                        English will be kept by default.
        -s/--subtitle-lang [langcode]   Specify subtitle language(s) to keep
                                        from the dumped content. Multiple
                                        languages can be specified.
        -d/--destdir [directory]        Specify the target directory for
                                        the extracted show content.
        -w/--workdir [directory]        Specify the working directory for
                                        dumping discs, transcoding, etc.
                                        You'll want to have a _lot_ of free
                                        disc space here.
        -a/--tvdb-api-key [key]         API key for TheTVDB. It will be used
                                        for looking up series metadata.

_EOT_
}

set -o nounset
clreol="$(tput el)"

declare -A DISC_BASE_SPEEDS=()
# These are KB/sec. They're used to compute how fast the rips are going.
DISC_BASE_SPEEDS=(
        ['dvd']=1385
        ['bd']=4500
)
declare -r DISC_BASE_SPEEDS

if ! options=$(getopt -o 'l:s:d:w:p:m:W:i:h' --long 'audio-lang:,subtitle-lang;,destdir:,workdir:,tvdb-pin:,min-title-len:,wait-time:,idle-time:,help' -- "$@") ; then
    echo "getopt failed?"
    usage
    exit 1
fi
eval set -- "${options}"

# Minimum number of seconds to be considered an actual episode
MIN_TITLE_LEN=480

declare -r TVDB_APPKEY='0037144c-64d6-4823-b609-bb4c79fc300a'

WAIT_TIME=15
IDLE_TIME=600
AUDIO_LANG='en'
SUBTITLE_LANGS=()
WORKDIR='/tmp'
DESTDIR="${HOME}/Videos"
TVDB_PIN=''
declare -r TVDB_META_FILE='.tvdb.json' MULTIPART_OFFSET=10
while : ; do
    case "${1:-}" in
      -l|--audio-lang)
        if [ -n "${ISO639_2_to_1[${2}]}" ] ; then
            AUDIO_LANG="${ISO639_2_to_1[${2}]}"
        elif [ -n "${ISO639_1[${2}]}" ] ; then
            AUDIO_LANG="${2}"
        else
            echo "FATAL: Language id '${2}' isn't known?" 1>&2
            exit 1
        fi
        shift 1
        ;;
      -s|--subtitle-lang)
        if [ -n "${ISO639_2_to_1[${2}]}" ] ; then
            SUBTITLE_LANGS+=("${ISO639_2_to_1[${2}]}")
        elif [ -n "${ISO639_1[${2}]}" ] ; then
            SUBTITLE_LANGS+=("${2}")
        else
            echo "FATAL: Language id '${2}' isn't known?" 1>&2
            exit 1
        fi
        shift 1
        ;;
      -d|--destdir)
        if ! [ -d "${2}" ] ; then
            echo "FATAL: No directory named '${2}' exists?" 1>&2
            exit 1
        fi
        # shellcheck disable=SC2034
        DESTDIR="$(realpath "${2}")"
        shift 1
        ;;
      -w|--workdir)
        if ! [ -d "${2}" ] ; then
            echo "FATAL: No directory named '${2}' exists?" 1>&2
            exit 1
        fi
        WORKDIR="$(realpath "${2}")"
        shift 1
        ;;
      -p|--tvdb-pin)
        TVDB_PIN="${2}"
        shift 1
        ;;
      -m|--min-title-len)
        MIN_TITLE_LEN="${2}"
        shift 1
        ;;
      -W|--wait-time)
        WAIT_TIME="${2}"
        shift 1
        ;;
      -i|--idle-time)
        # shellcheck disable=SC2034
        IDLE_TIME="${2}"
        shift 1
        ;;
      --)
        shift 1
        break
        ;;
      -h|--help)
        usage
        exit 1
        ;;
      *)
        break
        ;;
    esac
    shift 1
done

CMDPREFIX=()
#if [ "${UID}" -gt 0 ] ; then
#    CMDPREFIX=('sudo')
#fi

# shellcheck disable=SC2034
PACKAGES=('udftools' 'sudo' 'dvdbackup' 'smartmontools' 'lsdvd' 'python-yq' 'lsof' 'jq')

# See how far the disc read has gotten, for progress tracking purposes.
find_process_read_offset() {
    local DEVICE="${1}"
    local CHILDPID="${2}"

    if ! command -v lsof >& /dev/null ; then
        return 1
    fi

    lsof -n -p "${CHILDPID}" -o -o 15 2> /dev/null | awk '$9 == "'"${RAWDEVS[$DEVICE]}"'" { sub(/^0t/, "", $7); print $7; }' | head -n 1
}

# Try to use 'lsdvd' or 'eac3to' to get structure info for the disc, and
# mangle it into a useful form.
extract_titleinfo() {
    local BASEPATH="${1}"
    local TYPE="${2}"

    if [ "${TYPE}" = 'bd' ] ; then
        # turns out we can use makemkvcon to do the same thing with a
        # different (though similar) perl script. as much as I like eac3to,
        # it's a complicated dependency, and makemkv is critical to being
        # able to dump blu ray discs at all, so we may as well use it for
        # this too.
        makemkv_get_titleinfo "${BASEPATH}"
    elif [ "${TYPE}" = 'dvd' ] ; then
        my_lsdvd_gettitles "${BASEPATH}"
    fi
}

declare -A DUMP_PIDS=() DUMP_KILLPIDS=() DUMP_PATHS=() DUMP_TYPE=() \
        DUMP_STARTTIME=() DUMP_PROGRESSFILE=() DUMP_LABEL=()
# Kick off a disc dump.
start_dump() {
    local DEVICE="${1}"
    local TYPE="${2}"
    local DUMP_TO="${3}"
    local LABEL="${4}"

    local CHECKSUM
    # some stuff either a) misnumbers the disc labels or b) uses the same
    # volume label for all the discs (c.f.: doctor who). append a checksum
    # of some data from the start of the disc so we can separate one from
    # another...
    CHECKSUM="$(dd if="${RAWDEVS[${DEVICE}]}" bs=2k count=512 2> /dev/null | \
            sha1sum | awk '{ print $1 }')"
    DUMP_PATH="${DUMP_TO}/${LABEL}[${CHECKSUM}]"
    if [ -d "${DUMP_PATH}" ] ; then
        echo "NOTICE: Disc has already been dumped!" 1>&2
        "${CMDPREFIX[@]}" eject "${RAWDEVS[${DEVICE}]}"
        return 0
    fi
    if [ "${TYPE}" = 'bd' ] && [ -n "${MAKEMKV}" ] ; then
        mkdir "${DUMP_PATH}"
        # start the dump job, and store the PID for the started job
        # so we can manage/observe it later
        local PROGRESS_FILE
        PROGRESS_FILE="$(mktemp "${DUMP_TO}/progress_${DEVICE}_XXXXXX")"
        DUMP_PROGRESSFILE["${DEVICE}"]="${PROGRESS_FILE}"
        local PID_FILE
        PID_FILE="$(mktemp "${DUMP_TO}/pid_XXXXXX")"
        # because there's a pipeline there's not a straightforward way to
        # get just the makemkvcon pid, but this should let us do it...
        ( "${MAKEMKV}" backup --robot --decrypt --noscan --progress=-same \
                "disc:${MAKEMKV_DEVMAP[${RAWDEVS[${DEVICE}]}]}" "${DUMP_PATH}" & \
                echo "$!" > "${PID_FILE}") \
                 |& ( while read -r LINE ; do if [[ "${LINE}" =~ ^PRGV:([[:digit:]]+),([[:digit:]]+),([[:digit:]]+)[[:space:]]*$ ]] ; then echo "${BASH_REMATCH[2]} ${BASH_REMATCH[3]}" > "${PROGRESS_FILE}" ; fi ; done ; rm -f "${PROGRESS_FILE}" ) &
        local CHILD_PID="$!"
        DUMP_PIDS["${DEVICE}"]="${CHILD_PID}"
        while : ; do
            if [ -s "${PID_FILE}" ] ; then
                break
            fi
            #echo "PID file is still empty, sleeping briefly"
            sleep 3
        done
        DUMP_KILLPIDS["${DEVICE}"]="$(cat "${PID_FILE}")"
        rm -f "${PID_FILE}"
    elif [ "${TYPE}" = 'dvd' ] ; then
        # start the dump job, and store the PID for the started job
        # so we can manage/observe it later
        mkdir "${DUMP_PATH}"
        # dvdbackup chops off the label. when all else fails... cheat?
        "${CMDPREFIX[@]}" dvdbackup --mirror --input="${RAWDEVS[${DEVICE}]}" \
                --output="${DUMP_PATH}" --name='.' >& /dev/null &
        local CHILD_PID="$!"
        DUMP_PIDS["${DEVICE}"]="${CHILD_PID}"
        DUMP_KILLPIDS["${DEVICE}"]="${CHILD_PID}"
    else
        echo "Disc type '${TYPE}' was unknown, ejecting disc"
        "${CMDPREFIX[@]}" eject "${RAWDEVS[${DEVICE}]}"
        return 0
    fi
    DUMP_PATHS["${DEVICE}"]="${DUMP_PATH}"
    DUMP_TYPE["${DEVICE}"]="${TYPE}"
    DUMP_LABEL["${DEVICE}"]="${LABEL}"
    DUMP_STARTTIME["${DEVICE}"]="${EPOCHSECONDS}"
}

# See if a dump has completed or aborted, and handle that.
check_dump_status() {
    local dev pid DUMP_PATH TYPE
    for dev in "${!DUMP_PIDS[@]}" ; do
        if ! kill -n 0 "${DUMP_KILLPIDS[${dev}]}" >& /dev/null ; then
            # if return is true, then the process finished
            DUMP_PATH="${DUMP_PATHS[${dev}]}"
            TYPE="${DUMP_TYPE[${dev}]}"
            pid="${DUMP_PIDS[${dev}]}"
            # the background task no longer exists
            unset "DUMP_PATHS[${dev}]"
            unset "DUMP_TYPE[${dev}]"
            unset "DUMP_LABEL[${dev}]"
            unset "DUMP_PIDS[${dev}]"
            unset "DUMP_KILLPIDS[${dev}]"
            if [ -n "${DUMP_PROGRESSFILE[${dev}]:-}" ] ; then
                rm -f "${DUMP_PROGRESSFILE[${dev}]}"
                unset "DUMP_PROGRESSFILE[${dev}]"
            fi
            if ! wait "${pid}" ; then
                # return code from the child process was non-zero, so
                # should probably tell the user and remove the dump dir
                # instead of doing anything more with it
                echo "WARNING: Disc dump failed for dev ${dev}, label '${DUMP_PATH##*/}', removing" 1>&2
                rm -rf "${DUMP_PATH}"
                echo "WARNING: Dump failed, try cleaning the disc?" 1>&2
            else
                if ! INFO="$(extract_titleinfo "${DUMP_PATH}" "${TYPE}")" ; then
                #if [ -z "${INFO}" ] ; then
                    echo "WARNING: Couldn't get title info, please clean disc and try again" 1>&2
                    rm -rf "${DUMP_PATH}"
                else
                    TITLEINFO["${DUMP_PATH}"]="${INFO}"
                    # punt the rest of the job to the series solver subroutine...
                    series_solver "${DISC_SERIESID[${DUMP_PATH}]}" "${DISC_SEASONNUM[${DUMP_PATH}]:-}"
                fi
            fi
            "${CMDPREFIX[@]}" eject "${MOUNTDEVS[${dev}]}"
        fi
    done
}

check_active_ripping() {
    local DUMP_PATH="${1}"
    local SERIESID="${2}"
    local SEASONNUM="${3}"

    for dev in "${!DUMP_PATHS[@]}" ; do
        if [ "${DUMP_PATH}" = "${DUMP_PATHS[${dev}]}" ] && \
                [ "${DISC_SERIESID[${DUMP_PATH}]}" = "${SERIESID}" ] ; then
            # if no season number is specified, go ahead; if  there
            # is one, make sure it matches
            if [ -z "${SEASONNUM:-}" ] || \
                    [ "${DISC_SEASONNUM[${DUMP_PATH}]:-}" = "${SEASONNUM}" ] ; then
                echo "NOTICE: Dump still in progress for '${DUMP_LABEL[${dev}]}', let it finish" 1>&2
                return 1
            fi
        fi
    done
    return 0
}

do_progresscheck() {
    # move the cursor up a line and clear to end of line
    printf '\e[1A%s' "${clreol}"
    local key pid size rlen runtime remaintime progress total readrate \
            basespeed readspeed
    for key in "${!DUMP_PIDS[@]}" ; do
        pid="${DUMP_PIDS[${key}]}"
        size="$(get_blkdev_size "${key}")"
        rlen="$(find_process_read_offset "${key}" "${pid}")"
        if [ -n "${DUMP_PROGRESSFILE[${key}]:-}" ] ; then
            # these numbers aren't the real size, so this is a little bit
            # cheat-y, but it _should_ work...
            if ! [ -s "${DUMP_PROGRESSFILE[${key}]}" ] ; then
                sleep 1
            fi
            read -r progress total <<<"$(cat "${DUMP_PROGRESSFILE[${key}]}")"
            if [ -n "${total}" ] ; then
                rlen=$(( size * progress / total ))
            else
                rlen=0
            fi
        fi
        if [ "${rlen}" -eq 0 ] ; then
            continue
        fi

        # estimate how much time is left
        runtime=$(( EPOCHSECONDS - ${DUMP_STARTTIME[${key}]} ))
        remaintime=$(( runtime * (size - rlen) / rlen ))

        readrate=$(( rlen / runtime / 1000 ))
        basespeed="${DISC_BASE_SPEEDS[${DUMP_TYPE[${key}]}]}"
        # actually read speed x10
        readspeed=$(( (readrate * 10) / basespeed ))

        printf '%-30s      %s\n' "${MODEL[${key}]}" "${DUMP_LABEL[${key}]}"
        printf '%s: %12d / %12d %2d%% (%02d:%02d) ~%d.%dx\n' "${key}" "${rlen}" \
                "${size}" $(( ( rlen * 100 ) / size )) \
                $(( remaintime / 60 )) $(( remaintime % 60 )) \
                "${readspeed:0:$(( ${#readspeed} - 1 ))}" \
                "${readspeed:$(( ${#readspeed} - 1 ))}"
    done
}

do_cleanup() {
    echo -e "\nCleaning up..."
    local key
    for key in "${!DUMP_PIDS[@]}" ; do
        # kill the processes, and if they signal they were interrupted,
        # remove partial dumps
        kill -s TERM "${DUMP_KILLPIDS[${key}]}" >& /dev/null
        # FIXME: This doesn't work right with makemkv.
        if ! wait "${DUMP_PIDS[${key}]}" ; then
            rm -rf "${DUMP_PATHS[${key}]}"
        fi
        "${CMDPREFIX[@]}" eject "${MOUNTDEVS[$key]}"
    done

    exit 1
}

# start calling subroutines to make magic happen
discover_drives
can_makemkv
validate_drives

trap 'discover_drives ; can_makemkv ; validate_drives' USR1
trap do_cleanup INT
#trap handle_child_end CHLD
#trap do_cleanup ERR # if we die because of an error, stop rips in progress
trap do_progresscheck QUIT

tvdb_login "${TVDB_PIN}"

# shellcheck disable=SC2034
LASTACTION="${EPOCHSECONDS}"
declare -A PATH_TO_SERIESID=() METADATA_CACHE=() SERIESNAME_MAP=() \
        DISC_SERIESID=() DISC_SEASONNUM=() DISC_NUM_IN_SEASON=() \
        SERIESINFO=()

# find what's already there and gather metadata for those discs/series/shows
readarray -t ALREADY <<<"$(find "${WORKDIR}" -mindepth 1 -maxdepth 1 -type d -name '*\[*\]')"
if [ "${#ALREADY[@]}" -eq 1 ] && [ -z "${ALREADY[0]}" ] ; then
    unset 'ALREADY[0]'
fi

check_for_unchecked_rips() {
    local DUMP_PATH="${1}"
    local SERIESID="${2}"
    local SEASONNUM="${3}"

    local item
    for item in "${ALREADY[@]}" ; do
        if [ "${DUMP_PATH}" = "${item}" ] ; then
            continue
        fi
        if [ "${DISC_SERIESID[${DUMP_PATH}]}" = "${SEASONNUM}" ] ; then
            if [ -z "${SEASONNUM:-}" ] || \
                    [ "${DISC_SEASONNUM[${DUMP_PATH}]}" = "${SEASONNUM}" ] ; then
                echo "NOTICE: Other dumps from this season still pending, skipping for now" 1>&2
                return 1
            fi
        fi
    done
    return 0
}

ELEMS=('/' '-' \\ '|')
I=0

declare -A MAPPED=()
if [ "${#ALREADY[@]}" -gt 0 ] ; then
    echo 'Found extant disc dumps, let'\''s enumerate them.'
    echo ''

    printf 'Fetching metadata, please wait...  '
    for item in "${ALREADY[@]}" ; do
        LABEL="${item##*/}"
        LABEL="${LABEL%\[*\]}"

        if [ -t 1 ] ; then
            printf '\b%s' "${ELEMS[$((I++ % ${#ELEMS[*]}))]}" 1>&2
        fi

        if [ -d "${item}/VIDEO_TS" ] ; then
            disctype='dvd'
        elif [ -d "${item}/BDMV" ] ; then
            disctype='bd'
        else
            #echo "WARNING: Removing broken dump '${item##*/}'.'" 1>&2
            rm -rf "${item}"
            continue
        fi
        identify_title "${item}" "${LABEL}" "${disctype}"

        TITLEINFO["${item}"]="$(extract_titleinfo "${item}" "${disctype}")"
    done
    printf '\n'
    echo 'Metadata fetch complete.'

    for key in "${!ALREADY[@]}" ; do
        item="${ALREADY[${key}]}"
        if [ -z "${item}" ] ; then
            continue
        fi
        # skip a series/season that's already been looked at.
        if [ -n "${MAPPED[${DISC_SERIESID[${item}]}:${DISC_SEASONNUM[${item}]:-?}]:-}" ]
        then
            continue
        fi
        # punt the rest of the job to the series solver subroutine...
        series_solver "${DISC_SERIESID[${item}]}" "${DISC_SEASONNUM[${item}]:-}" 'check_for_unchecked_rips'

        # once all the metadata is loaded, this does the whole series solve,
        # so do a pass through the array and nix other disc roots for the
        # same series(/season, if applicable).
        MAPPED["${DISC_SERIESID[${item}]}:${DISC_SEASONNUM[${item}]:-?}"]=1
    done

    echo 'Enumerated extant disc dumps. Start looking for discs to rip...'
fi
MAPPED=()

# start checking the drives for media; if media is present, try to suss out
# if it's DVD or BD media, and dump out the file tree (if possible)
while : ; do
    for dev in "${CDDEVS[@]}" ; do
        if [ -n "${DUMP_PIDS[${dev}]:-}" ] ; then
            # there's already a process dumping from this drive
            continue
        fi
        if ! DATA="$(check_drive_for_media "${dev}")" ; then
            #echo "No media found in device '$dev'"
            continue
        fi
        eval "${DATA}"
        disctype=''
        # shellcheck disable=SC2154 # set via eval
        case "${udfrev}" in
          2.[56]0)
            # these are always blu-ray disc
            disctype='bd'
            ;;
          1.02|1.5)
            # 1.02 is miniudf, what dvd uses (dual-rooted with iso9660);
            # 'file' says 1.5, which is... close enough for our needs.
            disctype='dvd'
            ;;
          *)
            echo "I'm not familiar with this UDF version (${udfrev})..."
            continue
            ;;
        esac
        identify_title '' "${label}" "${disctype}" "${dev}"
    done
    check_dump_status
    # FIXME: Sometimes, especially on 4K discs, makemkv can get stuck because
    # the drive loses the thread. We should make an effort to notice this and
    # do something about it.
    sleep "${WAIT_TIME}"
done
