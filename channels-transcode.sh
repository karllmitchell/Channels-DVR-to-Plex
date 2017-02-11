#!/bin/bash
#  channels-transcode.sh standalone transcoder via the Channels DVR API
#
#  $1 = The recording ID from Channels DVR API
#  Additional arguments in the form VARIABLE="string" or VARIABLE=value
# 
# If you wish to deliver to Plex, DEST_DIR should be set and showname_clean function made available
#
# Location in which to create Plex-suitable file structure: DEST_DIR
# Locations of binary files: HANDBRAKE_CLI MP4BOX_CLI JQ_CLI FFMPEG_CLI CURL_CLI AP_CLI
# Handbrake tuning: PRESET SPEED EXTRAS MAXSIZE ALLOW_EAC3
# Behaviour of script: SOURCE_DIR BACKUP_DIR CHANNELS_DB HOST TMPDIR 
#    COMTRIM CHAPTERS LANG TVDB_API VERBOSE DEBUG 
# Phone notifications: IFTTT_MAKER_KEY
# 
# By default, comskip results are marked as chapters in output file
# COMTRIM=1 over-rides this to trim out commercials (dangerous)
# See instructions for HandBrake tuning (PRESET, EXTRAS, SPEED, MAXSIZE)
# AP_CLI=1 or e.g. AP_CLI="/usr/bin/AtomicParlsey" enables iTunes style tagging
 
# Reads variables of A=VALUE format
if [ $# -gt 0 ] ; then
  for var in "$@"; do
    regex="(.*)=(.*)"
    if [[ "${var}" =~ (.*)=(.*) ]] ; then
      variable=$(echo "$var" | cut -f1 -d=)
      value=$(echo "$var" | cut -f2- -d=)
      eval "${variable}=\"${value}\""
      if [ "$DEBUG" -eq 1 ]; then echo "${variable}=${value}"; fi
    fi
  done
fi

# A useful little tool for evaluating version numbers
function ver {
  printf "%03d%03d%03d%03d" $(echo "$1" | tr '.' ' ' | head -n 4 )
}

function notify_me {
  echo "${1}"
  if [ "${IFTTT_MAKER_KEY}" ]; then 
    IFTTT_MAKER="https://maker.ifttt.com/trigger/{TVevent}/with/key/${IFTTT_MAKER_KEY}"
    quiet="--silent"
    [ "${VERBOSE}" -eq 2 ] && quiet="--verbose"
    "${CURL_CLI}" $quiet -X POST -H "Content-Type: application/json" -d '{"value1":"'"${1}"'"}' "$IFTTT_MAKER" > /dev/null
  fi
  return 0
}

# Initial database download and file discovery
if [ "${TMPDIR}" ] ; then cd "${TMPDIR}" || (notify_me "Cannot access ${TMPDIR}"; exit 2); fi
if [ ! "${CHANNELS_DB}" ] ; then
  if [ "${HOST}" ] ; then 
    CHANNELS_DB="http://${HOST}/dvr/files"
  else
    CHANNELS_DB="http://localhost:8089/dvr/files"
  fi
fi

# Set some default behaviours
[ ! "${VERBOSE}" ] && VERBOSE=1
[ ! "${COMTRIM}" ] && CHAPTERS=1 && COMTRIM=0
[ ! "${CHAPTERS}" ] && [ "${COMTRIM}" -eq 0 ] && CHAPTERS=1
[ ! "${DEBUG}" ] && DEBUG=0
[ ! "${LANG}" ] && LANG="en-US"


## ESTABLISH PRESENCE OF CLI INTERFACES
# Essential...
program="HandBrakeCLI"; if [ ! -f "${HANDBRAKE_CLI}" ]; then HANDBRAKE_CLI="$(which ${program})" || (notify_me "${program} missing"; exit 9); fi
program="curl"; if [ ! -f "${CURL_CLI}" ]; then CURL_CLI="$(which ${program})" || (notify_me "${program} missing"; exit 9); fi
program="jq"; if [ ! -f "${JQ_CLI}" ]; then JQ_CLI="$(which ${program})" || (notify_me "${program} missing"; exit 9); fi

# Optional
if [ "$CHAPTERS" == 1 ]; then
  program="MP4Box"; if [ ! -f "${MP4BOX_CLI}" ]; then MP4BOX_CLI="$(which ${program})" || (notify_me "${program} missing"; exit 9); fi
fi
if [ "$COMTRIM" == 1 ]; then
  program="ffmpeg"; if [ ! -f "${FFMPEG_CLI}" ]; then FFMPEG_CLI="$(which ${program})" || (notify_me "${program} missing"; exit 9); fi
fi
if [ "$AP_CLI" ]; then
  program="AtomicParsley"; if [ ! -f "${AP_CLI}" ]; then AP_CLI="$(which ${program})" || (notify_me "${program} missing"; exit 9); fi
  regex="(.*)version: (.*) (.*)"
  apvers=$(${AP_CLI} | grep version)
  if [[ "${apvers}" =~ ${regex} ]]; then
    [ "$(ver "${BASH_REMATCH[2]}")" -lt "$(ver "0.9.6")" ] && ( echo "Old version of AtomicParsley detected.  Upgrade."; AP_CLI="" )
  else
    notify_me "Cannot establish version of AtomicParsley.  Upgrade."
    AP_CLI=""
  fi
fi
[ "${DEBUG}" -eq 1 ] && echo "All required programs found."

# Read Source Directory from API
sourcepath="$("${CURL_CLI}" -s "${CHANNELS_DB}"/../../dvr | jq -r '.path')"
[ ! "${sourcepath}" ] && ( notify_me "Cannot access Channels API"; exit 14 )
[ ! "${SOURCE_DIR}" ] && SOURCE_DIR="${sourcepath}"
[ "${DEBUG}" -eq 1 ] && ( echo "Curl: ${CURL_CLI}"; echo  "Source path: ${sourcepath}"; echo "SOURCE_DIR: ${SOURCE_DIR}" )
[ ! -d "${SOURCE_DIR}" ] && [ "${VERBOSE}" -ne 0 ] && echo "Cannot read ${sourcepath} directly.  Functioning remotely via API only."

# Get filename
"${CURL_CLI}" -s "${CHANNELS_DB}/${1}" > "${1}.json"
"${CURL_CLI}" -s "${CHANNELS_DB}/${1}/mediainfo.json" > "${1}_mi.json"
ifile="${SOURCE_DIR}/$(${JQ_CLI} -r '.Path' < "${1}.json")"
[ "${DEBUG}" -eq 1 ] && echo "Source location: ${ifile}"

fname=$(basename "${ifile}")	    # Name of original file
bname="${fname%.*}"		    # Name of original file minus extension

# Check if deleted
if [ "$(${JQ_CLI} -r '.Deleted' < "${1}.json")" == "true" ]; then notify_me "${bname} already deleted."; return 3; fi

# Identify type of file based on filename
regex="([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4})\ (.*)\ ([0-9]{4}-[0-9]{2}-[0-9]{2})\ [sS]([0-9]{2})[eE]([0-9]{2})\ (.*)\.(mp4|mkv|mpg|ts|m4v)"
if [[ "${fname}" =~ ${regex} ]]; then
  rectype="TV Show"
  #recdate="${BASH_REMATCH[1]}"
  showname="${BASH_REMATCH[2]}"
  #transdate="${BASH_REMATCH[3]}"
  season="${BASH_REMATCH[4]}"
  episode="${BASH_REMATCH[5]}"
  title="${BASH_REMATCH[6]}"
  extension="${BASH_REMATCH[7]}"
  [ "$(type "showname_clean" | grep -s function)" ] && showname="$(showname_clean "${showname}")"
  bname="${showname} - S${season}E${episode} - ${title}"
fi
regex="(.*)\ \(([0-9]{4})\)\ ([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4})\.(mp4|mkv|mpg|ts|m4v)"
if [[ "${fname}" =~ ${regex} ]]; then
  rectype="Movie"
  showname="${BASH_REMATCH[1]}"
  year="${BASH_REMATCH[2]}"
  #recdate="${BASH_REMATCH[3]}"
  extension="${BASH_REMATCH[4]}"
  bname="${showname} (${year})"
fi
if [ ! "${rectype}" ]; then
  echo "Cannot identify type of file based on filename."
fi

# Determine if file already available on local system.  Download via API if not.
fname="${1}.${extension}"
[ -f "${ifile}" ] && ln -s "${ifile}" "${fname}"
[ ! -f "${fname}" ] && "${CURL_CLI}" -s -o "${fname}" "${CHANNELS_DB}/${1}/stream.${extension}"
[ ! -f "${fname}" ] && ( notify_me "Cannot find ${bname}"; exit 4 )

# Looks to see if we have direct access to comskip logs
comskipped="$(jq -r 'select (( .Commercials[0] )) | {ID} | join (" ")' < tmp.json )"
[ ! "${comskipped}" ] && notify_me "${bname} not comskippped."

# Commercial trimming (optional)
if [ "${COMTRIM}" -eq 1 ] && [ "${comskipped}" ]; then
  # Perform the actual file splitting
  curl -s "${CHANNELS_DB}/${1}/comskip.ffsplit" > "${1}.ffsplit"; ffsplit="${1}.ffsplit"
  
  if [ -f "${ffsplit}" ]; then
    [ "$VERBOSE" -ne 0 ] && echo "Attempting to trim input file"
    while read -r split <&3; do
      "${FFMPEG_CLI}" -i "${fname}" "${split}"
    done 3< "${ffsplit}" 
    for i in segment*; do echo "file \'${i}\'" >> "${bname}.lis" ; done
    "${FFMPEG_CLI}" -f concat -i "${bname}.lis" -c copy "${1}_cut.${extension}"
    rm -f segment*
    ( [ -f "${1}_cut.${extension}" ] && mv -f "${1}_cut.${extension}" "${fname}" ) || notify_me "${bname} comtrim failed"
  fi
fi


# THE ACTUAL TRANSCODING PART
echo "Attempting to transcode ${fname} ..."
if [ "${VERBOSE}" ] ; then EXTRAS+=(-v "${VERBOSE}") ; fi
if [ "$MAXSIZE" ]; then EXTRAS+=(--maxHeight "$MAXSIZE" --maxWidth $((MAXSIZE * 16 / 9))); fi
if [ "${ALLOW_EAC3}" ]; then [ "${ALLOW_EAC3}" -eq 1 ] && EXTRAS+=(-E "ffaac,copy" --audio-copy-mask "eac3,ac3,aac"); fi 
if [ "${PRESET}" ] ; then EXTRAS+=(-Z "${PRESET}"); else EXTRAS+=(-Z "AppleTV 3"); fi
if [ "${SPEED}" ] ; then EXTRAS+=(--encoder-preset "${SPEED}"); else EXTRAS+=(--encoder-preset "veryfast"); fi
if [ "$VERBOSE" -ne 0 ] ; then
  for arg in "${HANDBRAKE_CLI}" -i "${fname}" -o "${1}.m4v" "${EXTRAS[@]}"; do
    if [[ $arg =~ \  ]]; then arg=\"$arg\"; fi
    echo -n "$arg "
  done; echo
fi

"${HANDBRAKE_CLI}" -i "${fname}" -o "${1}.m4v" "${EXTRAS[@]}" || ( notify_me "${bname} transcode failed." ; exit 6 )
rm -f "${fname}" # Delete tmp input file/link  

# COMMERCIAL MARKING
# Instead of trimming commercials, simply mark breaks as chapters
if [ "${CHAPTERS}" -eq 1 ] && [ "${comskipped}" ] ; then
  curl -s "${CHANNELS_DB}/${1}/comskip.vdr" > "${1}.vdr"; vdr="${1}.vdr"  
  "${MP4BOX_CLI}" -lang "${LANG}" -chap "${vdr}" "${1}.m4v" || notify_me "${bname} chapter marking failed"
fi


# TAGGING
if [ "$AP_CLI" ]; then
  # Build some tags
  if [ "${rectype}" == "TV Show" ]; then
    AP_OPTS=(--title "${title}" --TVShowName "${showname}" --TVEpisode "${season}${episode}" --TVEpisodeNum "$episode" --TVSeason "$season")
    AP_OPTS+=(--genre "TV Shows" --stik "TV Show") 
  fi
  if [ "${rectype}" == "Movie" ]; then
    AP_OPTS=(--title "${showname}" --genre "Movies" --stik "Movie")
  fi
  # Basic tags
  AP_OPTS+=(--geID "$(${JQ_CLI} -r '.Airing.Genres[0]' < "${1}.json")")
  AP_OPTS+=(--contentRating "$(${JQ_CLI} -r '.Airing.Raw.ratings[0].code' < "${1}.json")")
  AP_OPTS+=(--description "$(${JQ_CLI} -r '.Airing.Raw.program.shortDescription' < "${1}.json")")
  AP_OPTS+=(--longdesc "$(${JQ_CLI} -r '.Airing.Raw.program.longDescription' < "${1}.json")")
  AP_OPTS+=(--year "$(${JQ_CLI} -r '.Airing.Raw.program.releaseYear' < "${1}.json")")
  AP_OPTS+=(--cnid "$(${JQ_CLI} -r '.Airing.ProgramID' < "${1}.json" | cut -c3-)")
  tmsID="$(${JQ_CLI} -r '.Airing.ProgramID' < "${1}.json" | cut -c1-10)"
  show="$(${JQ_CLI} -r '.Airing.Title' < "${1}.json")"
  #type="$(${JQ_CLI} -r '.Airing.Raw.program.entityType' < "${1}.json")"
  #subtype="$(${JQ_CLI} -r '.Airing.Raw.program.subType' < "${1}.json")"
   
  # HD tags
  hdvideo=0
  #width="$(${JQ_CLI} '.streams[] | select(.codec_type == "video") | .width' < "${1}_mi.json")"
  height="$(${JQ_CLI} '.streams[] | select(.codec_type == "video") | .height' < "${1}_mi.json")"
  if [ "$height" -gt 700 ]; then hdvideo=1; fi
  if [ "$height" -gt 1000 ]; then hdvideo=2; fi
  [ "${hdvideo}" ] && AP_OPTS+=(--hdvideo $hdvideo)
  
  # Image tags
  imageloc="$(${JQ_CLI} -r '.Airing.Image' < "${1}.json")"
  artwork="${1}.jpg"
  "${CURL_CLI}" -s -o "${artwork}" -O "${imageloc}"
  [ -f "${artwork}" ] && AP_OPTS+=(--artwork "${artwork}") 
  
  # Network name
  if [ "${TVDB_API}" ] && [ "${rectype}" == "TV Show" ] ; then
    tvdb="https://api.thetvdb.com"
    token=$("${CURL_CLI}" -s -X POST -H "Content-Type: application/json" -d '{"apikey":"'"${TVDB_API}"'"}' ${tvdb}/login | ${JQ_CLI} -r '.token')
    tvdb_opts=(-s -X GET --header "Accept: application/json" --header "Authorization: Bearer $token") 
    showid="$("${CURL_CLI}" "${tvdb_opts[@]}" "${tvdb}/search/series?zap2itId=${tmsID}" | ${JQ_CLI} -r '.data[0].id')"
    if [ "$showid" == null ]; then
      # Add a show name override here
      showid="$("${CURL_CLI}" "${tvdb_opts[@]}" "${tvdb}/search/series?name=${show// /%20}" | ${JQ_CLI} -r '.data[0].id')"
      network="$("${CURL_CLI}" "${tvdb_opts[@]}" "${tvdb}/search/series?name=${show// /%20})" | ${JQ_CLI} -r '.data[0].network')"
    else
      network=$("${CURL_CLI}" "${tvdb_opts[@]}" "${tvdb}/series?id=${showid}" | ${JQ_CLI} '.data[0].network')
    fi
    [ "${network}" ] && AP_OPTS+=(--TVNetwork "${network}")   
  fi
  
  # Command that actually does the tagging!
  if [ "$VERBOSE" -ne 0 ] ; then
    for arg in "${AP_CLI}" "${1}.m4v" "${AP_OPTS[@]}"; do
      if [[ $arg =~ \  ]]; then arg=\"$arg\"; fi
      echo -n "$arg "
    done; echo
  fi
  
  "${AP_CLI}" "${1}.m4v" "${AP_OPTS[@]}" || notify_me "Tagging of ${bname} failed"
fi


# Determine if destination directory exists on local system, and create target folder if so.
# If not, bail. (Alternative approach to return file over GNU parallel protocol T.B.D.)
if [ "${DEST_DIR}" ]; then 
  [ -d "${DEST_DIR}" ] || exit 5
  tdname="${DEST_DIR}/Movies/${showname}"
  [ "${rectype}" == "TV Show" ] && tdname="${DEST_DIR}/TV Shows/${showname}/Season $((season))"
  [ "$(mkdir -p "${tdname}")" ] || ( notify_me "Cannot create ${tdname}."; exit 5 ) 
  if [ ! "$(mv -f "${1}.m4v" "${tdname}/${bname}.m4v")" ] ; then
    [ "${BACKUP_DIR}" ] && ( mv -f "${1}.m4v" "${BACKUP_DIR}/${bname}.m4v" || nofify_me "${bname}.m4v backup failed"; )
    exit 5
  fi
fi
[ "${VERBOSE}" -eq 0 ] || notify_me "${bname} processing complete."

exit 0

# Exit status
# 2: Couldn't access temp directory
# 3: Show no longer exists
# 4: Cannot find input file (but it should exist)
# 5: Transcoded but undeliberable, kept locally
# 9 : Missing critical program
# 14: Cannot access Channels DVR API
