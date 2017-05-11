#!/bin/bash
# (C) Karl Mitchell 2017, GPL: https://www.gnu.org/licenses/gpl-3.0.en.html
# Converts Channels DVR recordings to m4v (h.264) format, for Plex, Kodi, iTunes & iOS m4v
# This script is primarily intended to be run occasionally (e.g. daily), e.g. using launchd or cron job, during quiet time
# It can also be run on specific recordings, can be used locally or remotely to Channels DVR computer, and can distribute jobs remotely, as required.
# An installation script is provided on the GitHub site to automate most of the setup described below.
# Pre-requisites:
#  Curl (for accessing web resources)
#  jq (for processing JSON databases)
#  realpath (part of coreutils)
# Optional pre-requisites:
#  An IFTTT Maker Key for phone status notifications.
#  FFMPEG (a part of channels DVR, so you already have a copy, but you can use your own if you like) for commercial trimming/marking
#  Parallel (GNU software for parallel processing; Can run jobs in parallel across cores, processors or even computers if set up correctly)
#  AtomicParsley (software for writing iTunes tags) >= 0.9.6 recommended
# Unix prerequisites for above packages (use e.g. apt-get/macports), in case you're compiling manually:
#  autoconf automake libtool pkgconfig argtable sdl coreutils curl jq AtomicParsley
# MAC OS: Run with launchd at ~/Library/LaunchAgents/com.getchannels.transcode-plex.plist.  Edit to change when it runs (default = 12:01am daily).
#  Once in place and readable, run
#   sudo launchctl load ${HOME}/Library/LaunchAgents/com.getchannels.transcode-plex.plist
#   sudo launchctl start com.getchannels.transcode-plex
#   chmod 644 ~/Library/LaunchAgents/com.getchannels.transcode-plex.plist
#  If your computer sleeps, be sure to set something to wake it up on time.
# LINUX: Run as a cron or service, e.g. "EDITOR=nedit crontab -e" then add line 1 12 * * * nice /usr/local/bin/channels-transcoder.sh
# Edit default settings below.  These may all be over-ridden from the command line, e.g. channels-transcoder.sh CHAPTERS=1 COMTRIM=0 DAYS=2
#
## FIRST RUN
# The first time you run this script, it will create a database, typically in the same location as the preferences file
# Setting DAYS=N, e.g. DAYS=10, will list all shows older than N days as having been previously transcoded to prevent a massive backlog.
# Setting DAYS=0 will prevent any shows from being backlogged.
# You can force re-initialization of the database by adding CLEAN_DB=1
# Note that if you do not have write access to the existing database, then a new one will be set up and initiated.

## SOME TRICKS
# You can run without comparing with the transcode database and use current directory thus:
#  channels-transcoder.sh 62 63 DEST_DIR="" DAYS=0 TMPDIR="$(pwd)"
# You can deliver to iTunes (only recommended if you have tagging working) rather than to a Plex-compatible structure, thus:
#  ITUNES_AUTO="${HOME}/Music/iTunes/iTunes Media/Automatically Add to iTunes.localized"  
#  channels-transcoder.sh DEST_DIR="" BACKUP_DIR="${ITUNES_AUTO}"
# 

## PREFERENCES FOR SYSTEM CONFIGURATION
# The preferences file is normally called "prefs", and is typically placed in ~/.transcode-plex/prefs or ~/.channels-transcoder/prefs
# Other locations are also searched if not specified, including Library/Application Support/channels-transcoder|transcode-plex
# All of the options set within the preferences file can be over-riden by adding them as command-line arguments:
#   e.g. transcode-plex.sh CHAPTERS=1 COMTRIM=0 DAYS=2
EXECUTABLE="${BASH_SOURCE[0]}"
BN=$(basename "${EXECUTABLE}" .sh)
DIR="${BASH_SOURCE%/*}"
DEBUG=0

# realpath is a handy utility to find the path of a referenced file. 
# It is used sparingly in this code.
# An alias suggested for those that do not have it.
if [ ! "$(which realpath)" ] ; then
  echo "Some functionality of this software will be absent if realpath is not installed."
  echo "On most systems this can be installed as part of the coreutils package"
  echo "Specifically, searching for files based on filename, something that most users do not use, will fail."
  echo "If you have problems finding it, then please set up an alias in ~/.bashrc, ~/.profile (or your system equivalent) thus:"
  echo "alias realpath='[[ \$1 = /* ]] && echo \"\$1\" || printf \"%s/\${1#./}\" \${PWD}'"
  echo "This is not guaranteed to work."
  echo "Alternatively, ensure that TRANSCODE_DB is set in prefs, and do not run channels-transcoder.sh and search based on filenames."
fi


## INITIATION OF ARGUMENTS
# Reads initiation variables
if [ $# -gt 0 ] ; then
  for var in "$@"; do
    regex="(.*)=(.*)"
    if [[ "${var}" =~ (.*)=(.*) ]] ; then
      variable=$(echo "$var" | cut -f1 -d=)
      value=$(echo "$var" | cut -f2- -d=)
      eval "${variable}=\"${value}\""
    fi
  done
fi
if [[ ! -d "$DIR" ]]; then DIR="$PWD"; fi

# Finds preferences file, sources it, then sets preferences directory
if [ ! "${SOURCE_PREFS}" ]; then
  for i in "${HOME}/Library/Application Support/${BN}/prefs" "${HOME}/.${BN}/prefs" "${HOME}/.transcode-plex/prefs" \
    "${HOME}/Library/Application Support/transcode-plex/prefs" ; do
    if [ -f "${i}" ]; then SOURCE_PREFS="${i}"; break ; fi
  done
fi

if [ "${SOURCE_PREFS}" ]; then
  # spellcheck source=/dev/null
  [ "${TRANSCODE_DB}" ] || TRANSCODE_DB="$(realpath "$(dirname channels-transcoder.sh)")"/transcode.db  
  [ "$DEBUG" -eq 1 ] && echo "SOURCE_PREFS=${SOURCE_PREFS}"
  source "${SOURCE_PREFS}" || ( echo "Couldn't read SOURCE_PREFS=${SOURCE_PREFS}."; exit 1 )
else
  echo "Cannot find preferences file.  Example at: https://github.com/karllmitchell/Channels-DVR-to-Plex/"
  exit 1
fi

 # Re-reads initation variables to over-ride any global variables set on the command line
if [ $# -gt 0 ] ; then
  for var in "$@"; do
    regex="(.*)=(.*)"
    if [[ "${var}" =~ (.*)=(.*) ]] ; then
      variable=$(echo "$var" | cut -f1 -d=)
      value=$(echo "$var" | cut -f2- -d=)
      eval "${variable}=\"${value}\""
      [ "$DEBUG" -eq 1 ] && echo "${variable}=${value}"
    else
      case $var in
        ''|*[0-9]*) apilist+="${var} " ;;
	*.*) filelist+="${var} " ;;
	*) echo "Cannot interpret argument: ${var}";;
      esac
    fi
  done
fi

[ "${DEBUG}" -eq 1 ] && echo "TRANSCODE_DB=${TRANSCODE_DB}"

## REPORT PROGRESS, OPTIONALLY VIA PHONE NOTIFICATIONS
# Customise if you have an alternative notification system
function notify_me {
  echo "${1}"
  if [ "${IFTTT_MAKER_KEY}" ]; then 
    IFTTT_MAKER="https://maker.ifttt.com/trigger/{TVevent}/with/key/${IFTTT_MAKER_KEY}"
    quiet="--silent"
    [ "${VERBOSE}" -eq 2 ] && quiet="--verbose"
    [ ! "${CURL_CLI}" ] && CURL_CLI="$(which curl)"
    [ ! -f "${CURL_CLI}" ] && CURL_CLI="$(which curl)"
    "${CURL_CLI}" $quiet -X POST -H "Content-Type: application/json" -d '{"value1":"'"${1}"'"}' "$IFTTT_MAKER" > /dev/null
  fi
  return 0
}


## CREATE AND GO TO A TEMPORARY WORKING DIRECTORY
cwd=$(pwd)
[ "${WORKING_DIR}" ] || WORKING_DIR="/tmp"
[ "${TMP_PREFIX}" ] || TMP_PREFIX="transcode"
TMPDIR=$(mktemp -d "${WORKING_DIR}/${TMP_PREFIX}.XXXXXXXX") || exit 2
cd "${TMPDIR}" || ( notify_me "Cannot access ${WORKING_DIR}"; exit 2 )
[ "$VERBOSE" -ne 0 ] &&  echo "Working directory: ${TMPDIR}" 


## CREATE FUNCTION TO CLEAN UP AFTER YOURSELF
##
function finish {
  cd "${cwd}" || ( cd && echo "Original directory gone" ) 
  [ "$DEBUG" -eq 1 ] || [ "${TMPDIR}" == "${cwd}" ] || rm -rf "${TMPDIR}" || echo "Okay, that's strange: Temp directory missing"
}
trap finish EXIT

# A useful little tool for evaluating version numbers
function ver {
  printf "%03d%03d%03d%03d" $(echo "$1" | tr '.' ' ' | head -n 4 )
}


### ESTABLISH PRESENCE OF API AND CLI INTERFACES

# Essential command line programs
[ -f "${CURL_CLI}" ] || CURL_CLI="$(which curl)" || (notify_me "curl missing"; exit 9)
[ -f "${JQ_CLI}" ] || JQ_CLI="$(which jq)" || (notify_me "jq missing"; exit 9)

# Determine appropriate API web address
if [ ! "${HOST}" ]; then HOST="localhost:8089"; fi
regex="(.*):(.*)"
if [[ "${HOST}" =~ ${regex} ]]; then HOST="${BASH_REMATCH[1]}"; PORT="${BASH_REMATCH[2]}"; else PORT=8089; fi
DATA_DIR="$(curl -s "http://${HOST}:${PORT}/system" | jq -r '.pwd')"
[ -d "${DATA_DIR}" ] ||  (notify_me "Cannot find API at http://${HOST}:${PORT}/"; exit 14)  # Check for presence of Channels DVR API
[ "${VERBOSE}" -ne 0 ] && echo "Channels DVR API Interface Found"
[ "${SOURCE_DIR}" ] || SOURCE_DIR=$(curl -s "http://${HOST}:${PORT}/dvr" | jq -r '.path')  # Read Source Directory from API
[ ! -d "${SOURCE_DIR}" ] && SOURCE_DIR="" && [ "${VERBOSE}" -ne 0 ] && echo "Cannot read Channels source directory.  Functioning remotely via API only."
CHANNELS_DB="http://${HOST}:${PORT}/dvr/files"

# Confirm if operation via Parallel is being used and quit if it's not present.
[ ! "${PARALLEL_CLI}" ] || [ -f "${PARALLEL_CLI}" ] || PARALLEL_CLI="$(which parallel)" || (notify_me "parallel missing"; exit 9)

# Additional command-line programs for transcode function, only checked if not using remote execution with GNU parallel
if [ ! "${PARALLEL_CLI}" ]; then
  [ -f "${FFMPEG_CLI}" ] || FFMPEG_CLI="$(dirname "${DATA_DIR}")/latest/ffmpeg" && [ -f "${FFMPEG_CLI}" ] || (notify_me "ffmpeg missing"; exit 9)
  if [ "${AP_CLI}" ]; then
    [ -f "${AP_CLI}" ] || AP_CLI="$(which AtomicParsley)" || (notify_me "AtomicParsley missing"; exit 9)
    regex="(.*)version: (.*) (.*)"
    apvers=$("${AP_CLI}" | grep version)
    if [[ "${apvers}" =~ ${regex} ]]; then
      [ "$(ver "${BASH_REMATCH[2]}")" -lt "$(ver "0.9.6")" ] && echo "Old version of AtomicParsley detected.  If tagging fails, upgrade recommended." && AP_OLD=1
    else
      echo "Cannot determine version of AtomicParsley. If tagging fails, upgrade recommended."
    fi
  fi
fi

[ "${DEBUG}" -eq 1 ] && echo "All required programs found."
   


## CHECK FOR AND INITIATE TRANSCODE DATABASE IF NECESSARY
if [ ! -f "${TRANSCODE_DB}" ] || [ "${CLEAR_DB}" -eq 1 ] ; then
  [ "${DAYS}" ] || DAYS=0
  if [ "$(uname)" == "Darwin" ]; then since=$(date -v-${DAYS}d +%FT%H:%M); else since=$(date -d "$(date) - ${DAYS} days" +%FT%H:%M); fi
  [ "${DEBUG}" -eq 1 ] && echo "(Re-)initialising database with recordings up to ${since}.  Using ${CURL_CLI} and ${JQ_CLI}."
  "${CURL_CLI}" -s "${CHANNELS_DB}" | "${JQ_CLI}" -r '.[] | select ((.Airing.Raw.endTime < "'"$since"'")) | {ID} | join(" ") ' > "${TRANSCODE_DB}"
  notify_me "Transcode database (re-)initialised at ${TRANSCODE_DB}"
fi
if [ ! -w "${TRANSCODE_DB}" ] ; then
  notify_me "Cannot write to ${TRANSCODE_DB}.  I give up!"
  exit 13
fi


# FUNCTION TO USE ATOMIC PARSLEY FOR TAGGING, ACCESSING CHANNELS_DB
function ap_tagger {
  # $1 is the Channels DVR ID, $2 is the output format height
  # Existence of ${1}.json and ${1}.m4v are assumed
  # Right now this over-writes many of the tags from FFMPEG, largely for the sake of portability of the function.
  
  # TAGGING
  subtype="$("${JQ_CLI}" -r '.Airing.Raw.program.subtype' < "${1}.json")"  # Is Feature Film or part of Series?
   
  # Build some tags
  AP_OPTS=()

  if [ "${subtype}" == "Series" ]; then
    AP_OPTS+=(--genre "TV Shows" --stik "TV Show")
    showname="$(${JQ_CLI} -r '.Airing.Title' < "${1}.json")"
    [ "$(type "showname_clean" | grep -s function)" ] && showname="$(showname_clean "${showname}")"
    AP_OPTS+=(--TVShowName "${showname}")
    AP_OPTS+=(--title "$(${JQ_CLI} -r '.Airing.EpisodeTitle' < "${1}.json")")
    season="$(printf "%.02d" "$(jq -r '.Airing.SeasonNumber' < "${1}.json")")"
    episode="$(printf "%.02d" "$(jq -r '.Airing.EpisodeNumber' < "${1}.json")")"
    AP_OPTS+=(--TVEpisode "${season}${episode}" --TVEpisodeNum "${episode}" --TVSeason "${season}")   
  fi
  if [ "${subtype}" == "Feature Film" ]; then
    AP_OPTS+=(--genre "Movies" --stik "Movie")
    AP_OPTS+=(--title "$(${JQ_CLI} -r '.title' < "${1}.json")")
  fi
  
  AP_OPTS+=(--geID "$(${JQ_CLI} -r '.Airing.Genres[0]' < "${1}.json")")
  AP_OPTS+=(--contentRating "$(${JQ_CLI} -r '.Airing.Raw.ratings[0].code' < "${1}.json")")
  AP_OPTS+=(--year "$(${JQ_CLI} -r '.Airing.Raw.program.releaseYear' < "${1}.json")")
  AP_OPTS+=(--cnID "$(${JQ_CLI} -r '.Airing.ProgramID' < "${1}.json" | cut -c3-)")
  
  # HD tags - deprecated as ffmpeg now handles this, allowing older version of atomicparsley to be used.
  hdvideo=0 && [ "$2" -gt 700 ] && hdvideo=1 && [ "$2" -gt 1000 ] && hdvideo=2
  [ ! ${AP_OLD} ] && AP_OPTS+=(--hdvideo "$hdvideo")
  
  # Image tags
  imageloc="$(${JQ_CLI} -r '.Airing.Image' < "${1}.json")"
  artwork="${1}.jpg"
  "${CURL_CLI}" -s -o "${artwork}" -O "${imageloc}"
  [ -f "${artwork}" ] && AP_OPTS+=(--artwork "${artwork}") 
  
  # Network name
  channel="$(${JQ_CLI} -r '.Airing.Channel' < "${1}.json")"
  network="$("${CURL_CLI}" -s "${CHANNELS_DB}/../guide/channels" | "${JQ_CLI}" -r '.[] | select(.Number=="'"$channel"'") | .Name')" 
  AP_OPTS+=(--TVNetwork "${network}")
  
  # Command that actually does the tagging!
  if [ "$VERBOSE" -ne 0 ] ; then
    for arg in "${AP_CLI}" "${1}.m4v" "${AP_OPTS[@]}"; do
      if [[ $arg =~ \  ]]; then arg=\"$arg\"; fi
      echo -n "$arg "
    done; echo
  fi
  
  "${AP_CLI}" "${1}.m4v" "${AP_OPTS[@]}" || return 1
  return 0
}


function transcode {
  # Re-check required programs in case of remote execution
  if [ "${PARALLEL}" ] ; then
    errtxt="cannot be found on remote system. Critical error. Bailing."
    [ -f "${CURL_CLI}" ] || CURL_CLI="$(which curl)" || (notify_me "curl ${errtxt}"; exit 9)
    [ -f "${JQ_CLI}" ] || JQ_CLI="$(which jq)" || (notify_me "jq ${errtxt}"; exit 9)
    [ -f "${FFMPEG_CLI}" ] || FFMPEG_CLI="$(which ffmpeg)" || (notify_me "ffmpeg ${errtxt}"; exit 9)
    if [ "${AP_CLI}" ]; then
      [ -f "${AP_CLI}" ] || AP_CLI=$(which AtomicParsley) || (notify_me "AtomicParsley ${errtxt}"; exit 9)
      regex="(.*)version: (.*) (.*)"
      apvers=$("${AP_CLI}" | grep version)
      if [[ "${apvers}" =~ ${regex} ]]; then
        [ "$(ver "${BASH_REMATCH[2]}")" -lt "$(ver "0.9.6")" ] && notify_me "Old version of AtomicParsley detected. If tagging fails, upgrade recommended."
	exit 9
      else
        notify_me "Cannot determine version of AtomicParsley. If tagging fails, upgrade recommended"
      fi
    fi
  fi
  
  # Get filename
  "${CURL_CLI}" -s "${CHANNELS_DB}/${1}" > "${1}.json"
  "${CURL_CLI}" -s "${CHANNELS_DB}/${1}/mediainfo.json" > "${1}_mi.json"
  
  ifile="${SOURCE_DIR}/$(${JQ_CLI} -r '.Path' < "${1}.json")"
  [ "${DEBUG}" -eq 1 ] && echo "Source location: ${ifile}"
  fname=$(basename "${ifile}")	    # Name of original file
  bname="${fname%.*}"		    # Name of original file minus extension

  # Check if deleted
  [ "$(${JQ_CLI} -r '.Deleted' < "${1}.json")" == "true" ] && ( echo "${bname} already deleted."; return 3 )
  
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
  [ ! "${rectype}" ] && echo "Cannot identify type of file based on filename."

  # Determine if input file already available on local system.  Download via API if not.
  fname="${1}.${extension}"
  [ -f "${ifile}" ] && ln -s "${ifile}" "${fname}"
  [ ! -f "${fname}" ] && "${CURL_CLI}" -s -o "${fname}" "${CHANNELS_DB}/${1}/stream.${extension}"
  [ ! -f "${fname}" ] && ( notify_me "Cannot find ${bname}"; return 4 )

  # Check to see if file exists at destination ...
  if [ "${DEST_DIR}" ]; then 
    tdname="${DEST_DIR}/Movies/${showname}"
    [ "${rectype}" == "TV Show" ] && tdname="${DEST_DIR}/TV Shows/${showname}/Season $((10#${season}))"
    if [ -f "${tdname}/${bname}.m4v" ]; then
      if [ "${OVERWRITE}" -ne 1 ]; then
        echo "${tdname}/${bname}.m4v already exists at destination.  OVERWRITE=1 to ignore."
        return 1
      else
        echo "${tdname}/${bname}.m4v already exists at destination.  Overwriting."
      fi 
    fi
  else
    echo "Functionining in local-mode only.  Will not deliver to Plex or Plex-like file structure."
  fi

  # ... or is being created to in parallel
  [ "${TMP_PREFIX}" ] && [ "$(lsof 2>&1 | grep -s "${1}.m4v" | grep "ffmpeg" | grep "${TMP_PREFIX}")" ] && notify_me "${bname} transcoding already underway" && return 1

  # Looks to see if we have direct access to comskip logs
  comskipped="$(jq -r 'select (( .Commercials[0] )) | {ID} | join (" ")' < "${1}.json" )"
  
  
  # COMMERCIAL TRIMMING (optional)
  [ "${comskipped}" -ne "${1}" ] && [ "${COMTRIM}" -eq 1 ] && notify_me "${bname}: Cannot be comtrimmed due to lack of comskip results"
  if [ "${COMTRIM}" -eq 1 ] && [ "${comskipped}" -eq "${1}" ]; then
    # Perform the actual file splitting
    curl -s "${CHANNELS_DB}/${1}/comskip.ffsplit" > "${1}.ffsplit"; ffsplit="${1}.ffsplit"
    [ "$VERBOSE" -ne 0 ] && echo "Attempting to trim input file"
    while read -r split <&3; do
      "${FFMPEG_CLI}" -i "${fname}" "${split}" || ctfail=1
    done 3< "${ffsplit}" 
    for i in segment*; do echo "file \'${i}\'" >> "${bname}.lis" ; done   
    [ $ctfail -eq 1 ] || "${FFMPEG_CLI}" -f concat -i "${bname}.lis" -c copy "${1}_cut.${extension}" || ctfail=1
    [ $ctfail -eq 1 ] || mv -f "${1}_cut.${extension}" "${fname}" || ctfail=1
    [ $ctfail -eq 1 ] && notify_me "${bname} comtrim failed" 
    rm -f segment* "${bname}.lis"
  fi


  # THE TRANSCODING PART
  echo "Attempting to transcode ${fname} ..." 
  
  # Determine output video size 
  height="$(${JQ_CLI} '.streams[] | select(.codec_type == "video") | .height' < "${1}_mi.json")"
  ht=$(( height < MAXSIZE ? height : MAXSIZE ))
  hdvideo=0 && [ "$ht" -gt 700 ] && hdvideo=1 && [ "$ht" -gt 1000 ] && hdvideo=2
  
  # Tag with metadata
  echo ";FFMETADATA1" > "${1}.ffmeta"
  echo hd_video=${hdvideo} >> "${1}.ffmeta"
  if [ "${rectype}" == "Movie" ]; then
    echo media_type=9 >> "${1}.ffmeta"
    echo title=${showname} >> "${1}.ffmeta"
    echo date=${year} >> "${1}.ffmeta"
  fi
  if [ "${rectype}" == "TV Show" ]; then
    echo media_type=10 >> "${1}.ffmeta"
    echo title=${title} >> "${1}.ffmeta"
    echo show=${showname} >> "${1}.ffmeta"
    echo episode_id=${episode} >> "${1}.ffmeta"
    echo season_number=${season} >> "${1}.ffmeta"
    channel="$(${JQ_CLI} -r '.Airing.Channel' < "${1}.json")"
    network="$("${CURL_CLI}" -s "${CHANNELS_DB}/../guide/channels" | "${JQ_CLI}" -r '.[] | select(.Number=="'"$channel"'") | .Name')" 
    echo network=${network} >> "${1}.ffmeta"
  fi
  echo comment="$(${JQ_CLI} -r '.Airing.Raw.program.shortDescription' < "${1}.json")" >> "${1}.ffmeta"
  echo synopsis="$(${JQ_CLI} -r '.Airing.Raw.program.longDescription' < "${1}.json")" >> "${1}.ffmeta"

  # Add commercial markers if available
  [ "${CHAPTERS}" -eq 1 ] && [ "${comskipped}" -eq "${1}" ] && curl -s "${CHANNELS_DB}/${1}/comskip.ffmeta" | grep -v FFMETADATA >> "${1}.ffmeta"
  FFMPEG_OPTS+=(-i "${1}.ffmeta" -map_metadata 1)
  
  # Add album artwork if available: placeholder, as feature is currently unsupported by ffmpeg, although is a requested feature)
  # For now, you'll need AtomicParsley for this.
  
  #"${CURL_CLI}" -o ${1}.jpg "$(${JQ_CLI} -r '.Airing.Image' < "${1}.json")"
  #[ -s "${1}.ffmeta" ] 
  #[ -s "${1}.jpg" ] && FFMPEG_OPTS+=(-i "${1}.jpg" )
  
  # Video stream
  FFMPEG_OPTS+=(-map 0:0 -c:v libx264)                                                              # Specify video stream
  [ "$MAXSIZE" ] && [ "$MAXSIZE" -lt "$height" ] && height=${MAXSIZE} && FFMPEG_OPTS+=(-vf "scale=-1:${height}") # Limit width and height of video stream
  [ "${QUALITY}" ] || QUALITY=21                                                                    # Set default quality level (-crf flag for x264/ffmpeg)
  [ "${SPEED}" ] || SPEED="veryfast"                                                                # Set default speed level (-preset flag for x264/ffmpeg)
  [ "$height" -lt 1000 ] && QUALITY=$(( QUALITY - 1 )) && [ "$height" -lt 700 ] && QUALITY=$(( QUALITY - 1 )) && [ "$height" -lt 500 ] && QUALITY=$(( QUALITY - 1 ))
  QUALITY=$(( QUALITY > 18 ? QUALITY : 18 ))                                                        # Adjust quality sensibly   
  FFMPEG_OPTS+=(-preset "${SPEED}" -crf "${QUALITY}" -profile:v high -level 4.0)                    # Video stream encoding options
  
  # Audio streams
  FFMPEG_OPTS+=(-map 0:1 -c:a:0 aac -b:a:0 160k)                                                    # Specify first audio stream
  FFMPEG_OPTS+=(-map 0:2 -c:a:1 copy)                                                               # Specify second audio stream 
  FFMPEG_OPTS+=(-movflags faststart)                                                                # Optimize for streaming
  if [ "$VERBOSE" -ne 0 ] ; then
    for arg in "${FFMPEG_CLI}" -hide_banner -i "${fname}" "${FFMPEG_OPTS[@]}" "${1}.mp4"; do
      if [[ $arg =~ \  ]]; then arg=\"$arg\"; fi
      echo -n "$arg "
    done; echo
  fi
  
  # The actual transcoding command!  Requires Channels DVR >= 2017.04.13.0150
  "${FFMPEG_CLI}" -hide_banner -i "${fname}" "${FFMPEG_OPTS[@]}" "${1}.m4v" || ( notify_me "${bname} transcode failed." ; return 6 )
  rm -f "${fname}" # Delete tmp input file/link  


  # TAG THE FILE FOR ITUNES
  # This adds episode artwork, content rating, production date and a fake cnID tag which effectively enables production of SD-HD files if desired
  [ -f "${1}.m4v" ] && [ "${AP_CLI}" ] && ap_tagger "${1}" "${height}" || ( notify_me "Tagging of ${bname} failed")


  # CLEAN UP AND DELIVER
  # Clean up some files
  [ "${DEBUG}" -ne 1 ] && rm -f "${1}.json" "${1}_mi.json" "${1}.jpg" "${1}.vdr" "${1}.ffsplit" "${1}.mpg" "${1}.ts" "${1}-temp-*.m4v"
  
  # Determine if destination directory exists on local system, and create target folder if so.
  # If not, bail. (Alternative approach to return file over GNU parallel protocol T.B.D.)
  if [ "${DEST_DIR}" ] && [ -d "${DEST_DIR}" ] && mkdir -p "${tdname}" && mv -f "${1}.m4v" "${tdname}/${bname}.m4v"; then
    notify_me "${bname}.m4v delivery succeeded."
  else
    msg="${bname}.m4v failed to write to ${tdname}/."
    [ -d "${DEST_DIR}" ] || msg+=" Specific desination directory does not exist."   
    if [ "${BACKUP_DIR}" ]; then
      mv -f "${1}.m4v" "${BACKUP_DIR}/${bname}.m4v" && msg+=" File sent to backup directory." || msg+=" File backup failed."
    fi
    notify_me "${msg}"
    return 5
  fi
  return 0
}

## WAIT UNTIL SYSTEM IS NOT BUSY THEN CLEAN UP DEAD JOBS AND TRANSCODE DATABASE
#

# Wait until the system is done with recording, commercial skipping and transcoding
[ "${BUSY_WAIT}" ] || BUSY_WAIT=1  # Set Default behaviour
transcode_jobs="$(pgrep -fa "/bin/bash channels-transcoder.sh" | grep -vw $$ | grep -c bash)"       # Check for other transcoding jobs
channels_busy="$(curl -s "${CHANNELS_DB}/../../dvr" | jq '.busy')"         # Check to see if Channels DVR is busy

# Loop until no transcoding jobs, channels is no longer busy, or timeout.  Default is about a day.
if [ "${BUSY_WAIT}" -eq 1 ] && ( [ "${channels_busy}" == true ] || [ "${transcode_jobs}" -ge 1 ] ) ; then  
  [ "${TIMEOUT}" ] || TIMEOUT=82800
  delay="${TIMEOUT} seconds" ; [ "${TIMEOUT}" -ge 60 ] && delay="$((TIMEOUT/60)) minutes" ; [ "${TIMEOUT}" -ge 3600 ] && delay="$((TIMEOUT/3600)) hours"
  TIMER=0
  
  [ "${transcode_jobs}" -gt 1 ] && ( notify_me "Too many instances of channels-transcode.sh running. Preventing execution." ; exit 10 )
  echo "Waiting ~${delay} until Channels is no longer busy and no transcode jobs exist.  Set BUSY_WAIT=0 to prevent."  

  # Loop until Channels DVR isn't busy and there are no other active transcode jobs.  
  while [ "${channels_busy}" == true ] || [ "${transcode_jobs}" -ge 1 ]; do
    if [ "${TIMER}" -gt "${TIMEOUT}" ]; then notify_me "Instance of channels-transcoder.sh timed out at ${delay}." ; exit 11; fi
    sleep 60; TIMER=$((TIMER+60))
    channels_busy="$(curl -s "${CHANNELS_DB}/../../dvr" | jq '.busy')"     # Check if Channels DVR is busy
    transcode_jobs="$(pgrep -fa "/bin/bash channels-transcoder.sh" | grep -vw $$ | grep -c bash)"   # Check for other transcoding jobs
  done
fi

# Search through temporary directory to find and clean up any stalled jobs from GNU parallel
[ ! "$TMP_PREFIX" ] && TMP_PREFIX="transcode" 
for i in ${WORKING_DIR/ /\ }/${TMP_PREFIX}.*/progress.txt; do
  delete_tmp=1
  if [ -f "${i}" ] ; then
    old_tmpdir="$(dirname "${i}")" 
    n="$(grep transcode < "${i}" | awk '$7 == 0 || $7 == 1 || $7 == 3 {print $10}')"
    for j in $n; do [ -f "${old_tmpdir}/${i}.m4v" ] && delete_tmp=0 || echo "${j}" >> "${TRANSCODE_DB}"; done
    if [ ${delete_tmp} -eq 0 ]; then
      notify_me "Transcoded files exist in ${old_tmpdir}. Please delete or move manually."
    else 
      if rm -rf "${old_tmpdir}"; then notify_me "Cleaned up ${old_tmpdir}"; else notify_me "Couldn't delete ${old_tmpdir}"; fi
    fi 
  fi
done

# Clean up transcode database
uniq < "${TRANSCODE_DB}" | sort -n > "tmp.db" || (notify_me "Could not update transcode.db"; exit 13)
mv -f tmp.db "${TRANSCODE_DB}"


## CREATE LIST OF SHOWS TO BE TRANSCODED.
# If none can be accessed, quit, otherwise report on how many shows to do.
rlist="${TMPDIR}/recordings.list"
jlist="${TMPDIR}/recordings.json"
"${CURL_CLI}" -s "${CHANNELS_DB}" > "${jlist}"

# Add explicitly named files
if [ "${filelist}" ] || [ "${SOURCE_FILE}" ] ; then
  [ "${DAYS}" ] || DAYS=0
  [ "${SOURCE_FILE}" ] && [ "${SOURCE_FILE}" == "$(realpath "${SOURCE_FILE}")" ] && SOURCE_FILE="$(basename "${SOURCE_FILE}")"
  for i in ${filelist} ${SOURCE_FILE}; do
    [ "${i}" == "$(realpath "${i}")" ] && i="$(basename "${i}")"
    "${JQ_CLI}" -r '.[] | select (.Path | contains("'"${i}"'")) | select (.Deleted == false) | select (.Processed == true) | {ID} | join(" ")' < "${jlist}" >> tmp.list
  done
fi

# Add explicitly numbered files
if [ "${apilist}" ] ; then
  for i in ${apilist}; do
    [ "${DAYS}" ] || DAYS=0
    "${JQ_CLI}" -r '.[] | select (.Path) | select(.ID == "'"$i"'") | select (.Deleted == false) | select (.Processed == true) | {ID} | join(" ")' < "${jlist}" >> tmp.list
  done
fi

# Add list of new shows that have not previously been processed
"${JQ_CLI}" -r '.[] | select ((.Airing.Raw.endTime >= "'"$since"'")) | select (.Deleted == false) | select (.Processed == true) | {ID} | join(" ")' \
  < "${jlist}" | grep -Fxv -f "${TRANSCODE_DB}" >> tmp.list

# Clean up list to avoid duplication and set recording order
uniq < tmp.list > "${rlist}"
rm -f tmp.list

# Report how many news shows have been found
count=$(wc -l "${rlist}" | cut -d" " -f1)
if [ "$count" ]; then
  if [ "${count}" -eq 0 ] ; then notify_me "No new shows to transcode"; exit 0 ; fi
  notify_me "Found ${count} new shows to transcode."
else
  notify_me "No new shows to transcode"; exit 0
fi


## RUN THE MAIN LOOP TO ACTIVATE TRANSCODING JOBS
# Optionally via GNU parallel
# To do: Only add shows to transcode database if successful, or remove them if unsuccessful
export MP4BOX_CLI JQ_CLI FFMPEG_CLI CURL_CLI AP_CLI TSNAME \
  PRESET SPEED EXTRAS MAXSIZE ALLOW_EAC3 \
  DEST_DIR SOURCE_DIR BACKUP_DIR CHANNELS_DB TMPDIR OVERWRITE \
  COMTRIM CHAPTERS LANG DELETE_ORIG IFTTT_MAKER_KEY VERBOSE DEBUG AP_OLD
export -f showname_clean notify_me transcode ap_tagger

if [ "$PARALLEL_CLI" ]; then
  if [ "$COMTRIM" == 1 ]; then PARALLEL_OPTS+=(--delay 120); fi
  PARALLEL_OPTS+=(--joblog "progress.txt" --results progress --progress)
  # The following need to be exported to use GNU parallel:
  "${PARALLEL_CLI}" --record-env
  "${PARALLEL_CLI}" --env _ "${PARALLEL_OPTS[@]}" -a "${rlist}" transcode {} 
  while read -r i; do
    exitcode="$(grep "${TSNAME} ${i}" < progress.txt | awk '{print $7}')"
    case $exitcode in
      0) echo "${i}" >> "${TRANSCODE_DB}" ;;
      1) echo "${i}" >> "${TRANSCODE_DB}" ;;
      3) echo "${i}" >> "${TRANSCODE_DB}"; flist+="${i} " ;;
      *) flist+="${i} " ;;
    esac
  done < "${rlist}"
else 
  while read -r i ; do
    transcode "${i}"
    case $? in
      0) echo "${i}" >> "${TRANSCODE_DB}" ;;
      1) echo "${i}" >> "${TRANSCODE_DB}" ;;
      3) echo "${i}" >> "${TRANSCODE_DB}"; flist+="${i} " ;;
      *) flist+="${i} " ;;
    esac
  done < "${rlist}"
fi

if [ "${flist}" ]; then
  notify_me "Transcoding complete.  There were issues with: ${flist}.  See log file for more details."
else
  notify_me "Transcoding completed successfully"
fi

# Exit cleanly
exit 0

## EXIT/RETURN CODES
#0: E/R: All is good
#1: E: Couldn't access SOURCE_PREFS
#2: E/R: Problems accessing TEMPDIR 
#3: R: Input file already deleted 
#4: E: Cannot find input video
#5: E/R: Cannot write to target directory
#6: R: Transcoding failure
#9: E: Unix program missing
#10: E: Too many jobs for another instance.  Quitting.
#13: E: Cannot access TRANSCODE_BD
#14: E: Cannot access API
#15: E: Cannot delete old jobs
