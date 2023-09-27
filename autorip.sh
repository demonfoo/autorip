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

# Get title info with 'eac3to' for Blu-ray Discs (and UHD Blu-rays).
my_eac3to_gettitles() {
    local MOUNTPOINT="${1}"

    eac3to "${MOUNTPOINT}" 2> /dev/null | perl <(cat <<'_EOT_'
use strict;
use warnings;
use JSON;
use Array::Utils qw(:all);
use English qw(-no_match_vars);
use Carp qw(croak);
use Scalar::Util qw(refaddr);

my $data = [];

my %langmap;
for (my $i = 0; $i < (scalar(@ARGV) / 2) - 1; $i++) {
    $langmap{$ARGV[$i]} = $ARGV[(scalar(@ARGV) / 2) + $i];
}

my %widths = ( '480' => '720', '576' => '720', '720' => '1280',
               '1080' => '1920', '2160' => '3840' );
my %channelmap = ( 'mono' => '1', 'stereo' => '2', 'multi-channel' => '6' );
my %codecmap = ('AC3' => 'ac3', 'DTS' => 'dts', 'DTS Master Audio' => 'dtshd',
                'DTS Hi-Res' => 'dtshd', 'TrueHD' => 'truehd',
                'TrueHD/AC3' => 'truehd', 'E-AC3' => 'eac3',
                'RAW/PCM' => 'lpcm');

my $title;
my $audiotracknum = 1;
my $got_videoinfo = 0;
while (<STDIN>) {
    chomp;

    if (m{^\x08*(?<titlenum>\d+)\) (?<playlist>\d{5}\.mpls), (?:(?<streams>\d{5}\.m2ts(?:\+\d{5}.m2ts)*), )?(?<runtime>\d:\d{2}:\d{2})\s*$}) {
        my $time = ${^CAPTURE}{runtime};
        $title = {};
        $got_videoinfo = 0;
        push @{$data}, $title;
        ${$title}{ix}       = ${^CAPTURE}{titlenum};
        ${$title}{audio}    = [];
        #${$title}{chapter}  = [];
        ${$title}{playlist} = ${^CAPTURE}{playlist};
        if (defined ${^CAPTURE}{streams}) {
            ${$title}{streams}  = [split(m{\+}, ${^CAPTURE}{streams})];
        }
        my @runtime         = split(m{:}, $time);
        ${$title}{length}   = sprintf('%d', ($runtime[0] * 3600) + ($runtime[1] * 60) + $runtime[2]);
    }
    elsif (m{^\x08*    ?\[(?<streams>\d{1,5}(?:\+\d{1,5})*)\]\.m2ts\s*$}) {
        ${$title}{streams}  = [ map { sprintf('%05d.m2ts', $_); } split(m{\+}, ${^CAPTURE}{streams}) ];
    }
    #elsif (m{^\x08*    ?- Chapters, (?<nchapters>\d+) chapters\s*$}) {
    #    for (my $i = 1; $i <= ${^CAPTURE}{nchapters}; $i++) {
    #        push @{${$title}{chapter}}, {};
    #    }
    #}
    elsif (m{^\x08*    ?- (?<codec>[^,]+), (?<res>\d+)(?<prog>[ip])(?<framerate>\d+)(?: /(?<divisor>1\.001))? \((?<aspect>\d+:\d+)\)(?:, (?<hdrformat>[^,]+), (?<colorspace>BT\.(?:709|2020)))?\s*$}) {
        next if $got_videoinfo == 1;
        my %captures = %{^CAPTURE};
        $captures{aspect} =~ s{:}{/};
        ${$title}{aspect} = $captures{aspect};
        if (defined $captures{divisor}) {
            $captures{framerate} /= $captures{divisor};
        }
        if ($captures{prog} eq 'i') {
            $captures{framerate} /= 2;
        }
        my $fps = sprintf('%0.3f', $captures{framerate});
        $fps =~ s{\.?0+$}{};
        ${$title}{fps}          = $fps;
        ${$title}{progressive}  = $captures{prog} eq 'p' ? 'true' : 'false';
        ${$title}{height}       = $captures{res};
        ${$title}{width}        = $widths{$captures{res}};
        ${$title}{format}       = $captures{codec};
        if (defined $captures{hdrformat}) {
            ${$title}{hdrformat}    = $captures{hdrformat};
            ${$title}{colorspace}   = $captures{colorspace};
        }
        $got_videoinfo          = 1;
    }
    elsif (m{^\x08*    ?- (?<codec>[^,]+), (?<language>[^,]+), (?<channels>[[:alpha:]-]+), (?<rate>\d+)kHz\s*$}) {
        my $audio = {};
        ${$audio}{ix}           = $audiotracknum++;
        ${$audio}{language}     = ${^CAPTURE}{language};
        ${$audio}{langcode}     = $langmap{${^CAPTURE}{language}};
        ${$audio}{channels}     = $channelmap{${^CAPTURE}{channels}};
        ${$audio}{frequency}    = ${^CAPTURE}{rate} . '000';
        ${$audio}{format}       = $codecmap{${^CAPTURE}{codec}};
        push @{${$title}{audio}}, $audio;
    }
}

sub isSimplyIncreasingSequence {
    my ($seq) = @_;

    unless (defined($seq)
            and ('ARRAY' eq ref $seq)) {
        croak 'Expecting a reference to an array as first argument';
    }

    return 1 if @$seq < 2;

    my $first = $seq->[0];

    for my $n (1 .. $#$seq) {
        return unless $seq->[$n] == $first + $n;
    }

    return 1;
}

# look for a play-all title first...
my $playall_title;
my @checklist;
OUTER:
for (my $i = 0; $i <= $#{$data}; $i++) {
    # using play length for now as a guess, hopefully can do that better later
    if (scalar @{${$data}[$i]{streams}} >= 2 && ${$data}[$i]{length} > 5400) {
        # okay, we've found one... so now what to do about it
        my $matchcount = 0;
        @checklist = ();
        for (my $j = 0; $j <= $#{$data}; $j++) {
            # don't look at the same title item
            next if $j == $i;
            next if scalar(@{${$data}[$i]{streams}}) == scalar(@{${$data}[$j]{streams}});
            my @matches = intersect(@{${$data}[$i]{streams}}, @{${$data}[$j]{streams}});
            if (scalar(@matches) == scalar(@{${$data}[$j]{streams}})) {
                #print {*STDERR} "found a match in the playlist\n";
                $matchcount++;
                # find the first playlist item from the $j playlist, then
                # find its offset in the $i playlist, then save the playlist
                # in a temp array?
                for (my $k = 0; $k <= $#{${$data}[$i]{streams}}; $k++) {
                    if (${$data}[$j]{streams}[0] eq ${$data}[$i]{streams}[$k]) {
                        $checklist[$k] = ${$data}[$j];
                        #printf( {*STDERR} "added playlist %s at offset %d\n", $checklist[$k]{playlist}, $k);
                    }
                }
            }
        }
        if ($matchcount == scalar(@{${$data}[$i]{streams}}) && $matchcount > 1) {
            # can we find a sequence in the stuff in @checklist?
            my @matchlist = map { ${$_}{playlist} =~ m{^0+(\d+)\.mpls$}; $1 } @checklist;
            # if so, then use this alternative sort method
            if (!isSimplyIncreasingSequence(\@matchlist)) {
                #print {*STDERR} "looks like the playlist numbers aren't in a normal order, so sort a different way\n";
                $playall_title = ${$data}[$i];
                last OUTER;
            }
        }
    }
}

if (defined $playall_title) {
    # put the play-all list in first, then the titles in the play-all
    # list order, then... whatever the fuck is left?
    my $newlist = [ $playall_title, @checklist ];

    for (my $i = 0; $i <= $#{$data}; $i++) {
        if (${$data}[$i] eq $playall_title) {
            delete ${$data}[$i];
        }
        for (my $j = 0; $j <= $#checklist; $j++) {
            if (defined(${$data}[$i]) &&
                    refaddr(${$data}[$i]) == refaddr($checklist[$j])) {
                delete ${$data}[$i];
            }
        }
        if (defined ${$data}[$i]) {
            push @{$newlist}, ${$data}[$i];
        }
    }

    $data = $newlist;
}
else {
    # sort by mpls file name
    $data = [ sort { ${$a}{playlist} cmp ${$b}{playlist} } @{$data} ];
}

print encode_json($data), "\n";
_EOT_
) "${!LANGS_TO_ISO639_1[@]}" "${LANGS_TO_ISO639_1[@]}"
# ^^^ this will allow us to map language strings to codes
}

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
        my_eac3to_gettitles "${BASEPATH}"
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
        # punt the rest of the job to the series solver subroutine...
        series_solver "${DISC_SERIESID[${item}]}" "${DISC_SEASONNUM[${item}]:-}" 'check_for_unchecked_rips'

        # once all the metadata is loaded, this does the whole series solve,
        # so do a pass through the array and nix other disc roots for the
        # same series(/season, if applicable).
        for key2 in "${!ALREADY[@]}" ; do
            if [ "${DISC_SERIESID[${ALREADY[${key2}]}]}" = "${DISC_SEASONNUM[${item}]:-}" ] ; then
                if [ -z "${DISC_SEASONNUM[${item}]:-}" ] || \
                        [ "${DISC_SEASONNUM[${ALREADY[${key2}]}]}" = "${DISC_SEASONNUM[${item}]}" ] ; then
                    echo unset "ALREADY[${key2}]"
                    unset "ALREADY[${key2}]"
                fi
            fi
        done
    done

    echo 'Enumerated extant disc dumps. Start looking for discs to rip...'
fi

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
