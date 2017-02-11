#!/bin/bash
# (C) Karl Mitchell 2017, GPL: https://www.gnu.org/licenses/gpl-3.0.en.html
# Best run once daily, e.g. using launchd or cron job, during quiet time
# Converts Channels DVR to a Plex & iOS-friendly m4v (h.264) format
# Pre-requisites:
#  HandBrakeCLI (video transcoding application)
#  Curl (for accessing web resources)
#  jq (for processing JSON databases)
# Optional pre-requisites:
#  MP4Box (part of GPAC, use MacPorts or similar) for marking commercials start/end as chapters
#  An IFTTT Maker Key for phone statusnotifications.
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
# LINUX: Run as a cron or service, e.g. "EDITOR=nedit crontab -e" then add line 1 12 * * * nice /usr/local/bin/transcode-plex.sh
# Edit default settings below.  These may all be over-ridden from the command line, e.g. transcode-plex.sh CHAPTERS=1 COMTRIM=0 FIND_METHOD="-mtime -2"
#
## FIRST RUN
# The first time you run this code, it will create a database, typically in the same location as the preferences file
# If you have a lot of older recordings that you don't want transcoded, run with e.g. DAYS=1, to prevent recordings older than 1 DAY being transcoded
# By default, database initiation will be set to DAYS=7.
# Note that if you do not have write access to the existing database, then a new one will be set up and initiated.


## PREFERENCES FOR SYSTEM CONFIGURATION
# The preferences file is normally called "prefs", and is searched for within these locations in order:
#   ${BASH_SOURCE%/*}/transcode-plex/prefs
#   ~/.transcode-plex/prefs
#   ${BASH_SOURCE%/*}/../lib/transcode-plex/prefs
#   ~/Library/Application Support/transcode-plex/prefs
#   /Library/Application Support/transcode-plex/prefs
#   /var/lib/transcode-plex/prefs
#   /usr/local/lib/transcode-plex/prefs
# Alternatively, have a file called transcode-plex.prefs in your current working directory to overload
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

# A useful little tool for evaluating version numbers
function ver {
  printf "%03d%03d%03d%03d" $(echo "$1" | tr '.' ' ' | head -n 4 )
}

## INITIATION
# Reads initiation variables
if [ $# -gt 0 ] ; then
  for var in "$@"; do
    variable=$(echo "$var" | cut -f1 -d=)
    value=$(echo "$var" | cut -f2- -d=)
    eval "${variable}=\"${value}\""
    if [ "$DEBUG" -eq 1 ]; then echo "${variable}=${value}"; fi
  done
fi
if [[ ! -d "$DIR" ]]; then DIR="$PWD"; fi

# Finds preferences file, sources it, then sets preferences directory
if [ ! "${SOURCE_PREFS}" ]; then
  for i in "/usr/local/lib/${BN}/prefs" "/var/lib/${BN}/prefs" "/Library/Application Support/${BN}/prefs" "${HOME}/Library/Application Support/${BN}/prefs" "${DIR}/../lib/${BN}.prefs" "${HOME}/.${BN}/prefs" "${DIR}/${BN}/prefs" "./${BN}.prefs"; do
    if [ -f "${i}" ]; then SOURCE_PREFS="${i}"; break ; fi
  done
fi

if [ "${SOURCE_PREFS}" ]; then
  # spellcheck source=/dev/null
  PREFS_DIR="$(dirname "${SOURCE_PREFS}")"
  PREFS_DIR="$(realpath "${PREFS_DIR}")"
  if [ "$DEBUG" -eq 1 ] ; then echo "SOURCE_PREFS=${SOURCE_PREFS}"; fi
  source "${SOURCE_PREFS}" || ( echo "Couldn't read SOURCE_PREFS=${SOURCE_PREFS}."; exit 1 )
else
  echo "Cannot find preferences file.  Example at: https://github.com/karllmitchell/Channels-DVR-to-Plex/"
  exit 1
fi
if [ "${DEBUG}" -eq 1 ] ; then echo "PREFS_DIR=${PREFS_DIR}"; fi

# Re-reads initation variables to over-ride any global variables set on the command line
if [ $# -gt 0 ] ; then
  for var in "$@"; do
    variable=$(echo "$var" | cut -f1 -d=)
    value=$(echo "$var" | cut -f2- -d=)
    case "$variable" in
      DEBUG)
        if [ ! "$DEBUG" ]; then eval "${variable}=\"${value}\""; fi
	;;
      SOURCE_PREFS)
        if [ "$DEBUG" -eq 1 ]; then echo "${variable}=${SOURCE_PREFS}"; fi
	;;
      *)
        eval "${variable}=\"${value}\""
	if [ "$DEBUG" -eq 1 ]; then echo "${variable}=${value}"; fi
	;;
    esac
  done
fi

# Search through temporary directory to find any stalled jobs
[ ! "$TMP_PREFIX" ] && TMP_PREFIX="transcode" 
for i in ${WORKING_DIR/ /\ }/${TMP_PREFIX}.*/progress.txt; do
  notify_me "Found incomplete jobs in ${i}.  Cleaning directory and updating database where necessary."  
  grep transcode < "${i}" | awk '$7 == 0 {print $10}' >> "${TRANSCODE_DB}"
  rm -rf "$(dirname "${i}")" || notify_me "Cannot delete ${i}.  Please do so manually."
done

# Read Source Directory from API
if [ ! "${SOURCE_DIR}" ]; then SOURCE_DIR=$(curl -s http://192.168.2.2:8089/dvr/files/../../dvr | jq -r '.path'); fi
if [ ! -d "${SOURCE_DIR}" ] ; then
  SOURCE_DIR=""
  [ "${VERBOSE}" -ne 0 ] && echo "Cannot read Channels source directory.  Functioning remotely via API only."
fi

## ESTABLISH PRESENCE OF CLI INTERFACES
# Essential...
program="HandBrakeCLI"; if [ ! -f "${HANDBRAKE_CLI}" ]; then HANDBRAKE_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
program="curl"; if [ ! -f "${CURL_CLI}" ]; then CURL_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
program="jq"; if [ ! -f "${JQ_CLI}" ]; then JQ_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
# Optional
if [ "${CAFFEINATE_CLI}" ]; then
  program="caffeinate"; if [ ! -f "${CAFFEINATE_CLI}" ]; then CAFFEINATE_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
  "${CAFFEINATE_CLI}" -s; cpid=$!
fi
if [ "$CHAPTERS" == 1 ]; then
  program="MP4Box"; if [ ! -f "${MP4BOX_CLI}" ]; then MP4BOX_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
fi
if [ "$PARALLEL_CLI" ]; then
  program="parallel"; if [ ! -f "${PARALLEL_CLI}" ]; then PARALLEL_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
fi
if [ "$COMTRIM" == 1 ]; then
  program="ffmpeg"; if [ ! -f "${FFMPEG_CLI}" ]; then FFMPEG_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
fi
if [ "$AP_CLI" ]; then
  program="AtomicParsley"; if [ ! -f "${AP_CLI}" ]; then AP_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
  regex="(.*)version: (.*) (.*)"
  apvers=$(${AP_CLI} | grep version)
  if [[ "${apvers}" =~ ${regex} ]]; then
    [ "$(ver "${BASH_REMATCH[2]}")" -lt "$(ver "0.9.6")" ] && ( echo "Old version of AtomicParsley detected.  Upgrade."; AP_CLI="" )
  else
    echo "Cannot work out version of AtomicParsley.  Upgrade."
    AP_CLI=""
  fi
fi
[ "${DEBUG}" -eq 1 ] && echo "All required programs found."

## REPORT PROGRESS, OPTIONALLY VIA PHONE NOTIFICATIONS
# Customise if you have an alternative notification system
function notify_me {
  echo "${1}"
  if [ "${IFTTT_MAKER_KEY}" ]; then 
    IFTTT_MAKER="https://maker.ifttt.com/trigger/{TVevent}/with/key/${IFTTT_MAKER_KEY}"
    case "${VERBOSE}" in
      0)
        quiet="--silent"
	;;
      2)
        quiet="--verbose"
	;;
      *)
        quiet="--silent"
	;;
    esac
    "${CURL_CLI}" $quiet -X POST -H "Content-Type: application/json" -d '{"value1":"'"${1}"'"}' "$IFTTT_MAKER" > /dev/null
  fi
  return 0
}
export -f notify_me
   
## TEST FOR PRESENCE OF API INTERFACE (ESSENTIAL)
if [ ! "${HOST}" ]; then HOST="localhost:8089"; fi
regex="(.*):(.*)"
if [[ "${HOST}" =~ ${regex} ]]; then HOST="${BASH_REMATCH[1]}"; PORT="${BASH_REMATCH[2]}"; else PORT=8089; fi
CHANNELS_DB="http://${HOST}:${PORT}/dvr/files"
${CURL_CLI} -sSf "${CHANNELS_DB}" > /dev/null || (notify_me "Cannot find API at ${CHANNELS_DB}"; exit 14)
[ "${VERBOSE}" -ne 0 ] && echo "Channels DVR API Interface Found"

        
## CREATE AND GO TO A TEMPORARY WORKING DIRECTORY
cwd=$(pwd)
if [ ! "${WORKING_DIR}" ]; then WORKING_DIR="/tmp"; fi
TMPDIR=$(mktemp -d ${WORKING_DIR}/${TMP_PREFIX}.XXXXXXXX) || exit 2
cd "${TMPDIR}" || ( notify_me "Cannot access ${WORKING_DIR}"; exit 2 )
[ "$VERBOSE" -ne 0 ] &&  echo "Working directory: ${TMPDIR}" 


## CREATE FUNCTION TO CLEAN UP AFTER YOURSELF
##
function finish {
  cd "${cwd}" || ( cd && echo "Original directory gone" ) 
  if [ "$DEBUG" -ne 1 ]; then rm -rf "${TMPDIR}" || echo "Okay, that's strange: Temp directory missing" ; fi
}
trap finish EXIT


## CHECK FOR AND INITIATE TRANSCODE DATABASE IF NECESSARY
if [ ! "${TRANSCODE_DB}" ]; then TRANSCODE_DB="${PREFS_DIR}/transcode.db"; fi
if [ ! -f "${TRANSCODE_DB}" ] || [ "${CLEAR_DB}" -eq 1 ] ; then
  if [ ! "${DAYS}" ] ; then DAYS=0; fi
  if [ ! -w "${TRANSCODE_DB}" ] ; then
    notify_me "Cannot write to ${TRANSCODE_DB}, using ${HOME}/${BN}/transcode.db instead"
    TRANSCODE_DB="${HOME}/${BN}/transcode.db"
  fi
  if [ "$(uname)" == "Darwin" ]; then since=$(date -v-${DAYS}d +%FT%H:%M); else since=$(date -d "$(date) - ${DAYS} days" +%FT%H:%M); fi
  if [ "${DEBUG}" -eq 1 ]; then echo "Initiating database with recordings up to ${since}.  Using ${CURL_CLI} and ${JQ_CLI}."; fi
  "${CURL_CLI}" -s "${CHANNELS_DB}" | "${JQ_CLI}" -r '.[] | select ((.Airing.Raw.endTime < "'"$since"'")) | {ID} | join(" ") ' > "${TRANSCODE_DB}"
  notify_me "Transcode database initialised at ${TRANSCODE_DB}"
fi
if [ ! -w "${TRANSCODE_DB}" ] ; then
  notify_me "Cannot write to ${TRANSCODE_DB}.  I give up!"
  exit 13
fi


## MAIN TRANSCODING FUNCTION, APPLIED TO EACH FILE FOUND
##
function transcode {  
  # Transcode file, and run additional commands if successful
  # This assumes you're in the current working directory and that the source file exists
  # .ffsplit and .vdr files should have the same prefix.
  
  # Initial database download and file discovery
  cd "${TMPDIR}" || (notify_me "Cannot access ${TMPDIR}"; return 2)
  "${CURL_CLI}" -s "${CHANNELS_DB}/${1}" > "${1}.json"
  "${CURL_CLI}" -s "${CHANNELS_DB}/${1}/mediainfo.json" > "${1}_mi.json"
  ifile="${SOURCE_DIR}/$(${JQ_CLI} -r '.Path' < "${1}.json")"
  fname=$(basename "${ifile}")        # Name of original file
  bname="${fname%.*}"                 # Name of original file minus extension

  if [ "${DEBUG}" -eq 1 ]; then
    echo "ifile = ${ifile}"
    echo "fname = ${fname}"
  fi
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
    showname="$(showname_clean "${showname}")"
  fi
  regex="(.*)\ \(([0-9]{4})\)\ ([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4})\.(mp4|mkv|mpg|ts|m4v)"
  if [[ "${fname}" =~ ${regex} ]]; then
    rectype="Movie"
    showname="${BASH_REMATCH[1]}"
    year="${BASH_REMATCH[2]}"
    #recdate="${BASH_REMATCH[3]}"
    extension="${BASH_REMATCH[4]}"
  fi
  if [ ! "${rectype}" ]; then
    echo "Cannot identify type of file based on filename."
  fi
  
  # Fix naming convention of output file and pre-build some iTunes tags
  if [ "${rectype}" == "TV Show" ]; then
    bname="${showname} - S${season}E${episode} - ${title}"
    AP_OPTS=(--title "${title}" --TVShowName "${showname}" --TVEpisode "${season}${episode}" --TVEpisodeNum "$episode" --TVSeason "$season")
    AP_OPTS+=(--genre "TV Shows" --stik "TV Show") 
  fi
  if [ "${rectype}" == "Movie" ]; then
    bname="${showname} (${year})"
    AP_OPTS=(--title "${showname}" --genre "Movies" --stik "Movie")
  fi
  
  # Determine if file already available on local system.  Download via API if not.
  fname="${1}.${extension}"
  if [ ! -f "${fname}" ] ; then
    if [ -f "${ifile}" ] ; then
      ln -s "${ifile}" "${fname}"
      [ "$VERBOSE" -eq 2 ] && echo "Linking to local system copy of ${bname}"
    else
      "${CURL_CLI}" -s -o "${fname}" "${CHANNELS_DB}/${1}/stream.${extension}"
      [ "$VERBOSE" -eq 2 ] && echo "${bname} downloading from API"
    fi
  fi
  [ ! -f "${fname}" ] && ( notify_me "Cannot find input file"; exit 4 )
  [ "${DEBUG}" -eq 1 ] && echo "Input file is ${fname}."
 
  
  # Looks to see if we have direct access to comskip logs
  if [ "$(jq -r 'select (( .Commercials[0] )) | {ID} | join (" ")' < tmp.json )" ]; then
    notify_me "${bname} not comskippped."
    # Add code here to call comskip directly and new options to force comskip functionality
    ctfail=1
  fi

  # Commercial trimming (optional)
  if [ "${COMTRIM}" -eq 1 ] && [ "${ctfail}" -ne 1 ]; then
    # Perform the actual file splitting
    if [ -f "${2}" ]; then
      ffsplit="${2}"   # Can use file provided via $2 if needed
    else
      curl -s "http://192.168.2.2:8089/dvr/files/${1}/comskip.ffsplit" > "${1}.ffsplit"; ffsplit="${1}.ffsplit"
    fi 
    
    if [ -f "${ffsplit}" ]; then
      [ "$VERBOSE" -ne 0 ] && echo "Attempting to trim input file"
      while read -r split <&3; do
        "${FFMPEG_CLI}" -i "${fname}" "${split}" || ctfail=1
      done 3< "${ffsplit}" 
      for i in segment*; do echo "file \'${i}\'" >> "${bname}.lis" ; done
      "${FFMPEG_CLI}" -f concat -i "${bname}.lis" -c copy "${1}_cut.${extension}" || ctfail=1
      rm -f segment*
      if [ -f "${1}_cut.${extension}" ]; then
        rm -f "${fname}" && mv -f "${1}_cut.${extension}" "${fname}" || ctfail=1
      fi
    else
      ctfail=1
    fi
    
    if [ ${ctfail} -eq 0 ]; then
      mv -f "${bname}_cut.${extension}" "${fname}"
      [ "$VERBOSE" -ne 0 ] && echo "Commercial trimming was successful"
    else
      notify_me "${bname} commercial trim failed. Using un-trimmed file."
    fi 
  fi
  

  # THE ACTUAL TRANSCODING PART
  echo "Attempting to transcode ${fname} ..."
  if [ "$MAXSIZE" ]; then EXTRAS+=(--maxHeight "$MAXSIZE" --maxWidth $((MAXSIZE * 16 / 9))); fi
  if [ "${ALLOW_EAC3}" -eq 1 ]; then EXTRAS+=(-E "ffaac,copy" --audio-copy-mask "eac3,ac3,aac"); fi 
  if [ "$VERBOSE" -ne 0 ] ; then
    for arg in "${HANDBRAKE_CLI}" -v "${VERBOSE}" -i "${fname}" -o "${1}.m4v" --preset="${PRESET}" --encoder-preset="${SPEED}" "${EXTRAS[@]}"; do
      if [[ $arg =~ \  ]]; then arg=\"$arg\"; fi
      echo -n "$arg "
    done; echo
  fi
  if "${HANDBRAKE_CLI}" -v "${VERBOSE}" -i "${fname}" -o "${1}.m4v" --preset="${PRESET}" --encoder-preset="${SPEED}" "${EXTRAS[@]}" ; then
    rm -f "${fname}" # Delete tmp input file/link  
  else
    # Transcode has failed, so report that but don't give up on the rest
    notify_me "${bname} transcode failed."
    return 6   # Returns from transcode function with error 6 (transcoding failed)
  fi

  
  # COMMERCIAL MARKING
  # Instead of trimming commercials, simply mark breaks as chapters
  if [ "${CHAPTERS}" -eq 1 ] && [ "${COMTRIM}" -ne 1 ] && [ "${ctfail}" -ne 1 ] ; then
    if [ -f "${2}" ]; then
      vdr="${2}";
    else
      curl -s "http://192.168.2.2:8089/dvr/files/${1}/comskip.vdr" > "${1}.vdr"; vdr="${1}.vdr"  
    fi  # Can use file provided via $2 if needed
    
    if [ -f "${vdr}" ]; then
      "${MP4BOX_CLI}" -lang "${LANG}" -chap "${vdr}" "${1}.m4v" || ctfail=1
      [ "$VERBOSE" -eq 0 ] && echo "Commercials marked"
    else
      ctfail=1
    fi
  fi
  [ ${ctfail} -eq 1 ] && notify_me "Unable to mark commercials as chapters"

  # TAGGING
  if [ "$AP_CLI" ]; then
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
    "${AP_CLI}" "${1}.m4v" "${AP_OPTS[@]}"
  fi
  
  
  # Determine if destination directory exists on local system, and create target folder if so.
  # If not, bail. (Alternative approach to return file over GNU parallel protocol T.B.D.)
  if [ -d "${DEST_DIR}" ] ; then
    if [ "${rectype}" == "TV Show" ]; then
      tdname="${DEST_DIR}/TV Shows/${showname}/Season $((season))"
    else
      tdname="${DEST_DIR}/Movies/${showname}"
    fi
    if mkdir -p "${tdname}"; then
      [ "$VERBOSE" -eq 2 ] && echo "Target directory okay"
    else
      notify_me "${tdname} inaccessible.  Bailing."; exit 5
    fi
    if mv -f "${1}.m4v" "${tdname}/${bname}.m4v"; then
      [ "$VERBOSE" -eq 2 ] && echo "Delivered"
    else
      if [ "${BACKUP_DIR}" ]; then    
        mv -f "${1}.m4v" "${BACKUP_DIR}/${bname}.m4v" || (notify_me "${bname}.m4v undeliverable"; return 5)
        notify_me "${bname} sent to backup directory"; return 5
      fi
    fi
  else
    notify_me "${DEST_DIR} inaccessible"; return 5      
  fi
  notify_me "${bname} processing complete." 
  
  return 0
} 
export -f transcode


# Wait until the system is done with recording and commercial skipping
busy=$(curl -s http://192.168.2.2:8089/dvr/files/../../dvr | jq '.busy')
if [ ! "${BUSY_WAIT}" -eq 0 ] && [ "${busy}" == true ] ; then
  notify_me "Waiting (max 4 hours) until Channels is no longer busy.  Set BUSY_WAIT=0 to prevent."
  while [ $SECONDS -lt 14400 ] || [ "${busy}" == true ] ; do
    wait 60
    busy=$(curl -s http://192.168.2.2:8089/dvr/files/../../dvr | jq '.busy')
  done
fi

## SEARCH API FOR RECORDINGS IN THE LAST $DAYS NUMBER OF DAYS THAT ARE NOT IN THE TRANSCODE DB.
# If none can be accessed, quit, otherwise report on how many shows to do.
rlist="${TMPDIR}/recordings.list"
jlist="${TMPDIR}/recordings.json"
"${CURL_CLI}" -s "${CHANNELS_DB}" > "${jlist}"

if [ "${SOURCE_FILE}" ]; then
  if [ "${SOURCE_FILE}" == "$(realpath "${SOURCE_FILE}")" ]; then SOURCE_FILE=$(basename "$SOURCE_FILE"); fi
fi

# Creates a list of new shows (optionally that match search criteria)
"${JQ_CLI}" -r \
 '.[] | select ((.Airing.Raw.endTime >= "'"$since"'")) | select (.Path | contains("'"${SOURCE_FILE}"'")) | select (.Deleted == false) | select (.Processed == true) | {ID} | join(" ")' \
  < "${jlist}" | grep -Fxv -f "${TRANSCODE_DB}" > "${rlist}"

# Report how many news shows have been found
count=$(wc -l "${rlist}" | cut -d" " -f1)
if [ "$count" ]; then
  notify_me "Found ${count} new shows to transcode."
else
  notify_me "No new shows to transcode"
  exit 0
fi

## RUN THE MAIN LOOP TO ACTIVATE TRANSCODING JOBS
# Optionally via GNU parallel
# To do: Only add shows to transcode database if successful, or remove them if unsuccessfulaaaa
if [ "$PARALLEL_CLI" ]; then
  if [ "$COMTRIM" == 1 ]; then PARALLEL_OPTS+=(--delay 120); fi
  PARALLEL_OPTS+=(--joblog "progress.txt" --results progress --progress)
  # The following need to be exported to use GNU parallel:
  export HANDBRAKE_CLI MP4BOX_CLI JQ_CLI FFMPEG_CLI CURL_CLI AP_CLI \
    PRESET SPEED EXTRAS MAXSIZE ALLOW_EAC3 \
    DEST_DIR SOURCE_DIR BACKUP_DIR CHANNELS_DB TMPDIR  \
    COMTRIM CHAPTERS LANG DELETE_ORIG IFTTT_MAKER_KEY TVDB_API VERBOSE DEBUG 
  export -f showname_clean
  parallel --record-env
  parallel --env _ "${PARALLEL_OPTS[@]}" -a "${rlist}" transcode {}
  
  flist=""
  for i in ${rlist}; do
    if [ "$(grep "transcode ${i}" < progress.txt | awk '{print $7}')" -eq 0 ]; then
      echo "${i}" >> "${TRANSCODE_DB}" || ( notify_me "Couldn't update transcode database"; exit 13 )
    else
      flist+="${i} "
    fi
  done
else 
  flist=""
  while read -r i ; do
    if [ "$(transcode "${i}")" ]; then
      echo "${i}" >> "${TRANSCODE_DB}" || ( notify_me "Couldn't update transcode database"; exit 13 )
    else
      flist+="${i} " 
    fi
  done < "${rlist}"
fi

if [ "${flist}" ]; then
  notify_me "Transcoding complete.  Failed to transcode the following recording(s): ${flist}"
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
