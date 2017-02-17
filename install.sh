#!/bin/bash
# Installer for Channels-DVR-to-Plex software
# Should be safe for previous users, but check prefs folder after running, just in case
# Run as ". install.sh" or "chmod 700 install.sh; ./install.sh"

tplist="com.getchannels.channels-transcoder.plist"

function initiate_db {
  # Initiate database
  cwd="$(pwd)"
  /usr/local/bin/channels-transcoder.sh DAYS="${1}"
  echo "Database initiated.  Any backlog has been transcoded." >> "${2}/log"
  
  if [ "$(uname)" == "Darwin" ] && [ "$(which launchctl)" ] ; then
    echo "Defaulting to using launchd under MacOS" >> "${2}/log"
    mv "${tplist}" "${HOME}/Library/LaunchAgents/${tplist}"
    echo "You should now run:" >> "${2}/log"
    echo "sudo launchctl load \"~/Library/LaunchAgents/${tplist}\"" >> "${2}/log"
  else
    # Update crontab
    crontab -l > mycron
    echo "01 00 * * * nice /usr/local/bin/channels-transcoder.sh > \"${2}/log\" " >> mycron
    crontab mycron
    rm -f mycron
    echo "Cronjob added, will run at 12:01 each night." >> "${2}/log"
  fi
   
  # Remove installation files
  cd "${cwd}/.." || ( echo "Couldn't remove files" >> "${2}/log" && exit 1 )
  rm -rf Channels-DVR-to-Plex-master master.zip
  echo "Installation files removed"
  
  exit 0
}

wget https://github.com/karllmitchell/Channels-DVR-to-Plex/archive/master.zip
unzip master.zip
cd Channels-DVR-to-Plex-master || ( echo "Download did not work. Exiting" ; exit 1 )
prefsdir="${HOME}/.channels-transcoder"

# Update from obsolete location
if [ -d "${HOME}/.transcode-plex" ] && [ ! -d "${HOME}/.channels-transcoder" ]; then
  echo "Moving obsolete ~/.transcode-plex to ~/.channels-transcoder"
  mv -f "${HOME}/.transcode-plex" "${prefsdir}"
fi

# Alternative installation location for Mac users
if [ -d "${HOME}/Library/Application Support/transcode-plex" ] && [ -d "${HOME}/Library/Application Support/channels-transcoder" ] ; then
  echo "Moving obsolete ${HOME}/Library/Application Support/transcode-plex to ${HOME}/Library/Application Support/channels-transcoder"
  mv -f "${HOME}/Library/Application Support/transcode-plex" "${HOME}/Library/Application Support/channels-transcoder"
fi
[ -d "${HOME}/Library/Application Support/channels-transcoder" ] && prefsdir="${HOME}/Library/Application Support/channels-transcoder"

# 
mkdir -p "${prefsdir}"
if [ ! -f "${prefsdir}/prefs" ] ; then 
  echo "The destination directory is for producing Plex-like file structures."
  echo -n "Enter the desired destination directory, followed by [ENTER]: "
  read -r destination
  sed "/DEST_DIR*/c\DEST_DIR=\"${destination}\"                               # Destination for video recordings" < transcode-plex.prefs > ~/.channels-transcoder/prefs
fi
echo "Password will be required to install channels-transcoder: "
sudo mv channels-transcoder.sh /usr/local/bin

if [ ! -f "${prefsdir}/transcode.db" ] ; then
  echo "Channels transcoder to be initiated.  You may choose whether to transcode old recordings or ignore them."
  echo "If you have a lot of backlog, this will run slowly in the background."
  echo "Do not delete the Channels-DVR-to-Plex-master folder in the meantime.  It will clean itself up."
  echo -n "Enter the desired number of days of Channels DVR recordings backlog to transcode (default=0): "
  read -r days
  [ "${days}" -eq "${days}" ] 2>/dev/null || days=0
  initiate_db "${days}" "${prefsdir}" &
  pid=$!
  disown $pid
  if [ "$(uname)" == "Darwin" ] && [ "$(which launchctl)" ] ; then
    timeout 10 bash -c wait $pid
    if ps -p $pid >&-; then
      echo "Transcoding backlog is running in background."
      echo "Assuming it completes, once done you should run the following command: "
      echo "  sudo launchctl load \"${HOME}/Library/LaunchAgents/${tplist}\""
      echo "You may follow progress by running: tail -f \"${prefsdir}/log\""
    else
      echo "Installing launch daemon.  Password might be required."
      sudo launchctl unload "${HOME}/Library/LaunchAgents/${tplist}"
      sleep 2
      sudo launchctl load "${HOME}/Library/LaunchAgents/${tplist}"
    fi
  else
    timeout 10 bash -c wait $pid
    if ps -p $pid >&-; then
      echo "Any backlog is running in the background.  Depending on backlog it may take a while."
      echo "Once complete, a daily cronjob will be set up, running transcoding at 12:01 am."
    else
      echo "A daily cronjob has been set up, running transcoding at 12:01 am."
    fi 
    echo "Use crontab -e to change cronjob defaults if desired."
  fi
fi

echo "Done."

exit 0
