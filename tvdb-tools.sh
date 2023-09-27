#!/usr/bin/env bash

TVDB_TOKEN=''
tvdb_login() {
    local PIN="${1}"

    if [ -z "${PIN}" ] ; then
        echo "FATAL: No TheTVDB API token supplied, can't look stuff up!" 1>&2
        exit 1
    fi
    eval "$(curl --silent --header 'Content-Type: application/json' \
            --header 'Accept: application/json' -X POST \
            https://api4.thetvdb.com/v4/login \
            -d "{ \"apikey\": \"${TVDB_APPKEY}\", \"pin\": \"${TVDB_PIN}\" }" \
            2> /dev/null | jq -r '"TVDB_TOKEN=" + (.data.token | @sh)')"
}

urlencode() {
    jq -r -n --arg val "${1:?No string specified to URL encode}" '$val | @uri'
}

tvdb_search() {
    local TERMS="${1}"

    curl --silent --header 'Content-Type: application/json' \
            --header "Authorization: Bearer ${TVDB_TOKEN}" \
            --header 'Accept: application/json' -X GET \
            "https://api4.thetvdb.com/v4/search?query=$(urlencode "${TERMS}")&type=series&limit=10"
}

tvdb_get_series() {
    local SERIESID="${1}"

    curl --silent --header 'Content-Type: application/json' \
            --header "Authorization: Bearer ${TVDB_TOKEN}" \
            --header 'Accept: application/json' -X GET \
            "https://api4.thetvdb.com/v4/series/${SERIESID}"
}

tvdb_get_episodes() {
    local SERIESID="${1}"
    local ORDER="${2:-official}"
    local LANG="${3:-eng}"

    curl --silent --header 'Content-Type: application/json' \
            --header "Authorization: Bearer ${TVDB_TOKEN}" \
            --header 'Accept: application/json' -X GET \
            "https://api4.thetvdb.com/v4/series/${SERIESID}/episodes/${ORDER}/${LANG}"
}

if [ "${0}" = "${BASH_SOURCE[0]}" ] ; then
    echo "This script is not an executable, it doesn't do anything."
fi
