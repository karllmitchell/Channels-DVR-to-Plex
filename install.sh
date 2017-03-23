#!/bin/bash
# Installer for Channels-DVR-to-Plex software
# Should be safe for previous users, but check prefs folder after running, just in case
# Run as ". install.sh" or "chmod 700 install.sh; ./install.sh"

tplist="com.getchannels.channels-transcoder.plist"

wget https://github.com/karllmitchell/Channels-DVR-to-Plex/archive/master.zip
unzip master.zip
cd Channels-DVR-to-Plex-master || ( echo "Download did not work. Exiting" ; exit 1 )

# Determine if Mac or Linux, and if necessary import obsolete folders
if [ $(uname)=="Darwin" ]; then
  prefsdir="${HOME}/Library/Application Support/channels-transcoder"
  if [ -d "${HOME}/Library/Application Support/transcode-plex" ] && [ -d "${HOME}/Library/Application Support/channels-transcoder" ] ; then
    echo "Moving obsolete ${HOME}/Library/Application Support/transcode-plex to ${HOME}/Library/Application Support/channels-transcoder"
    mv -f "${HOME}/Library/Application Support/transcode-plex" "${HOME}/Library/Application Support/channels-transcoder"
  fi  
else
  prefsdir="${HOME}/.channels-transcoder"
  if [ -d "${HOME}/.transcode-plex" ] && [ ! -d "${HOME}/.channels-transcoder" ]; then
    echo "Moving obsolete ~/.transcode-plex to ~/.channels-transcoder"
    mv -f "${HOME}/.transcode-plex" "${prefsdir}"
  fi
fi

# Generate prefs directory, with user inputs
mkdir -p "${prefsdir}"
if [ ! -f "${prefsdir}/prefs" ] ; then 
  echo "The local destination directory is for producing Plex-like file structures."
  echo -n "Enter the desired destination directory, followed by [ENTER]: "
  read -r destination   # Destination for video recordings
  sed "/DEST_DIR*/c\DEST_DIR=\"${destination}\"" < channels-transcoder.prefs > "${prefsdir}/prefs"
  echo "If you're running this script on a machine other than the one running Channels DVR, you should specify the host here."
  echo -n "Enter the hostname and port number (leave blank for default \"localhost:8089\"), followed by [ENTER]: "
  read -r host_name       # Host for video recordings
  [ "${host_name}" ] || host_name="localhost:8089"
  sed "/HOST*/c\HOST=\"${host_name}\"                                         # Default=\"localhost:8089\".  For running  script remotely." < channels-transcoder.prefs > "${prefsdir}/prefs"
fi
echo "Password may be required to install channels-transcoder to /usr/local/bin : "
sudo mv channels-transcoder.sh /usr/local/bin


if [ ! -f "${prefsdir}/transcode.db" ] ; then
  echo "Channels transcoder to be initiated.  You may choose whether to transcode old recordings or ignore them."
  echo "If you have a lot of backlog, this will take significant time, so please ensure that your computer remains online."
  echo "Do not delete the Channels-DVR-to-Plex-master folder in the meantime.  It will clean itself up."
  echo
  echo -n "Enter the desired number of days of Channels DVR recordings backlog to transcode (default=0): "
  read -r days
  [ "${days}" -eq "${days}" ] 2>/dev/null || days=0

  # Initiate database
  cwd="$(pwd)"
  echo "Please wait for the database to be initiated and backlog to be transcoded..."
  /usr/local/bin/channels-transcoder.sh DAYS="${days}"
  echo "Database initiated.  Backlog transcoded." >> "${2}/log"
  
  echo "Installing automation script..."
  if [ "$(uname)" == "Darwin" ] && [ "$(which launchctl)" ] ; then
    echo "Defaulting to using launchd under MacOS" >> "${2}/log"
    if [ ! -f "${HOME}/Library/LaunchAgents/${tplist}" ]; then
      echo "If prompted, please enter your password now..."
      mv -f "${tplist}" "${HOME}/Library/LaunchAgents/${tplist}"
      launchctl load "${HOME}/Library/LaunchAgents/${tplist}"
      echo "Launch Agent installed"
  else
    # Update crontab
    count="$(crontab -l | sed 's/transcode-plex/channels-transcoder/g' | grep -s "channels-transcoder.sh" | wc -l)"
    case $count in
      0)  crontab -l > mycron
          echo "01 00 * * * nice /usr/local/bin/channels-transcoder.sh > \"${2}/log\"" >> mycron
          echo "Cronjob added, will run at 12:01 each night." >> "${2}/log"
	  ;;
      1)  crontab -l | sed 's/transcode-plex/channels-transcoder/g' > mycron
          echo "Using/adapting existing crontab" >> "${2}/log"
          ;;
      *)  crontab -l | sed 's/transcode-plex/channels-transcoder/g' | grep -v "channels-trancoder" > mycron
          echo "01 00 * * * nice /usr/local/bin/channels-transcoder.sh > \"${2}/log\"" >> mycron
          echo "Cronjob had multiple entriees.  Replaced with a single one that will run at 12:01 each night." >> "${2}/log"
    esac
    crontab mycron
    rm -f mycron
  fi
else
  echo "Existing transcode.db detected."
  echo "If you wanted to update your crontab or LaunchAgent, delete the channels-transcoder.sh line in your crontab,"
  echo " or, if on a Mac, delete the ${HOME}/Library/LaunchAgents/${tplist} launch agent."
  echo "Otherwise, you're good to go!"
fi
   
# Remove installation files
cd "${cwd}/.." || ( echo "Couldn't remove files" >> "${2}/log" && exit 1 )
rm -rf Channels-DVR-to-Plex-master master.zip
echo "Installation files removed"

echo "Done."

exit 0
