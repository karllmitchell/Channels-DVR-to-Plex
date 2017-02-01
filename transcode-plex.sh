#!/bin/bash
# (C) Karl Mitchell 2017, GPL: https://www.gnu.org/licenses/gpl-3.0.en.html
# Best run once daily, e.g. using launchd or cron job, during quiet time
# Converts Channels DVR to a Plex & iOS-friendly m4v (h.264) format
# Pre-requisites:
#  HandBrakeCLI (video transcoding application)
# Optional pre-requisites:
#  MP4Box (part of GPAC, use MacPorts or similar) for marking commercials start/end as chapters
#  Curl and an IFTTT Maker Key for phone statusnotifications.
#  FFMPeg (a part of channels DVR, but you'll need to point to it) for commercial trimming
#  Caffeinate (a mac utility to prevent sleep)
#  Parallel (GNU software for parallel processing; Can run jobs in parallel across cores, processors or even computers if set up correctly)
# Unix prerequisites for above packages (use e.g. apt-get/macports):
#  autoconf automake libtool pkgconfig argtable sdl coreutils curl ffmpeg realpath
# MAC OS: Run with launchd at /Library/LaunchAgents/com.getchannels.transcode-plex.plist.  Edit to change when it runs (default = 12:01am daily).
#  Once in place and readable, run
#   sudo launchctl load /Library/LaunchAgents/com.getchannels.transcode-plex.plist
#   sudo launchctl start com.getchannels.transcode-plex
#   chmod 644 /Library/LaunchAgents/com.getchannels.transcode-plex.plist
#  If your computer sleeps, be sure to set something to wake it up on time.
# LINUX: Run as a cron or service, e.g. "EDITOR=nedit crontab -e" then add line 1 12 * * * nice /usr/local/bin/transcode-plex.sh
# Edit default settings below.  These may all be over-ridden from the command line, e.g. transcode-plex.sh CHAPTERS=1 COMTRIM=0 FIND_METHOD="-mtime -2"

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
#   e.g. transcode-plex.sh CHAPTERS=1 COMTRIM=0 FIND_METHOD="-mtime -2" 
EXECUTABLE="${BASH_SOURCE[0]}"
BN=$(basename "${EXECUTABLE}")
DIR="${BASH_SOURCE%/*}"

echo "${BN} executed"

if [[ ! -d "$DIR" ]]; then DIR="$PWD"; fi

for i in "/usr/local/lib/${BN}/prefs" "/var/lib/${BN}/prefs" "/Library/Application Support/${BN}/prefs" "${HOME}/Library/Application Support/${BN}/prefs" "${DIR}/../lib/${BN}.prefs" "${HOME}/.${BN}/prefs" "${DIR}/${BN}/prefs" "./${BN}.prefs"; do
  if [ -f "$i" ] ; then SOURCE_OPTS="$i"; fi
done

if [ "${SOURCE_OPTS}" ]; then
  # spellcheck source=/dev/null
  source "${SOURCE_OPTS}"
else
  echo "Cannot find preferences file.  Example at: https://github.com/karllmitchell/Channels-DVR-to-Plex/"
  exit 1
fi

if [ $# -gt 0 ] ; then
  for var in "$@"; do
    variable=$(echo "$var" | cut -f1 -d=)
    value=$(echo "$var" | cut -f2- -d=)
    eval "${variable}=\"${value}\""
  done
fi


## ESTABLISH PRESENCE OF CLI INTERFACES
program="HandBrakeCLI"; if [ ! -f "${HANDBRAKE_CLI}" ]; then HANDBRAKE_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
if [ "${CAFFEINATE_CLI}" ]; then
  program="caffeinate"; if [ ! -f "${CAFFEINATE_CLI}" ]; then CAFFEINATE_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
  "${CAFFEINATE_CLI}" -s; cpid=$!
fi
if [ "$CHAPTERS" == 1 ]; then
  program="MP4Box"; if [ ! -f "${MP4BOX_CLI}" ]; then MP4BOX_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
fi
if [ "$IFTTT_MAKER_KEY" ]; then
  program="curl"; if [ ! -f "${CURL_CLI}" ]; then CURL_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
fi
if [ "$PARALLEL_CLI" ]; then
  program="parallel"; if [ ! -f "${PARALLEL_CLI}" ]; then PARALLEL_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
fi
if [ "$FFMPEG_CLI" ]; then
  program="ffmpeg"; if [ ! -f "${FFMPEG_CLI}" ]; then FFMPEG_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
fi
if [ ! "$(which realpath)" ] ; then
  echo "Some functionality of this software will be absent if realpath is not installed."
  echo "If you have problems, then please set up an alias in /etc/bashrc (or your system equivalent) thus:"
  echo "alias realpath='[[ \$1 = /* ]] && echo \"\$1\" || printf \"%s/\${1#./}\" \${PWD}'"
fi
if [ "$(uname)" == "Darwin" ]; then alias find="find -E"; else REGEXTYPE="-regextype posix-extended"; fi


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
        quiet=""
	;;
    esac
    "${CURL_CLI}" $quiet -X POST -H "Content-Type: application/json" -d '{"value1":"'"${1}"'"}' "$IFTTT_MAKER" > /dev/null
  fi
  return 0
}
export -f notify_me
   
        
## CREATE AND GO TO A TEMPORARY WORKING DIRECTORY
cwd=$(pwd)
if [ ! "${WORKING_DIR}" ]; then WORKING_DIR="/tmp"; fi
TMPDIR=$(mktemp -d ${WORKING_DIR}/transcode.XXXXXXXX) || exit 1
cd "${TMPDIR}" || ( notify_me "Cannot access ${WORKING_DIR}"; exit 1 )
if [ "$VERBOSE" -ne 0 ] ; then echo "Working directory: ${TMPDIR}"; fi 


## CLEAN UP AFTER YOURSELF
function finish {
  cd "${cwd}" || ( cd && echo "Original directory gone" ) 
  if [ "$DEBUG" -ne 1 ]; then rm -rf "${TMPDIR}" || echo "Okay, that's strange: Temp directory missing" ; fi
}
trap finish EXIT


## MAIN TRANSCODING FUNCTION, APPLIED TO EACH FILE FOUND

function transcode {  
  # Transcode file, and run additional commands if successful
  # This assumes you're in the current working directory and that the source file exists
  # .cffsplit and .vdr files should have the same prefix.
  
  ifile="$1"  # Full path to original file
  fname=$(basename "$1")     # Name of original file
  bname="${fname%.*}"       # Name of original file minus extension
  
  regex="(.*) - [sS]([0-9]{2})[eE]([0-9]{2}) - (.*)\.(mp4|mkv|mpg|ts|m4v|avi)"
  if [[ "${fname}" =~ ${regex} ]]; then
    showname="${BASH_REMATCH[1]}"
    season="${BASH_REMATCH[2]}"
    episode="${BASH_REMATCH[3]}"
    title="${BASH_REMATCH[4]}"
    extension="${BASH_REMATCH[5]}"
  fi  
  tdname="${DEST_DIR}/${showname}/Season $((season))"

  # COMMERCIAL TRIMMING (optional)
  # Trims out commercial breaks before transcoding, if option set
  if [ "${COMTRIM}" -eq 1 ]; then
    # Finds symbolic link to target file within Logs directory. Important: Assumes only one match.
    # Then finds comskip output files within that directory.
    ctfail=0
    
    if [ "$VERBOSE" -ne 0 ] ; then echo "Attempting to trim input file"; fi
    
    # Split then concatenate source file
    if [ ${ctfail} -eq 0 ] && [ -f "${bname}.cffsplit" ] && [ -s "${FFMPEG_CLI}" ]; then
      while read -r split <&3; do
        "${FFMPEG_CLI}" -i "${fname}" "${split}" || ctfail=1
      done 3< "${bname}.ffsplit"      
      for i in segment*; do echo "file \'${i}\'" >> "${bname}.lis" ; done
      "${FFMPEG_CLI}" -f concat -i "${bname}.lis" -c copy "${bname}_cut.${extension}" || ctfail=1
      rm -f segment*
    else
      ctfail=1
    fi
    
    if [ ${ctfail} -eq 0 ]; then
      mv -f "${bname}_cut.${extension}" "${fname}"
      if [ "$VERBOSE" -ne 0 ] ; then echo "Commercial trimming was successful"; fi
    else
      notify_me "${bname} commercial trim failed. Using un-trimmed file."
    fi
  fi
  
  # THE ACTUAL TRANSCODING PART
  echo "Attempting to transcode ${fname} ..."
  if [ "$MAXSIZE" ]; then EXTRAS+=(--maxHeight "$MAXSIZE" --maxWidth $((MAXSIZE * 16 / 9))); fi
  if [ "${ALLOW_EAC3}" -eq 1 ]; then EXTRAS+=(-E "ffaac,copy" --audio-copy-mask "eac3,ac3,aac"); fi 
  if [ "$VERBOSE" -ne 0 ] ; then
    echo \"${HANDBRAKE_CLI}\" -v \""${VERBOSE}"\" -i \""${ifile}"\" -o \""${bname}.m4v"\" --preset=\""${PRESET}"\" --encoder-preset=\""${SPEED}"\" "${EXTRAS[@]}"
  fi
  if "${HANDBRAKE_CLI}" -v "${VERBOSE}" -i "${fname}" -o "${bname}.m4v" --preset="${PRESET}" --encoder-preset="${SPEED}" "${EXTRAS[@]}" ; then
    rm -f "${ifile}" # Delete tmp input file/link  
  else
    # Transcode has failed, so report that but don't give up on the rest
    notify_me "${bname} transcode failed."
    return 5   # Returns from transcode function with error 5 (transcoding failed)
  fi

  
  # COMMERCIAL MARKING
  # Instead of trimming commercials, simply mark breaks as chapters
  if [ "${CHAPTERS}" -eq 1 ] && [ "${COMTRIM}" -ne 1 ]; then
    if [ "$VERBOSE" != 0 ] ; then echo "Adding commercial chapters to file"; fi
    if "${MP4BOX_CLI}" -lang "${LANG}" -chap "${bname}.vdr" "${bname}.m4v"; then
      if [ "$VERBOSE" != 0 ] ; then echo "Commercial marking succeeded"; fi
    else
      # Transcode has failed, so report that but don't give up on the rest
      notify_me "Failed to add commercial markers to ${bname}."
      return 8   # Returns from transcode function with error 8 (MP4 Box transcode failed)
    fi
  fi


  # MOVE FILE TO TARGET DIRECTORY
  if [ "$VERBOSE" != 0 ] ; then echo mv -f \""${bname}.m4v"\" \""${tdname}"\"; fi
  if mkdir -p "${tdname}" && mv -f "${bname}.m4v" "${tdname}"; then 
    echo "Devlivered."
    # If this fails, back up transcoded file to local drive, then send error messages and exit script	
  else
    if [ "${BACKUP_DIR}" ]; then    
      if mv -f "${bname}.m4v" "${BACKUP_DIR}"; then 
        notify_me "${bname}.m4v undeliverable, sent to backup directory."
        exit 3  # Exits from script with error 3 (cannot write to source directory; backup location used).
      else
        notify_me "${bname}.m4v undeliverable."
        exit 6  # Exits from script with error 6 (cannot write to source directory or backup location).
      fi
    fi
  fi
  
  # CLEAN UP
  rm -f "${bname}.*"
  if [ "${DELETE_ORIG}" -eq 1 ]; then
    if ! rm -f "$1"; then
      notify_me "${bname} original file failed to delete."
      return 4	# Returns from transcode function with error 4 (cannot delete original file)
    fi
  fi
  
  notify_me "${bname} processing complete." 
  
  return 0
} 
export -f transcode



## SCAN SOURCE DIRECTORY FOR FILES, OR PARSE SOURCE_FILE ARGUMENT
# If none can be accessed, quit, otherwise report on how many shows to do.
                                                                        
rlist="${TMPDIR}/recording_list"
if [ "${SOURCE_FILE}" ]; then
  # Try to find the file within the source directory
  if ! find "${SOURCE_DIR}" -type f -name "*${SOURCE_FILE}*" > "${rlist}"; then
    # Interpret as a full file path, and if that fails exit
    realpath -e "${SOURCE_FILE}" > "${rlist}" || ( notify_me "Cannot find ${SOURCE_FILE}"; exit 1 )
  fi
else
  if ! find "${SOURCE_DIR}" -not -path '*/\.grab' -not -path "./Temp/*" -type f \
    ${REGEXTYPE} -regex ".*\.(${SOURCE_TYPE})" ${FIND_METHOD} > "${rlist}"; then
    notify_me "Cannot access ${SOURCE_DIR}"
    exit 1	# Exits from script with error 1 (cannot access source directory) 
  fi
fi
count=$(wc -l "${rlist}" | cut -d" " -f1)
if [ "$count" ]; then
  notify_me "Found ${count} new shows to transcode."
else
  notify_me "No new shows to transcode"
  exit 0
fi


## PREPARE FILES AND LINKS IN WORKING DIRECTORY
# This prepares all files for transcoding, one after the other
if [ "$VERBOSE" != 0 ] ; then echo "$(wc -l "${rlist}") files found."; fi
while read -r show <&3; do
  # EXTRACT DETAILS OF SHOW
  # Break down file name into variables and use to define output filename and directory
  regex="([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4})\ (.*)\ ([0-9]{4}-[0-9]{2}-[0-9]{2})\ [sS]([0-9]{2})[eE]([0-9]{2})\ (.*)\.(mp4|mkv|mpg|ts|m4v)"
  if [[ "$(basename "${show}")" =~ ${regex} ]]; then
    #recdate="${BASH_REMATCH[1]}"
    showname="${BASH_REMATCH[2]}"
    #transdate="${BASH_REMATCH[3]}"
    season="${BASH_REMATCH[4]}"
    episode="${BASH_REMATCH[5]}"
    title="${BASH_REMATCH[6]}"
    extension="${BASH_REMATCH[7]}"
  fi
  showname="$(showname_clean "${showname}")"
  tdname="${DEST_DIR}/${showname}/Season $((season))"
  bname="${showname} - S${season}E${episode} - ${title}"
  
  # Create symbolic links to comskip output files in tmp folder
  ctgt=$(find -L "${SOURCE_DIR}/../Logs/comskip" -samefile "${show}" -name "video.mpg") || ctfail=1
  cdir=$(dirname "${ctgt}") || ctfail=1
  for i in ffsplit vdr; do if [ -f "${cdir}/video.${i}" ] ; then ln -s "${cdir}/video.${i}" "${bname}.${i}"; fi; done

  # If selected, copy file to tmp folder, and report errors if there are issues
  if [ "${TEMP_COPY}" == 1 ]; then
    if [ "$VERBOSE" != 0 ] ; then printf "\nAttempting to copy %s ...\n" "$1"; fi
    if ! cp -f "${show}" "${TMPDIR}/${bname}.${extension}"; then
      # Report that file couldn't be accessed ...
      # ... and if source directory isn't accessible, exit from script, otherwise exit from function.
      if [ ! -d "${SOURCE_DIR}" ]; then
        notify_me "Cannot access ${SOURCE_DIR}"
        exit 1	 # Exits from script with error 1 (cannot access source directory)
      else
        notify_me "Cannot access ${1}"
        return 2   # Returns from transcode function with error 1 (cannot access original file)
      fi
    fi 
  else
    ln -s "${show}" "${bname}.${extension}"   # Otherwise simply create a symbolic link
  fi
done 3< "${rlist}"

# THIS CALLS THE ACTUAL TRANSCODING JOB
# Using GNU Parallel is preferred, due to the extra flexibility it gives
if [ "$PARALLEL_CLI" ]; then
  if [ "$COMTRIM" == 1 ]; then PARALLEL_OPTS+=(--delay 120); fi
  PARALLEL_OPTS+=(--joblog "progress.txt" --results progress --header :)
  # The following need to be exported to use GNU parallel:
  export DEST_DIR HANDBRAKE_CLI COMTRIM VERBOSE FFMPEG_CLI MAXSIZE ALLOW_EAC3 PRESET SPEED EXTRAS \
    CHAPTERS MP4BOX_CLI LANG BACKUP_DIR DELETE_ORIG CURL_CLI IFTTT_MAKER_KEY
  parallel --record-env
  parallel --env _ "${PARALLEL_OPTS[@]}" transcode ::: *.mpg
else 
  if [ "${NICE}" ]; then NICE="nice -n ${NICE}"; else NICE="nice"; fi
  for file in *.mpg; do ${NICE} transcode "${file}"; done
fi

notify_me "All transcoding complete"
if [ -f "${CAFFEINATE_CLI}" ]; then kill -9 ${cpid} ; fi

# Exit cleanly
exit 0
