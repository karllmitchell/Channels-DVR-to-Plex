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
#  autoconf automake libtool pkgconfig argtable sdl coreutils curl ffmpeg
# MAC OS: Run with launchd at /Library/LaunchAgents/com.getchannels.transcode-plex.plist.  Edit to change when it runs (default = 12:01am daily).
#  Once in place and readable, run
#   sudo launchctl load /Library/LaunchAgents/com.getchannels.transcode-plex.plist
#   sudo launchctl start com.getchannels.transcode-plex
#   chmod 644 /Library/LaunchAgents/com.getchannels.transcode-plex.plist
#  If your computer sleeps, be sure to set something to wake it up on time.
# LINUX: Run as a cron or service, e.g. "EDITOR=nedit crontab -e" then add line 1 12 * * * nice /usr/local/bin/transcode-plex.sh
# Edit default settings below.  These may all be over-ridden from the command line, e.g. transcode-plex.sh CHAPTERS=1 COMTRIM=0 FIND_METHOD="-mtime -2"

## DEFAULT SETTINGS:
# Set the following variables to be correct for your system
# If source_dir is on a remove drive, automount/autofs is recommended
SOURCE_DIR="/mnt/dvr/channels/TV"            # Location for source video recordings.  Should be the TV sub-directory of channels-dvr folders.
SOURCE_TYPE="ts|mkv|mpg"                     # File extension used, could be "ts" or "ts|mpg|mpeg".  Avoid "m4v" if delivering to same directory..
DEST_DIR="/mnt/network/Plex/TV Shows"        # Desination for video recordings.  Subdirectory structure within SOURCE_DIR duplicated too..
WORKING_DIR="/mnt/dvr/tmp"                   # If left blank, an arbitrary temp directory will be used.
SOURCE_FILE=""                               # If filled, specifies a particular filename and only searches for that file.  Useful for manual input.
BACKUP_DIR=""                                # Location to deposit files if server offline.  Delete if not needed.
CHAPTERS=1                                   # Set to mark commercials as chapters.  Doesn't work if COMTRIM enabled.
COMTRIM=0                                    # Set to 1 to trim commercials from output file.  Takes priority over comskip.  Use at own risk.
DELETE_ORIG=0                                # Set to 1 to delete original files and 0 to disable.
TEMP_COPY=0                                  # Copies input file to the working directory first; useful when running over erratic networks.
LANG="en-US"                                 # Force MP4 file tracks to have a language; Necessary for AppleTV 4 to see chapters.			
FIND_METHOD="-mtime -1"                      # See man find for usage.  -mtime -1 signifies the last 24 hours.  Leave blank if you want all files.  
NICE=10                                      # For intensive tasks, set a "niceness" between 0 and 19, so as not to lock up the machine.
VERBOSE=1                                    # 0 = quiet; 1 = normal; 2 = detailed.
DEBUG=0                                      # For development.  Does not delete temporary directory (in WORKING_DIR) after use.  
					     
# Encoder presets, usually best to keep it simple.  
PRESET="Apple 1080p30 Surround"              # HandBrakeCLI preset determines output default quality/resolution, run HandBrakeCLI -z to show list
                                             # In older versions of HandBrakeCLI, this would be "AppleTV 3".  For old/slow clients use "Apple 720p30 Surround".
					     # In this instance, this is more for setting quality and player performance requirements.  Size can be changed below.
SPEED="veryfast"                             # Faster settings give theoretically larger filesizes and shorter transcode times; They do not affect quality.
                                             # In my own tests, however, despite using simpler, faster algorithms, veryfast actually produces smaller files.
					     # The only recommended ENCODER_PRESET values are slow, medium, fast, faster, fastest, veryfast.
MAXSIZE=720                                  # Sets an upper limit for height; Recommended are those that give a 16:9 ratio, 1080, 720, 576, 540, 360
ALLOW_EAC3=1                                 # EXPERIMENTAL: Enables preservation of Dolby Digital Plus (where available) in a manner playable by AppleTV 4.
EXTRAS=(--optimize --subtitle 1)             # Extra options set here.  Read HandBrakeCLI documentation before editing!

# Locations of critical programs.  These can be shortened to just the name, but then default version discovered by "which" will be used. 
HANDBRAKE_CLI="/usr/local/bin/HandBrakeCLI"  # Location of HandBrakeCLI binary.  Absolutely necessary
MP4BOX_CLI="/usr/bin/MP4Box"                 # Location of MP4Box binary (part of gpac package).  Only required if CHAPTERS=1.
FFMPEG_CLI="/usr/bin/ffmpeg"                 # Location of ffmpeg binary.  Only required if COMTRIM=1.
CAFFEINATE_CLI=""                            # Location of caffeinate binary.  Prevents system from sleeping if present.  Unnecessary for always-on systems.

# If you want phone notifications with IFTTT, enter your IFTTT_MAKER_KEY here, and be sure to have curl on your system
# Also, set up an IFTTT MAKER Applet event called "TVEvent" with a "Value1." notification format.
IFTTT_MAKER_KEY="cswxmCHxXyO05HkUU1STG0"     # Set to "" if you do not want IFTTT Maker notifications.  A 22-digit code.
CURL_CLI="/usr/bin/curl"                     # Location of curl binary.  Only required if using IFTTT notifications.
# WARNING: Do not change these two IFTTT system variables:
IFTTT_TYPE="Content-Type: application/json"
IFTTT_MAKER="https://maker.ifttt.com/trigger/{TVevent}/with/key/${IFTTT_MAKER_KEY}"

# WARNING: Most people should leave PARALLEL_CLI blank
# GNU parallel allows you to control the number of parallel transcoding jobs or farm out to other machines (target directory should be the same)
# Anyone using this will should read  GNU parallel documentation sufficient to set up their remote servers. Multiple PARALLEL_OPTS arguments should be added:
#   The memfree option requires a recent version of parallel >=2015, and should be tailored based on experience
#   If set up correctly, you can add multiple servers, e.g. "-S $SERVER1 -S $SERVER2", here too.  Remember to set ssh keys for password-free login.
#   --memfree 700M (RAM needed) is appropriate for default settings ("Apple 1080p30 Surround", veryfast, MAXSIZE=1080).  MAXSIZE=720 is more like 425M.
# T.B.D. etherwake to allow Wake-on-LAN functionality, and something to allow waiting for available cores.
PARALLEL_CLI="/usr/bin/parallel"             # Location of GNU parallel binary.  Note that with -j 1 this will run like a normal non-parallel task.  
PARALLEL_OPTS=(-j 1 --nice $NICE --memfree 700M) 

# The following need to be exported to use GNU parallel
export DEST_DIR HANDBRAKE_CLI COMTRIM VERBOSE FFMPEG_CLI MAXSIZE ALLOW_EAC3 PRESET SPEED EXTRAS CHAPTERS MP4BOX_CLI LANG BACKUP_DIR DELETE_ORIG CURL_CLI IFTTT_TYPE IFTTT_MAKER


# When multiple TV shows or movies have the same name, they need to be identified by year as well in order for Plex to identify them.
# Showname substitutions go below, using the format examples:
function showname_clean {
  local show=""
  case "$1" in
    "Bull") show="Bull (2016)";;
    "Conviction") show="Conviction (2016)";;
    "Doctor Who") show="Doctor Who (2005)";;
    "Once Upon a Time") show="Once Upon a Time (2011)";;
    "Poldark on Masterpiece") show="Poldark (2015)";;
    "Poldark") show="Poldark (2015)";;
    *) show="${1}";;
  esac
  echo "$show"
}

## ---------- DO NOT EDIT BELOW THIS LINE UNLESS YOU KNOW WHAT YOU'RE DOING ---------- ##

## DEFAULT SETTINGS OVER-RIDES
# You can over-ride any of the above settings by adding them as command line arguments
# e.g. transcode-plex.sh CHAPTERS=1 COMTRIM=0 FIND_METHOD="-mtime -2" 
if [ $# -gt 0 ] ; then
  for var in "$@"; do
    variable=$(echo "$var" | cut -f1 -d=)
    value=$(echo "$var" | cut -f2- -d=)
    eval "${variable}=\"${value}\""
  done
fi


## CHECK PRESENCE OF REQUIRED CLI INTERFACES
program="HandBrakeCLI"
if [ ! -f "${HANDBRAKE_CLI}" ]; then HANDBRAKE_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi

if [ ${CAFFEINATE_CLI} ]; then
  program="caffeinate"
  if [ ! -f "${CAFFEINATE_CLI}" ]; then CAFFEINATE_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
  "${CAFFEINATE_CLI}" -s; cpid=$!
fi

if [ $CHAPTERS == 1 ]; then
  program="MP4Box"
  if [ ! -f "${MP4BOX_CLI}" ]; then MP4BOX_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
fi

if [ $IFTTT_MAKER_KEY ]; then
  program="curl"
  if [ ! -f "${CURL_CLI}" ]; then CURL_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
fi

if [ $PARALLEL_CLI ]; then
  program="parallel"
  if [ ! -f "${PARALLEL_CLI}" ]; then PARALLEL_CLI=$(which ${program}) || (notify_me "${program} missing"; exit 9); fi
fi


## REPORT PROGRESS, OPTIONALLY VIA PHONE NOTIFICATIONS
# Customise if you have an alternative notification system
function notify_me {
  echo "${1}"
  if [ ${IFTTT_MAKER_KEY} ]; then 
    case ${VERBOSE} in
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
    "${CURL_CLI}" $quiet -X POST -H "$IFTTT_TYPE" -d '{"value1":"'"${1}"'"}' "$IFTTT_MAKER" > /dev/null
  fi
  return 0
}
export -f notify_me

        
## CREATE AND GO TO A TEMPORARY WORKING DIRECTORY
cwd=$(pwd)
if [ ! "${WORKING_DIR}" ]; then WORKING_DIR="/tmp"; fi

TMPDIR=$(mktemp -d ${WORKING_DIR}/transcode.XXXXXXXX) || exit 1
cd "${TMPDIR}" || ( notify_me "Cannot write to ${WORKING_DIR}"; exit 1 )
if [ $VERBOSE -ne 0 ] ; then echo "Working directory: ${TMPDIR}"; fi 

## CLEAN UP AFTER YOURSELF
function finish {
  cd "${cwd}" || cd || echo "Original directory gone" 
  if [ DEBUG -ne 1 ]; then rm -rf "${TMPDIR}"; fi
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
  if [ ${COMTRIM} -eq 1 ]; then
    # Finds symbolic link to target file within Logs directory. Important: Assumes only one match.
    # Then finds comskip output files within that directory.
    ctfail=0
    
    if [ $VERBOSE -ne 0 ] ; then echo "Attempting to trim input file"; fi
    
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
      if [ $VERBOSE -ne 0 ] ; then echo "Commercial trimming was successful"; fi
    else
      notify_me "${bname} commercial trim failed. Using un-trimmed file."
    fi
  fi
  
  # THE ACTUAL TRANSCODING PART
  echo "Attempting to transcode ${fname} ..."
  if [ $MAXSIZE ]; then EXTRAS+=(--maxHeight $MAXSIZE --maxWidth $((MAXSIZE * 16 / 9))); fi
  if [ ${ALLOW_EAC3} -eq 1 ]; then EXTRAS+=(-E "ffaac,copy" --audio-copy-mask "eac3,ac3,aac"); fi 
  if [ $VERBOSE -ne 0 ] ; then
    echo \"${HANDBRAKE_CLI}\" -v ${VERBOSE} -i \""${ifile}"\" -o \""${bname}.m4v"\" --preset=\""${PRESET}"\" --encoder-preset=\""${SPEED}"\" "${EXTRAS[@]}"
  fi
  if "${HANDBRAKE_CLI}" -v ${VERBOSE} -i "${fname}" -o "${bname}.m4v" --preset="${PRESET}" --encoder-preset="${SPEED}" "${EXTRAS[@]}" ; then
    rm -f "${ifile}" # Delete tmp input file/link  
  else
    # Transcode has failed, so report that but don't give up on the rest
    notify_me "${bname} transcode failed."
    return 5   # Returns from transcode function with error 5 (transcoding failed)
  fi

  
  # COMMERCIAL MARKING
  # Instead of trimming commercials, simply mark breaks as chapters
  if [ ${CHAPTERS} -eq 1 ] && [ ${COMTRIM} -ne 1 ]; then
    if [ $VERBOSE != 0 ] ; then echo "Adding commercial chapters to file"; fi
    if "${MP4BOX_CLI}" -lang "${LANG}" -chap "${bname}.vdr" "${oname}"; then
      if [ $VERBOSE != 0 ] ; then echo "Commercial marking succeeded"; fi
    else
      # Transcode has failed, so report that but don't give up on the rest
      notify_me "Failed to add commercial markers to ${bname}."
      return 8   # Returns from transcode function with error 8 (MP4 Box transcode failed)
    fi
  fi


  # MOVE FILE TO TARGET DIRECTORY
  if [ $VERBOSE != 0 ] ; then echo mv -f \""${bname}.m4v"\" \""${tdname}"\"; fi
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
  if [ ${DELETE_ORIG} == 1 ]; then
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
# If none can be accessed, quit with error                                                                                                                                                                                                                                              
notify_me "Searching for new shows to transcode."
rlist="${TMPDIR}/recording_list"
if [ "${SOURCE_FILE}" ]; then
  # Try to find the file within the source directory
  if ! find "${SOURCE_DIR}" -type f -name "*${SOURCE_FILE}*" > "${rlist}"; then
    # Interpret as a full file path, and if that fails exit
    realpath -e "${SOURCE_FILE}" > "${rlist}" || ( notify_me "Cannot find ${SOURCE_FILE}"; exit 1 )
  fi
else
  if ! find "${SOURCE_DIR}" -not -path '*/\.grab' -not -path "./Temp/*" -type f \
    -regextype posix-extended -regex ".*\.(${SOURCE_TYPE})" ${FIND_METHOD} > "${rlist}"; then
    notify_me "Cannot access ${SOURCE_DIR}"
    exit 1	# Exits from script with error 1 (cannot access source directory) 
  fi
fi


## PREPARE FILES AND LINKS IN WORKING DIRECTORY
# This prepares all files for transcoding, one after the other
if [ $VERBOSE != 0 ] ; then echo "$(wc -l "${rlist}") files found."; fi
while read -r show <&3; do
  #ifile=$(basename "${show}")     # Name of original file
  #bname="${fname%.*}"       # Basename of original file
  #dname=$(dirname "${show}")      # Directory of original file
  #extension="${show##*.}"   # Extension (type) of original file  
  
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
  if [ ${TEMP_COPY} == 1 ]; then
    if [ $VERBOSE != 0 ] ; then printf "\nAttempting to copy %s ...\n" "$1"; fi
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
  if [ $COMTRIM == 1 ]; then PARALLEL_OPTS+=(--delay 120); fi
  PARALLEL_OPTS+=(--joblog "progress.txt" --results progress --header :)
  parallel --record-env
  parallel --env _ "${PARALLEL_OPTS[@]}" transcode ::: *.mpg
else 
  if [ ${NICE} ]; then NICE="nice -n ${NICE}"; else NICE="nice"; fi
  for file in *.mpg; do ${NICE} transcode "${file}"; done
fi

notify_me "All transcoding complete"
if [ -f "${CAFFEINATE_CLI}" ]; then kill -9 ${cpid} ; fi

# Exit cleanly
exit 0
