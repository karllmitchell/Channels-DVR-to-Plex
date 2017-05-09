#!/bin/bash
# Installer for Channels-DVR-to-Plex software
# Should be safe for previous users, but check prefs folder after running, just in case
# Run as "bash install.sh" or "chmod 700 install.sh; ./install.sh"

set -e

tplist="com.getchannels.channels-transcoder.plist"
fname="channels-transcoder"
oname="transcode-plex"
targetdir="/usr/local/bin/"

echo "If you're running this script on a machine other than the one running Channels DVR, you should specify the host here."
echo -n "Enter the hostname and port number (leave blank for default \"localhost:8089\"), followed by [ENTER]: "
read -r host_name       # Host for video recordings
[ "${host_name}" ] || host_name="localhost:8089"
  
echo "Checking for critical pre-requisite programs:"
echo " jq curl ffmpeg realpath"
echo "Optional packages include:"
echo " AtomicParsley >= 0.9.6 and parallel >= 20161222"
echo "If they do not exist on your system, please use whichever package manager"
echo " works for your system to install them"
echo "On Ubuntu/Debian Linux:"
echo " sudo apt-get install jq curl HandBrakeCLI ffmpeg realpath"
echo "On Mac, use homebrew, macports or fink similarly."

[ ! "$(which curl)" ] && echo " curl not installed." && prfail=1 
[ ! "$(which jq)" ] && echo " jq not installed." && prfail=1

datadir="$(curl -s "http://${host_name}/system" | jq -r '.pwd')"
[ -d "${datadir}" ] || echo " Channels DVR API not present at defined host.  Is Channels DVR installed?" && prfail=1
idir="$(dirname "$datadir")"

[ ! "$(which ffmpeg)" ] && [ ! -f "${idir}/latest/ffmpeg" ] && echo " ffmpeg not installed." && prfail=1 
if [ ! "$(which realpath)" ] && [ ! "$(alias realpath)" ] ; then
  echo " realpath not installed."
  echo "  - If you cannot find realpath, then please set up an alias in ~/.bashrc,"
  echo "    ~/.profile (or your system equivalent) and relog to activate, thus:"
  echo "     alias realpath='[[ \$1 = /* ]] && echo \"\$1\" || printf \"%s/\${1#./}\" \${PWD}'"
  prfail=1 
fi
[ "${prfail}" -eq 1 ] && [ "$1" != "force" ] && echo "Some pre-requisites not installed." && echo "Please try again or use \"bash install.sh force\" then edit your prefs file manually" && exit 1


# Download archive, unzip and change directories
rm -f master.zip*
wget https://github.com/karllmitchell/Channels-DVR-to-Plex/archive/master.zip
unzip master.zip
cd Channels-DVR-to-Plex-master || ( echo "Download did not work. Exiting" ; exit 1 )
chmod 755 "${fname}.sh"

# Import obsolete folders
echo "Checking for obsolete versions of preferences folder"
if [ "$(uname)" == "Darwin" ]; then
  prefsdir="${HOME}/Library/Application Support/${fname}"
  if [ -d "${HOME}/Library/Application Support/${oname}" ] && [ -d "${HOME}/Library/Application Support/${fname}" ] ; then
    echo "Moving obsolete ${HOME}/Library/Application Support/${oname} to ${HOME}/Library/Application Support/${fname}"
    mv -f "${HOME}/Library/Application Support/${oname}" "${HOME}/Library/Application Support/${fname}"
  fi  
else
  prefsdir="${HOME}/.${fname}"
  if [ -d "${HOME}/.${oname}" ] && [ ! -d "${HOME}/.${fname}" ]; then
    echo "Moving obsolete ~/.${oname} to ~/.${fname}"
    mv -f "${HOME}/.${oname}" "${prefsdir}"
  fi
fi
echo "Done."
echo

# Generate prefs directory, with user inputs
mkdir -p "${prefsdir}"
if [ ! -f "${prefsdir}/prefs" ] ; then 
  echo "The local destination directory is for producing Plex-like file structures." 
  echo -n "Enter the desired destination directory (default \"${HOME}/Movies/Plex\"), followed by [ENTER]: "
  read -r destination   # Destination for video recordings
  [ "${destination}" ] || destination="${HOME}/Movies/Plex"
  mkdir -p "${destination}" || ( echo "Destination directory unwritable.  Bailing.  Please re-run installation script." ; exit 1 )
  
  
  # Install prefs file
  cat channels-transcoder.prefs | sed "/DEST_DIR*/c\DEST_DIR=\"${destination}\"" | sed "/HOST*/c\HOST=\"${host_name}\"" > "${prefsdir}/prefs"
  echo "Preferences file generated."
else
  echo "Leaving old preferences file as is at: ${prefsdir}/prefs"
fi
echo

# Install main binary
echo "Installing main binary ..."
nosudo=$(sudo -v 2>&1 >/dev/null)
if [ "${nosudo}" ]; then
  targetdir="${HOME}/bin/"
  mkdir -p "${targetdir}"
  echo "Running completely in user-space.  Ensure ${HOME}/bin is in your path."
  mv -f "${fname}.sh" "${targetdir}"
  chmod 755 "${targetdir}/${fname}.sh"
else
  echo "Password may be required to install channels-transcoder to /usr/local/bin : "
  sudo mv -f "${fname}.sh" "${targetdir}"
  sudo chmod 755 "${targetdir}/${fname}.sh"
fi
echo "Main binary installed."
echo

# Transcode backlog if no transcode.db found
if [ -f "${prefsdir}/transcode.db" ]; then
  echo "Existing transcode.db detected.  If you would like to clear a backlog, enter the number of days below."
  echo "If show was previously transcoded and is listed in transcode.db, transcode will be prevented unless you delete ${prefsdir}/transcode.db first."
else
  echo "No existing transcode.db detected.  This will now be initiated."
  echo "If you would like to transcode previously transcoded shows, please pick a number of days worth of backlog to transcode, e.g. 1000"
fi
echo "If you have a lot of backlog, this will take significant time, so please do not close this terminal or reboot."
echo -n "Enter the desired number of days of Channels DVR recordings backlog to transcode (default=0): "
read -r days
[ "${days}" ] || days=0
[ "${days}" -gt 0 ] && echo "Please wait.  You may check progress by opening another terminal and running: tail -f \"${prefsdir}/log\""
"${targetdir}/${fname}.sh" DAYS="${days}" > "${prefsdir}/log" 2>&1
echo "Database OK."
echo

# Install launchagent (mac) or cronjob (other) in user space
echo "Installing automation script..."
if [ "$(uname)" == "Darwin" ] && [ "$(which launchctl)" ] ; then
  echo "Defaulting to using launchd under MacOS" >> "${2}/log"
  echo "If prompted, please enter your password now..."
  mv -f "${tplist}" "${HOME}/Library/LaunchAgents/${tplist}"
  launchctl load "${HOME}/Library/LaunchAgents/${tplist}"
  echo "Launch Agent installed.  Inspect ${HOME}/Library/LaunchAgents/${tplist} if you would like to edit it."
else
  # Update crontab
  count="$(crontab -l | sed "s/${oname}/${fname}/g" | grep -s "${fname}.sh" | wc -l)"
  case $count in
    0)  crontab -l > mycron
	echo "01 00 * * * nice \"${targetdir}/${fname}.sh\" >> \"${2}/log\"" >> mycron
	echo "Cronjob added, will run at 12:01 each night." 
        ;;
    1)  crontab -l | sed "s/${oname}/${fname}/g" > mycron
	echo "Using/adapting existing crontab"
	;;
    *)  crontab -l | sed "s/${oname}/${fname}/g" | grep -v "${fname}" > mycron
	echo "01 00 * * * nice \"${targetdir}/${fname}.sh\" >> \"${2}/log\"" >> mycron
	echo "Cronjob had multiple entriees.  Replaced with a single one that will run at 12:01 each night."
  esac
  crontab mycron
  rm -f mycron
  echo "Crontab installed. Run crontab -e if you would like to edit it."
fi
echo
  
# Remove installation files
cd .. 
rm -rf Channels-DVR-to-Plex-master master.zip || ( echo "Couldn't remove files, but everything else seems OK" && exit 1 )
echo "Installation files removed"
echo "Done."

exit 0
