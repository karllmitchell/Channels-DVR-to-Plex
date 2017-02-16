#!/bin/bash
# (C) Karl Mitchell 2017, GPL: https://www.gnu.org/licenses/gpl-3.0.en.html
# Converts Channels DVR recordings to m4v (h.264) format, for Plex, Kodi, iTunes & iOS m4v
# This script is primarily intended to be run occasionally (e.g. daily), e.g. using launchd or cron job, during quiet time
# It can also be run on specific recordings, can be used locally or remotely to Channels DVR computer, and can distribute jobs remotely, as required.
# Pre-requisites:
#  HandBrakeCLI (video transcoding application)
#  Curl (for accessing web resources)
#  jq (for processing JSON databases)
# Optional pre-requisites:
#  MP4Box (part of GPAC, use MacPorts or similar) for marking commercials start/end as chapters
#  An IFTTT Maker Key for phone status notifications.
#  FFMPEG (a part of channels DVR, but you'll need to point to it) for commercial trimming
#  Caffeinate (a mac utility to prevent sleep)
#  Parallel (GNU software for parallel processing; Can run jobs in parallel across cores, processors or even computers if set up correctly)
#  AtomicParsley (software for writing iTunes tags) >= 0.9.6 [Removal of older versions recommended, or it'll try to use them and fail]
# Unix prerequisites for above packages (use e.g. apt-get/macports):
#  autoconf automake libtool pkgconfig argtable sdl coreutils curl ffmpeg realpath jq AtomicParsley
# MAC OS: Run with launchd at /Library/LaunchAgents/com.getchannels.transcode-plex.plist.  Edit to change when it runs (default = 12:01am daily).
#  Once in place and readable, run
#   sudo launchctl load /Library/LaunchAgents/com.getchannels.transcode-plex.plist
#   sudo launchctl start com.getchannels.transcode-plex
#   chmod 644 /Library/LaunchAgents/com.getchannels.transcode-plex.plist
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
# It is used sparingly in this code, and only as a rarely-used backup.
# An alias suggested for those that do have it, but it is unlikely you'll need it.
if [ ! "$(which realpath)" ] ; then
  echo "Some functionality of this software will be absent if realpath is not installed."
  echo "If you have problems, then please set up an alias in /etc/bashrc (or your system equivalent) thus:"
  echo "alias realpath='[[ \$1 = /* ]] && echo \"\$1\" || printf \"%s/\${1#./}\" \${PWD}'"
  echo "Alternatively, ensure that TRANSCODE_DB is set in prefs, and that if SOURCE_FILE used it is done so correctly."
fi


## INITIATION OF ARGUMENTS (LONG, TEDIOUS SECTION)
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
  for i in "${HOME}/.${BN}/prefs" "${HOME}/.transcode-plex/prefs" \
    "${HOME}/Library/Application Support/${BN}/prefs" "${HOME}/Library/Application Support/transcode-plex/prefs" ; do
    if [ -f "${i}" ]; then SOURCE_PREFS="${i}"; break ; fi
  done
fi

if [ "${SOURCE_PREFS}" ]; then
  # spellcheck source=/dev/null
  PREFS_DIR="$(dirname "${SOURCE_PREFS}")"
  PREFS_DIR="$(realpath "${PREFS_DIR}")"
  [ "$DEBUG" -eq 1 ] && echo "SOURCE_PREFS=${SOURCE_PREFS}"
  source "${SOURCE_PREFS}" || ( echo "Couldn't read SOURCE_PREFS=${SOURCE_PREFS}."; exit 1 )
else
  echo "Cannot find preferences file.  Example at: https://github.com/karllmitchell/Channels-DVR-to-Plex/"
  exit 1
fi
[ "${DEBUG}" -eq 1 ] && echo "PREFS_DIR=${PREFS_DIR}"

filelist=""
apilist="" 
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
        ''|*[!0-9]*) apilist+="${var} " ;;
	*.*) filelist+="${var} " ;;
	*) echo "Cannot interpret argument: ${var}";;
      esac
    fi
  done
fi

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
if [ ! "${WORKING_DIR}" ]; then WORKING_DIR="/tmp"; fi
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

# Confirm if operation via Parallel is being used and quit if it's not present.
[ ! "${PARALLEL_CLI}" ] || [ -f "${PARALLEL_CLI}" ] || PARALLEL_CLI="$(which parallel)" || (notify_me "parallel missing"; exit 9)

# Essential command line programs
[ -f "${CURL_CLI}" ] || CURL_CLI="$(which curl)" || (notify_me "curl missing"; exit 9)
[ -f "${JQ_CLI}" ] || JQ_CLI="$(which jq)" || (notify_me "jq missing"; exit 9)

# Prevent sleep on systems with caffeinate
[ ! "${CAFFEINATE_CLI}" ] || [ -f "${CAFFEINATE_CLI}" ] || CAFFEINATE_CLI="$(which caffeinate)" || (notify_me "caffeinate missing"; exit 9)
[ -f "${CAFFEINATE_CLI}" ] && "${CAFFEINATE_CLI}" -s && cpid=$!

# Additional command-line programs for transcode function, only checked if not using remote execution with GNU parallel
if [ ! "${PARALLEL_CLI}" ]; then
  [ -f "${HANDBRAKE_CLI}" ] || HANDBRAKE_CLI="$(which HandBrakeCLI)" || (notify_me "HandBrakeCLI missing"; exit 9)
  [ "${CHAPTERS}" -ne 1 ] || [ -f "${MP4BOX_CLI}" ] || MP4BOX_CLI="$(which MP4Box)" || (notify_me "MP4Box missing"; exit 9)
  [ "${COMTRIM}" -ne 1 ] || [ -f "${FFMPEG_CLI}" ] || FFMPEG_CLI="$(which ffmpeg)" || (notify_me "ffmpeg missing"; exit 9)
  if [ "${AP_CLI}" ]; then
    [ -f "${AP_CLI}" ] || AP_CLI=$(which AtomicParsley) || (notify_me "AtomicParsley missing"; exit 9)
    regex="(.*)version: (.*) (.*)"
    apvers=$("${AP_CLI}" | grep version)
    if [[ "${apvers}" =~ ${regex} ]]; then
      [ "$(ver "${BASH_REMATCH[2]}")" -lt "$(ver "0.9.6")" ] && notify_me "Old version of AtomicParsley detected.  Tagging may fail loudly.  Upgrade recommended."
    else
      notify_me "Cannot determine version of AtomicParsley.  Tagging may fail loudly.  Upgrade recommended."
    fi
  fi
fi

[ "${DEBUG}" -eq 1 ] && echo "All required programs found."
   
  

## TEST FOR PRESENCE OF API INTERFACE (ESSENTIAL)

# Determine appropriate API web address
if [ ! "${HOST}" ]; then HOST="localhost:8089"; fi
regex="(.*):(.*)"
if [[ "${HOST}" =~ ${regex} ]]; then HOST="${BASH_REMATCH[1]}"; PORT="${BASH_REMATCH[2]}"; else PORT=8089; fi
CHANNELS_DB="http://${HOST}:${PORT}/dvr/files"

# Test for presence of API
${CURL_CLI} -sSf "${CHANNELS_DB}" > /dev/null || (notify_me "Cannot find API at ${CHANNELS_DB}"; exit 14)
[ "${VERBOSE}" -ne 0 ] && echo "Channels DVR API Interface Found"

# Read Source Directory from API
if [ ! "${SOURCE_DIR}" ]; then SOURCE_DIR=$(curl -s "${CHANNELS_DB}/../../dvr" | jq -r '.path'); fi
if [ ! -d "${SOURCE_DIR}" ] ; then
  SOURCE_DIR=""
  [ "${VERBOSE}" -ne 0 ] && echo "Cannot read Channels source directory.  Functioning remotely via API only."
fi
        


## CHECK FOR AND INITIATE TRANSCODE DATABASE IF NECESSARY
[ "${TRANSCODE_DB}" ] || TRANSCODE_DB="${PREFS_DIR}/transcode.db"
if [ ! -f "${TRANSCODE_DB}" ] || [ "${CLEAR_DB}" -eq 1 ] ; then
  [ "${DAYS}" ] || DAYS=0
  if [ ! -w "${TRANSCODE_DB}" ] ; then
    notify_me "Cannot write to ${TRANSCODE_DB}, using ${HOME}/${BN}/transcode.db instead"
    TRANSCODE_DB="${HOME}/${BN}/transcode.db"
  fi 
  if [ "$(uname)" == "Darwin" ]; then since=$(date -v-${DAYS}d +%FT%H:%M); else since=$(date -d "$(date) - ${DAYS} days" +%FT%H:%M); fi
  [ "${DEBUG}" -eq 1 ] && echo "Initiating database with recordings up to ${since}.  Using ${CURL_CLI} and ${JQ_CLI}."
  "${CURL_CLI}" -s "${CHANNELS_DB}" | "${JQ_CLI}" -r '.[] | select ((.Airing.Raw.endTime < "'"$since"'")) | {ID} | join(" ") ' > "${TRANSCODE_DB}"
  notify_me "Transcode database initialised at ${TRANSCODE_DB}"
fi
if [ ! -w "${TRANSCODE_DB}" ] ; then
  notify_me "Cannot write to ${TRANSCODE_DB}.  I give up!"
  exit 13
fi

# Search through temporary directory to find and clean up any stalled jobs
[ ! "$TMP_PREFIX" ] && TMP_PREFIX="transcode" 
for i in ${WORKING_DIR/ /\ }/${TMP_PREFIX}.*/progress.txt; do
  if [ -f "${i}" ] ; then
    notify_me "Found incomplete jobs in ${i}. Cleaning."  
    grep transcode < "${i}" | awk '$7 == 0 {print $10}' >> "${TRANSCODE_DB}"
    grep transcode < "${i}" | awk '$7 == 1 {print $10}' >> "${TRANSCODE_DB}"
    
    rm -rf "$(dirname "${i}")" || notify_me "Cannot delete ${i}. Please do so manually."
  fi
done

function transcode {
  # Re-check required programs in case of remote execution
  if [ "${PARALLEL}" ] ; then
    errtxt="cannot be found on remote system. Critical error. Bailing."
    [ -f "${CURL_CLI}" ] || CURL_CLI="$(which curl)" || (notify_me "curl ${errtxt}"; exit 9)
    [ -f "${HANDBRAKE_CLI}" ] || HANDBRAKE_CLI="$(which HandBrakeCLI)" || (notify_me "HandBrakeCLI ${errtxt}"; exit 9)
    [ -f "${JQ_CLI}" ] || JQ_CLI="$(which jq)" || (notify_me "jq ${errtxt}"; exit 9)
    [ "${CHAPTERS}" -ne 1 ] || [ -f "${MP4BOX_CLI}" ] || MP4BOX_CLI="$(which MP4Box)" || (notify_me "MP4Box ${errtxt}"; exit 9)
    [ "${COMTRIM}" -eq 1 ] || [ -f "${FFMPEG_CLI}" ] || FFMPEG_CLI="$(which ffmpeg)" || (notify_me "ffmpeg ${errtxt}"; exit 9)
    [ "${AP_CLI}" ] || [ -f "${AP_CLI}" ] || AP_CLI="$(which AtomicParsley)" || (notify_me "AtomicParsley ${errtxt}"; exit 9)
    if [ "${AP_CLI}" ]; then
      [ -f "${AP_CLI}" ] || AP_CLI=$(which AtomicParsley) || (notify_me "AtomicParsley missing"; exit 9)
      regex="(.*)version: (.*) (.*)"
      apvers=$("${AP_CLI}" | grep version)
      if [[ "${apvers}" =~ ${regex} ]]; then
        [ "$(ver "${BASH_REMATCH[2]}")" -lt "$(ver "0.9.6")" ] && notify_me "Old version of AtomicParsley detected.  Tagging may fail loudly.  Upgrade recommended."
      else
        notify_me "Cannot determine version of AtomicParsley.  Tagging may fail loudly.  Upgrade recommended."
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
    [ "${rectype}" == "TV Show" ] && tdname="${DEST_DIR}/TV Shows/${showname}/Season $((season))"
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
  [ "${TMP_PREFIX}" ] && [ "$(lsof 2>&1 | grep -s "${1}.m4v" | grep "HandBrake" | grep "${TMP_PREFIX}")" ] && notify_me "${bname} transcoding already underway" && return 1

  # Looks to see if we have direct access to comskip logs
  comskipped="$(jq -r 'select (( .Commercials[0] )) | {ID} | join (" ")' < "${1}.json" )"
  
  # COMMERCIAL TRIMMING (optional)
  [ "${comskipped}" -ne "${1}" ] && [ "${COMTRIM}" -eq 1 ] && notify_me "${bname}: Cannot be comtrimmed due to lack of comskip results"
  if [ "${COMTRIM}" -eq 1 ] && [ "${comskipped}" -eq "${1}" ]; then
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

  "${HANDBRAKE_CLI}" -i "${fname}" -o "${1}.m4v" "${EXTRAS[@]}" || ( notify_me "${bname} transcode failed." ; return 6 )
  rm -f "${fname}" # Delete tmp input file/link  

  # COMMERCIAL MARKING (optional)
  # Instead of trimming commercials, simply mark breaks as chapters
  [ "${comskipped}" -ne "${1}" ] && [ "${CHAPTERS}" -eq 1 ] && notify_me "${bname}: Cannot mark chapters due to lack of comskip results"
  if [ "${CHAPTERS}" -eq 1 ] && [ "${comskipped}" -eq "${1}" ] ; then
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
    AP_OPTS+=(--cnID "$(${JQ_CLI} -r '.Airing.ProgramID' < "${1}.json" | cut -c3-)")
    tmsID="$(${JQ_CLI} -r '.Airing.ProgramID' < "${1}.json" | cut -c1-10)"
    show="$(${JQ_CLI} -r '.Airing.Title' < "${1}.json")"
    #type="$(${JQ_CLI} -r '.Airing.Raw.program.entityType' < "${1}.json")"
    #subtype="$(${JQ_CLI} -r '.Airing.Raw.program.subType' < "${1}.json")"
   
    # HD tags
    hdvideo=0
    #width="$(${JQ_CLI} '.streams[] | select(.codec_type == "video") | .width' < "${1}_mi.json")"
    height="$(${JQ_CLI} '.streams[] | select(.codec_type == "video") | .height' < "${1}_mi.json")"
    [ "$height" -gt 700 ] && hdvideo=1
    [ "$height" -gt 1000 ] && hdvideo=2
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
  
    "${AP_CLI}" "${1}.m4v" "${AP_OPTS[@]}" || ( notify_me "Tagging of ${bname} failed")
  fi

  # Clean up some files
  [ "${DEBUG}" -ne 1 ] && rm -f "${1}.json" "${1}_mi.json" "${1}.jpg" "${1}.vdr" "${1}.ffsplit" "${1}.mpg" "${1}.ts"
  
  # Determine if destination directory exists on local system, and create target folder if so.
  # If not, bail. (Alternative approach to return file over GNU parallel protocol T.B.D.)
  if [ "${DEST_DIR}" ] ; then
    [ -d "${DEST_DIR}" ] && mkdir -p "${tdname}"
    ( [ -d "${tdname}" ] && [ "$(mv -f "${1}.m4v" "${tdname}/${bname}.m4v")" ] ) || ( [ "${BACKUP_DIR}" ] && mv -f "${1}.m4v" "${BACKUP_DIR}/${bname}.m4v" )
    [ -f "${tdname}/${bname}.m4v" ] || ( notify_me "${bname}.m4v delivery failed" ; return 5 )
  fi
  
  [ ! "${DEST_DIR}" ] && [ "${BACKUP_DIR}" ] && [ -d "${BACKUP_DIR}" ] && \
    ( mv -f "${1}.m4v" "${BACKUP_DIR}/${bname}.m4v" || ( notify_me "${bname}.m4v delivery failed" ; return 5 ))
  
  return 0
}

## WAIT UNTIL CHANNELS DVR IS QUIET
# Wait until the system is done with recording and commercial skipping
busy=$(curl -s "${CHANNELS_DB}/../../dvr" | jq '.busy')
if [ ! "${BUSY_WAIT}" -eq 0 ] && [ "${busy}" == true ] ; then
  [ "${TIMEOUT}" ] || TIMEOUT=14400
  notify_me "Waiting (max 4 hours) until Channels is no longer busy.  Set BUSY_WAIT=0 to prevent."
  while [ ${SECONDS} -lt ${TIMEOUT} ] || [ "${busy}" == true ] ; do
    wait 60
    busy=$(curl -s "${CHANNELS_DB}/../../dvr" | jq '.busy')
  done
fi


## SEARCH API FOR RECORDINGS IN THE LAST $DAYS NUMBER OF DAYS THAT ARE NOT IN THE TRANSCODE DB.
# If none can be accessed, quit, otherwise report on how many shows to do.
rlist="${TMPDIR}/recordings.list"
jlist="${TMPDIR}/recordings.json"
"${CURL_CLI}" -s "${CHANNELS_DB}" > "${jlist}"

# Add explicitly named files
if [ "${filelist}" ] || [ "${SOURCE_FILE}" ] ; then
  [ "${SOURCE_FILE}" ] && [ "${SOURCE_FILE}" == "$(realpath "${SOURCE_FILE}")" ] && SOURCE_FILE="$(basename "${SOURCE_FILE}")"
  for i in ${filelist} ${SOURCE_FILE}; do
    [ "${i}" == "$(realpath "${i}")" ] && i="$(basename "${i}")"
    "${JQ_CLI}" -r '.[] | select (.Path | contains("'"${i}"'")) | select (.Deleted == false) | select (.Processed == true) | {ID} | join(" ")' < "${jlist}" >> tmp.list
  done
fi

# Add explicitly numbered files
if [ "${apilist}" ] ; then for i in ${apilist}; do
  "${JQ_CLI}" -r '.[] | select (.Path | select(.ID == "'"$i"'") | select (.Deleted == false) | select (.Processed == true) | {ID} | join(" ")' < "${jlist}" >> tmp.list
done
fi

# Add list of new shows that have not previously been processed
"${JQ_CLI}" -r '.[] | select ((.Airing.Raw.endTime >= "'"$since"'")) | select (.Deleted == false) | select (.Processed == true) | {ID} | join(" ")' \
  < "${jlist}" | grep -Fxv -f "${TRANSCODE_DB}" >> tmp.list

# Clean up list to avoid duplication and set recording order
uniq < tmp.list | sort > "${rlist}"
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
export HANDBRAKE_CLI MP4BOX_CLI JQ_CLI FFMPEG_CLI CURL_CLI AP_CLI TSNAME \
  PRESET SPEED EXTRAS MAXSIZE ALLOW_EAC3 \
  DEST_DIR SOURCE_DIR BACKUP_DIR CHANNELS_DB TMPDIR OVERWRITE \
  COMTRIM CHAPTERS LANG DELETE_ORIG IFTTT_MAKER_KEY TVDB_API VERBOSE DEBUG 
export -f showname_clean notify_me transcode

flist=""
if [ "$PARALLEL_CLI" ]; then
  if [ "$COMTRIM" == 1 ]; then PARALLEL_OPTS+=(--delay 120); fi
  PARALLEL_OPTS+=(--joblog "progress.txt" --results progress --progress)
  # The following need to be exported to use GNU parallel:
  "${PARALLEL_CLI}" --record-env
  "${PARALLEL_CLI}" --env _ "${PARALLEL_OPTS[@]}" -a "${rlist}" transcode {} 
  while read -r i; do
    exitcode="$(grep "${TSNAME} ${i}" < progress.txt | awk '{print $7}')"
    if [ "${exitcode}" -ne 0 ] && [ "${exitcode}" -ne 1 ]; then
      flist+="${i} "
    else
      echo "${i}" >> "${TRANSCODE_DB}"
    fi
  done < "${rlist}"
else 
  while read -r i ; do
    exitcode=$(transcode "${i}")
    if [ "${exitcode}" -ne 0 ] && [ "${exitcode}" -ne 1 ]; then
      flist+="${i} "
    else
      echo "${i}" >> "${TRANSCODE_DB}"
    fi
  done < "${rlist}"
fi


if [ "${flist}" ]; then
  notify_me "Transcoding complete.  There were issues with: ${flist}.  See log file for more details."
else
  notify_me "Transcoding completed successfully"
fi

if [ -f "${CAFFEINATE_CLI}" ]; then kill -9 ${cpid} ; fi

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
#13: E: Cannot access TRANSCODE_BD
#14: E: Cannot access API
#15: E: Cannot delete old jobs
