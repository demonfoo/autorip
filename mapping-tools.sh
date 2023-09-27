#!/usr/bin/env bash

declare -A TITLEINFO

# This is where we try to puzzle out a whole season (or series), and then
# queue remuxing/transcoding jobs for the individual episodes. Or we will,
# anyway, _eventually_.
series_solver() {
    local SERIESID="${1}"
    local SEASONNUM="${2}"
    local CHECK_SUB="${3:-check_active_ripping}"

    # now, we need to do a few things:
    # * figure out what discs are part of the series(/season, if given)
    # * figure out which of the titles from those discs are actual episodes
    #   and not just "play all"/extras/other detritus
    # * determine if any are missing, and if not, don't proceed.
    # * if we _do_ have an entire season/series (some stuff like Witchblade
    #   doesn't indicate seasons, but has > 1 season spread across the discs)
    #   get the necessary info and collect it to relay for
    #   remuxing/transcoding/whatever our endgame is.

    # step 1: get the paths for the series(/season, if relevant)
    local key dev
    local -a CANDIDATE_PATHS=()
    # FIXME: Need to handle situation where a one-off (first?) disc doesn't
    # indicate a season number, but it's part of a season (typically the
    # first season). c.f.: Game of Thrones S1.
    for key in "${!DISC_SERIESID[@]}" ; do
        if ! "${CHECK_SUB}" "${key}" "${SERIESID}" "${SEASONNUM}" ; then
            return 0
        fi
        if [ "${DISC_SERIESID[${key}]}" = "${SERIESID}" ] ; then
            CANDIDATE_PATHS+=("${key}")
        fi
    done
    # now we'll have all the disc roots for the series; if SEASONNUM isn't
    # empty, filter that down to just the season-relevant ones. if we're
    # getting a SEASONNUM at all, there should already be values for it.
    if [ -n "${SEASONNUM:-}" ] ; then
        for key in "${!CANDIDATE_PATHS[@]}" ; do
            if [ "${DISC_SEASONNUM[${CANDIDATE_PATHS[${key}]}]}" != "${SEASONNUM}" ] ; then
                unset "CANDIDATE_PATHS[${key}]"
            fi
        done
    fi
    local -a DISCPATHS=() UNNUMBERED_PATHS=()
    local path
    for path in "${CANDIDATE_PATHS[@]}" ; do
        if [ "${DISC_NUM_IN_SEASON[${path}]}" != '?' ] ; then
            DISCPATHS["${DISC_NUM_IN_SEASON[${path}]}"]="${path}"
        else
            UNNUMBERED_PATHS+=("${path}")
        fi
    done
    local MAYBE_DISCNUM
    if [ "${#UNNUMBERED_PATHS[@]}" -gt 0 ] ; then
        # there were discs that weren't numbered, let's do a check...
        if [ "${#UNNUMBERED_PATHS[@]}" -gt 1 ] ; then
            echo "FATAL: More than one unnumbered dumped disc, not sure what to do" 1>&2
            exit 1
        fi
        for (( I=1;  ; I++ )) ; do
            if [ -z "${DISCPATHS[${I}]:-}" ] ; then
                # Guess the missing disc...
                DISCPATHS["${I}"]="${UNNUMBERED_PATHS[0]}"
                MAYBE_DISCNUM="${I}"
                break
            fi
        done
    fi

    echo "Found discs for series/season:"
    local -a DISC_TITLELISTS
    for path in "${DISCPATHS[@]}" ; do
        echo "    ${path}"
        DISC_TITLELISTS+=("${TITLEINFO[${path}]}")
    done

    if map_series_data "${SERIESID}" "${SEASONNUM:-}" "${DISCPATHS[@]}" '/==/' "${DISC_TITLELISTS[@]}" ; then
        echo "Mapper thinks series is complete, so we would queue transcodes/remuxes here..."
        # Possible disc number is _probably_ safe to actually apply now...
        if [ -n "${MAYBE_DISCNUM:-}" ] ; then
            DISC_NUM_IN_SEASON["${UNNUMBERED_PATHS[0]}"]="${MAYBE_DISCNUM}"

            jq -n --arg tvdbid "${PATH_TO_SERIESID[${UNNUMBERED_PATHS[0]}]}" \
                    --arg season "${DISC_SEASONNUM[${UNNUMBERED_PATHS[0]}]:-}" \
                    --arg discnum "${MAYBE_DISCNUM}" \
                    '{ "tvdbid": ($tvdbid | tonumber),
                       "discnum": (if $discnum == "?" then "?" else ($discnum | tonumber) end) } |
                       if $season != "" then .season = ($season | tonumber) else . end' \
                               > "${UNNUMBERED_PATHS[0]}/${TVDB_META_FILE}"

        fi
    fi
    echo "TBD: solve for series/season for '${SERIESID}' season '${SEASONNUM:-n/a}'"
    echo ''
    # FIXME: Still need to actually handle queuing transcodes/remuxes/whatever.
}

map_series_data() {
    local SERIESID="${1}"
    local SEASONNUM="${2}"
    shift 2

    local BASEPATH
    BASEPATH="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
    # call the perl script that does the real work here
    perl "${BASEPATH}/series-mapper.pl" "${SEASONNUM}" \
            <(cat <<<"${SERIESINFO[${SERIESID}]}") \
            $(( MIN_TITLE_LEN / 60 )) "${AUDIO_LANG}" "$@"
}

add_title_to_map() {
    local DUMP_PATH="${1}"
    local TVDBID="${2}"
    local SEASONNUM="${3:-}"
    local DISCNUM="${4}"
    local SERIESNAME="${5:-}"

    PATH_TO_SERIESID["${DUMP_PATH}"]="${TVDBID}"
    if [ -z "${SERIESINFO[${TVDBID}]:-}" ] ; then
        SERIESINFO["${TVDBID}"]="$(tvdb_get_episodes "${TVDBID}")"

        eval "$(jq -r '[(.name | ascii_downcase), .aliases[]? | ascii_downcase] |
                "NAMES=(" + (. | @sh) + ")"' <<<"${METADATA_CACHE[${TVDBID}]}")"
        for name in "${NAMES[@]}" ; do
            SERIESNAME_MAP["${name}"]="${TVDBID}"
            # also remove spaces, just in case...
            SERIESNAME_MAP["${name// /}"]="${TVDBID}"
        done
    fi
    if [ -n "${SERIESNAME:-}" ] ; then
        SERIESNAME_MAP["${SERIESNAME}"]="${TVDBID}"
    fi
    DISC_SERIESID["${DUMP_PATH}"]="${TVDBID}"
    if [ -n "${SEASONNUM:-}" ] ; then
        local -A SEASONLIST
        eval "$(jq -r '[[.data.episodes[].seasonNumber] | reduce .[] as $season ({}; .[$season | tostring] =  "1") | keys | .[] | select(. != "0")] | map_values("[" + (. | @sh ) + "]=1") | "SEASONLIST=(" + (. | join(" ")) + ")"' <<<"${SERIESINFO[${TVDBID}]}")"
        if [ -z "${SEASONLIST[${SEASONNUM}]:-}" ] ; then
            # disc indicates a season number that doesn't exist, so let's
            # see if there's a reason for that
            #echo "Season number '${SEASONNUM}' doesn't seem to exist, maybe this is a \"half-season\"..."
            if [ -n "${SEASONLIST[${SEASONNUM:0:$((${#SEASONNUM} - 1))}]}" ] ; then
                case "${SEASONNUM:$((${#SEASONNUM} - 1))}" in
                  0)
                    # not a half-season...
                    #echo "Not a \"half-season\", I don't think..."
                    :
                    ;;
                  5)
                    #echo "Looks like a \"half-season\", incrementing disc number some to compensate..."
                    # it is a half-season (apparently)
                    (( DISCNUM+=MULTIPART_OFFSET ))
                    ;;
                  *)
                    # If this ever happens, whatever it is rates about a 9.0
                    # on my weird-shit-o-meter...
                    echo "FATAL: Season number unrealistically high, but doesn't seem to be a fractional season...?" 1>&2
                    exit 1
                    ;;
                esac
                # strip off the trailing digit to compensate (thanks BSG S4!)
                SEASONNUM="${SEASONNUM:0:$((${#SEASONNUM} - 1))}"
            else
                # The season number still doesn't make sense to me?
                echo "FATAL: Season number doesn't exist, and not sure what to do about it" 1>&2
                exit 1
            fi
        fi

        DISC_SEASONNUM["${DUMP_PATH}"]="${SEASONNUM}"
    fi
    local key
    local -a DISCPATHS
    for key in "${!DISC_SERIESID[@]}" ; do
        if [ "${DISC_SERIESID[${key}]}" = "${TVDBID}" ] && \
                [ "${key}" != "${DUMP_PATH}" ] ; then
            if [ -z "${SEASONNUM:-}" ] || \
                    [ "${DISC_SEASONNUM[${key}]:-}" = "${SEASONNUM}" ] ; then
                if [ "${DISC_NUM_IN_SEASON[${key}]}" = "${DISCNUM}" ] ; then
                    # there's another disc with the same disc number; we
                    # should handle this (thanks TNG S1 and S5!)
                    echo "Disc dumps '${key##*/}' and '${DUMP_PATH##*/}' have the same disc number."
                    local REPLY
                    read -n 1 -r -p "Is '${DUMP_PATH##*/}' the actual disc ${DISCNUM}? (Y/N) " REPLY
                    echo ''
                    case "${REPLY}" in
                      Y|y)
                        local OTHERDISCNUM
                        read -r -e -i '1' -p "What disc is ${key##*/} in the season/series? " OTHERDISCNUM
                        DISC_NUM_IN_SEASON["${key}"]="${OTHERDISCNUM}"
                        # update the dumped disc stored metadata too.
                        jq -n --arg tvdbid "${TVDBID}" --arg season "${SEASONNUM:-}" \
                                --arg discnum "${OTHERDISCNUM}" \
                                '{ "tvdbid": ($tvdbid | tonumber),
                                   "discnum": (if $discnum == "?" then "?" else ($discnum | tonumber) end) } |
                                    if $season != "" then .season = ($season | tonumber) else . end' > "${key}/${TVDB_META_FILE}"

                        ;;
                      N|n)
                        read -r -e -i '1' -p 'What disc is this in the season/series? ' DISCNUM
                        ;;
                    esac
                fi
            fi
        fi
    done

    DISC_NUM_IN_SEASON["${DUMP_PATH}"]="${DISCNUM}"
    if ! [ -f "${DUMP_PATH}/${TVDB_META_FILE}" ] ; then
        jq -n --arg tvdbid "${TVDBID}" --arg season "${SEASONNUM:-}" \
                --arg discnum "${DISCNUM}" \
                '{ "tvdbid": ($tvdbid | tonumber), "discnum": (if $discnum == "?" then "?" else ($discnum | tonumber) end) } | if $season != "" then .season = ($season | tonumber) else . end' > "${DUMP_PATH}/${TVDB_META_FILE}"
    fi
}

identify_title() {
    local DUMP_PATH="${1:-}"
    local label="${2}"
    local disctype="${3}"
    local dev="${4:-}"

    local SERIESNAME SEASONNUM DISCNUM ORIG_SERIESNAME TVDBID RESULTS \
            FILTERED NUMRESULTS

    if [ -n "${DUMP_PATH}" ] && [ -d "${DUMP_PATH}" ] && \
            [ -f "${DUMP_PATH}/${TVDB_META_FILE}" ] ; then
        eval "$(jq -r --arg dump_path "${DUMP_PATH}" \
                '"TVDBID=" + (.tvdbid | @sh) +
                 "\nDISCNUM=" + (.discnum | @sh) +
                 if .season then "\nSEASONNUM=" + (.season | @sh) else "" end' \
                         "${DUMP_PATH}/${TVDB_META_FILE}")"

        if [ -n "${TVDBID:-}" ] ; then
            # FIXME: Cache the series info on local disk?
            METADATA_CACHE["${TVDBID}"]="$(tvdb_get_series "${TVDBID}" | \
                    jq -r '.data | .aliases = ([.aliases[] |
                    select(.language == "eng")] | map_values(.name))')"
            add_title_to_map "${DUMP_PATH}" "${TVDBID}" "${SEASONNUM:-}" \
                    "${DISCNUM}" "$(jq -r '.name | sub("\\s+\\(\\d{4}\\)\\s*$";"") | ascii_downcase' <<<"${METADATA_CACHE[${TVDBID}]}")"

            return 0
        else
            rm -f "${DUMP_PATH}/${TVDB_META_FILE}"
        fi
    fi

    # this is a pretty wild regex, but it works for a bunch of series...
    if [[ "${label}" =~ ^(.*[[:alnum:]])[_' ']+S(ERIES|EASON)?[_' ']?([[:digit:]]+)([_' ']AND[_' ']A[_' ']HALF|[_' ']P(AR)?T([[:digit:]]+)|[_' '][A-CE-Z][[:alnum:]]+)?([_' ']?D(ISC)?[_' ']?([[:digit:]]+)([_' '][[:alpha:]]+)?)?$ ]] ; then
        printf 'Looks like "%s" is part of a season-numbered group...\n' "${label}"
        SERIESNAME="${BASH_REMATCH[1]}"
        SEASONNUM="${BASH_REMATCH[3]}"
        # if no disc number comes through, flag it this way so the
        # season/series solver knows to put it in the missing place
        DISCNUM="${BASH_REMATCH[9]:-?}"
        # the following should never coincide with an unknown disc number...
        if [[ "${BASH_REMATCH[6]}" = [1-9] ]] ; then
            local PARTNUM="${BASH_REMATCH[6]}"
            # this is a multi-part set (thanks Doctor Who series 7!)
            #echo "multi-part set found, part ${PARTNUM}, adjusting..."
            (( DISCNUM+= (PARTNUM - 1) * MULTIPART_OFFSET ))
        fi
        if [[ "${BASH_REMATCH[4]}" = [_' ']AND[_' ']A[_' ']HALF ]] ; then
            # this means a "half season" (thanks BSG S4!)
            #echo "\"half-season\" found, adjusting..."
            (( DISCNUM+=MULTIPART_OFFSET ))
        fi
    elif [[ "${label}" =~ ^(.*?)[_' ']D(ISC)?[_' ']?([[:digit:]]+)$ ]] ; then
        printf 'Looks like "%s" is part of a numbered, but not season-numbered, group...\n' "${label}"
        SERIESNAME="${BASH_REMATCH[1]}"
        unset SEASONNUM
        DISCNUM="${BASH_REMATCH[3]}"
    elif [[ "${label}" =~ ^(.*?)[_' ']([[:digit:]]+)$ ]] ; then
        printf 'Looks like "%s" is part of a numbered, but not season-numbered, group...\n' "${label}"
        SERIESNAME="${BASH_REMATCH[1]}"
        unset SEASONNUM
        DISCNUM="${BASH_REMATCH[2]}"
    else
        # doesn't look like a typical TV series volume label. let's ask the
        # user to fill in the gaps.
        printf '\nUnsure what to make of "%s"...\n' "${label}"
        SERIESNAME="${label//_/ }"
        SERIESNAME="${SERIESNAME,,}"
        if [ -n "${SERIESNAME_MAP[${SERIESNAME}]:-}" ] ; then
            TVDBID="${SERIESNAME_MAP[${SERIESNAME}]}"
            printf 'This seems to correspond to TVDB ID "%s".\n' "${TVDBID}"
        fi
        local REPLY
        while : ; do
            read -n 1 -r -p 'Is this definitely a TV series (Y/N)? ' REPLY
            echo ''
            case "${REPLY}" in
              N|n)
                if [ -n "${dev}" ] ; then
                    "${CMDPREFIX[@]}" eject "${RAWDEVS[${dev}]}"
                fi
                return 1
                ;;
              Y|y)
                break
                ;;
            esac
            # yes, keep prompting until we get a yes/no answer
        done

        # If the TVDBID is set, it's already a known show; if not, let's
        # find out what it is...
        if [ -z "${TVDBID:-}" ] ; then
            read -r -p 'Series name: ' -e -i "${SERIESNAME}" SERIESNAME
            # the rest of the search will happen shortly...
            if [ -n "${SERIESNAME_MAP[${SERIESNAME}]:-}" ] ; then
                TVDBID="${SERIESNAME_MAP[${SERIESNAME}]}"
                printf 'This seems to correspond to TVDB ID "%s".\n' "${TVDBID}"
            fi
        fi
        read -r -p 'What season is this disc from (if any)? ' SEASONNUM
        # try to guess likely disc number base on what discs are already
        # dumping/dumped for the series/season
        if [ -n "${TVDBID:-}" ] ; then
            local key
            for (( DISCNUM=1; ; DISCNUM++ )) ; do
                for key in "${!DISC_SERIESID[@]}" ; do
                    # match same series id
                    if [ "${DISC_SERIESID[${key}]}" = "${TVDBID}" ] ; then
                        # match season (if applicable)
                        if [ -z "${SEASONNUM:-}" ] || \
                                [ "${DISC_SEASONNUM[${key}]}" = "${SEASONNUM}" ] ; then
                            # match disc number
                            if [ "${DISC_NUM_IN_SEASON[${key}]}" = "${DISCNUM}" ] ; then
                                # if we made it here, there's a conflicting
                                # disc number, so keep going
                                continue 2
                            fi
                        fi
                    fi
                done
                # if we got all the way to the end of the list of discs,
                # there was no conflict, so use this disc number.
                break
            done
        fi
        read -r -e -i "${DISCNUM}" -p 'What disc is this in the season/series (1 if the only disc)? ' DISCNUM
    fi
    # make series name something we could (probably) search for in thetvdb
    SERIESNAME="${SERIESNAME//_/ }"
    SERIESNAME="${SERIESNAME,,}"
    ORIG_SERIESNAME="${SERIESNAME}"

    if [ -n "${dev}" ] ; then
        # DUMP_PATH gets defined here, if it's not already...
        start_dump "${dev}" "${disctype}" "${WORKDIR}" "${label}"
    fi

    # Use the cached series mapping, if possible.
    if [ -n "${SERIESNAME_MAP[${SERIESNAME}]:-}" ] ; then
        TVDBID="${SERIESNAME_MAP[${SERIESNAME}]}"
        add_title_to_map "${DUMP_PATH}" "${TVDBID}" "${SEASONNUM:-}" \
                "${DISCNUM}" "${ORIG_SERIESNAME}"
        return 0
    fi
    while : ; do
        # Try searching based on the series name.
        RESULTS="$(tvdb_search "${SERIESNAME}")"
        FILTERED="$(jq --arg seriesname "${SERIESNAME}" '[.data[] | select((.name | ascii_downcase | sub("\\s+\\(\\d{4}\\)\\s*$";"")) == $seriesname or (.translations.eng // "" | ascii_downcase | sub("\\s+\\(\\d{4}\\)\\s*$";"")) == $seriesname or IN(.aliases[]? | ascii_downcase | sub("\\s+\\(\\d{4}\\)\\s*$";"");$seriesname))]' <<<"${RESULTS}")"
        eval "$(jq -r '"NUMRESULTS=" + (length | @sh)' <<<"${FILTERED}")"
        # See how many results we got back...
        #eval "$(jq -r '"NUMRESULTS=" + (.data | length | @sh)' <<<"${RESULTS}")"
        if [ "${NUMRESULTS}" -eq 1 ] ; then
            TVDBID="$(jq -r '.[0].tvdb_id' <<<"${FILTERED}")"
            METADATA_CACHE["${TVDBID}"]="$(jq -r '.[0]' <<<"${FILTERED}")"
            add_title_to_map "${DUMP_PATH}" "${TVDBID}" "${SEASONNUM:-}" \
                    "${DISCNUM}" "${ORIG_SERIESNAME}"
            return 0
        elif [ "${NUMRESULTS}" -gt 1 ] ; then
            # Try to find an exact name match first...
            #FILTERED="$(jq --arg seriesname "${SERIESNAME}" '[.data[] | select((.name | ascii_downcase | sub("\\s+\\(\\d{4}\\)\\s*$";"")) == $seriesname or (.translations.eng // "" | ascii_downcase | sub("\\s+\\(\\d{4}\\)\\s*$";"")) == $seriesname or IN(.aliases[]? | ascii_downcase | sub("\\s+\\(\\d{4}\\)\\s*$";"");$seriesname))]' <<<"${RESULTS}")"
            eval "$(jq -r '"FILTERED_COUNT=" + (length | @sh)' <<<"${FILTERED}")"
            if [ "${FILTERED_COUNT}" -eq 1 ] ; then
                printf 'Found a name/alias match for "%s"\n' "$(jq -r '.[0].name' <<<"${FILTERED}")"
                TVDBID="$(jq -r '.[0].tvdb_id' <<<"${FILTERED}")"
                METADATA_CACHE["${TVDBID}"]="$(jq -r '.[0]' <<<"${FILTERED}")"
                add_title_to_map "${DUMP_PATH}" "${TVDBID}" "${SEASONNUM:-}" \
                        "${DISCNUM}" "${ORIG_SERIESNAME}"
                return 0
            fi
            # Do a simple picker, then...
            echo 'Please pick the appropriate series name'
            local -A CHOOSELIST
            # generate an associative array based on the series names found,
            # so when the user picks one we can then get the TVDB ID straight
            # away based on that.
            eval "$(jq -r '.data | map_values("[" + (.translations.eng | @sh) +
                    "]=" + (.tvdb_id | @sh)) | join(" ") | "CHOOSELIST=(" + . +
                    ")"' <<<"${RESULTS}")"
            local SHOWNAME
            select SHOWNAME in "${!CHOOSELIST[@]}" 'none of these' ; do
                # If the user picks none, let them edit the string manually...
                if [ "${SHOWNAME}" = 'none of these' ] ; then
                    printf 'Please edit the series name\n'
                    read -r -p 'Series name: ' -e -i "${SERIESNAME}" SERIESNAME
                    break
                fi
                # if nothing corresponds, the user might have mistyped the
                # number or something.
                if [ -z "${CHOOSELIST[${SHOWNAME}]:-}" ] ; then
                    continue
                fi
                TVDBID="${CHOOSELIST[${SHOWNAME}]}"
                METADATA_CACHE["${TVDBID}"]="$(jq --arg tvdbid "${TVDBID}" -r '.[] | select(.tvdb_id == $tvdbid)' <<<"${FILTERED}")"
                add_title_to_map "${DUMP_PATH}" "${TVDBID}" "${SEASONNUM:-}" \
                        "${DISCNUM}" "${ORIG_SERIESNAME}"
                return 0
            done
        elif [ "${NUMRESULTS}" -eq 0 ] ; then
            # let the user edit the series name and try searching again.
            printf 'No results were found; please edit the series name\n'
            read -r -p 'Series name: ' -e -i "${SERIESNAME}" SERIESNAME
        fi
        # If we didn't get any results before, keep trying.
    done
}



if [ "${0}" = "${BASH_SOURCE[0]}" ] ; then
    echo "This script is not an executable, it doesn't do anything."
fi
