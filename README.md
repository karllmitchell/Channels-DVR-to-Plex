# Channels-DVR-to-Plex

Channels DVR (https://community.getchannels.com/dvr/) is an extremely user friendly piece of software for recording TV from Silicondust HDHomeRun network TV tuners and, primarily, for serving to the Channels app on the Apple TV 4.  However, it is somewhat limited in its ability to serve to other clients and outside of a local network. I have found it convenient to automatically transcode recorded shows to an h.264 format and add them to a Plex (http://plex.tv) server.  This avoids the need for live transcoding to most devices, enabling lower power hardware and more optimized algorithms to minimize bandwidth.

Please note that this has not been thoroughly tested on all systems, and that it is to be used at your own risk. It has so far been tested on (at least) Ubuntu 16.04 Xenial (arm64) and Mac OS Sierra 10.12 (intel x86-64).  This is sub-beta quality right now!  Feel free to take it and make it your own, or contribute to this archive, as long as you share your work and operate within the license.

Pre-requisites on unix systems (including Mac) are working versions of Channels DVR and Plex Media Server, as well as the following utilities: jq, curl, coreutils, AtomicParsley (optional, preferably >= 0.9.6) and GNU parallel (>= 20161222).  These can be installed e.g. `apt-get install jq curl coreutils atomicparsley parallel` on Debian/Ubuntu Linux.  On a Mac, install the homebrew software first (http://brew.sh/), then run `brew install jq curl coreutils atomicparsley parallel`.  Be sure to check version numbers installed against requirements, which may change over time. 

The Channels-DVR-to-Plex software can be installed using the *install.sh* script, thus:

`curl https://raw.githubusercontent.com/karllmitchell/Channels-DVR-to-Plex/master/install.sh > install.sh;  bash install.sh`

Do NOT pipe to bash, or use any other type of shell, or it will fail.  Note that this can also be used to update existing configurations.

When running the install script, consider carefully the question about number of days backlog to transcode, as this can take a long time. DAYS=0 is pretty safe, and you can always transcode missed shows later from the command line.

The final step is that you'll need to go to your Plex web interface and add the TV Shows and Movies folder within your desination directory to your Plex library.  By default these are "${HOME}/Movies/Plex/TV Shows" and "${HOME}/Movies/Plex/Movies".

For 90% of you, and the TL;DR crowd, that's probably enough to get you going.  

**The main script**

*channels-transcoder.sh* requires bash, and is designed primarily to run as a nightly job, preferably after all commercial scanning is over (12:01 AM by default), although it has additional functionality when run via the command line too.  It can be installed either on the same machine as runs Channels DVR, or on another machine as long as you set the HOST variable; Note that it will copy files across the network in this latter mode.  The advantage of this is that you can run a very low powered machine (ARM board or NAS) for the recording, and then use another higher-powered machine for the transcoding, potentially letting it sleep most of the time. By default it lives in /usr/local/bin.

At the core of the script is ffmpeg, which performs the transcoding via libx264; The same script that performs transcoding from the web interface of Channels DVR. By default I have it set up to produce high quality full resolution outputs that look good on a full HDTV with Apple TV, which also runs on most devices that are capable of 1080p playback.  Both closed captions and sound are preserved from the original MPEG, and if surround sound exists then a stereo track is added for more universal compatibility.  However, unfortunately Plex at the moment does not support the ability to play back these closed captions, something I'm hoping to fix eventually.

Although the code will run on extremely underpowered systems, including low cost ARM-based SOCs runnings Linux, by default I do not recommend anything with less than 1 GByte, preferable 2 GBytes, of RAM (certainly at least 750 MBytes unused).  If you are accessing the inputs files across a network, you will want a fast one (Gigabit throughout, ideally), or to set aside at least a few tens of GBytes of storage and use the TEMP_COPY=1 argument.  Many modern intel systems can almost certainly process faster-than-realtime (i.e. a 1-hr show will take less than 1-hr), but an ARM SOC like a Raspberry Pi would probably be about 6x slower than real-time, and might not keep up with your TV viewing.

**Set up, first run and the transcode database**

On this first run (or install script), the code will initialise a database that lists previously transcoded recordings. Note that it will by default not transcode any previously recorded shows unless you respond to the DAYS prompt when asked (install script).  You can reset this database using the command-line with these options:

`channels-transcoder.sh CLEAR_DB=1 DAYS=N`

where N is the number of days backlog you want clearing (so e.g. DAYS=7).  This will reset the database and mark all previously recorded shows (before N days ago) as having already been transcoded.  This may take a long time, depending on your system and how much stuff you have.  DO NOT run transcode-plex.sh again until this is complete.  The install script will handle most of this for you.

**Subsequent runs**

From now on, channels-transcoder.sh should work fine if run on a repeated cycle, e.g. every 24 hours.  If an existing instance of it running is found, or if Channels DVR is recording or comskipping, it will wait up to a user-defined amount of time (default=82800 seconds or 23 hours) before executing.  If more than one existing instance is found, channels-transcoder.sh will exit immediately. Note that HandBrakeCLI h.264 encoding is well optimized for multiple CPUs/threads, and so most of the time there is little benefit to running it multiple times.

Setting BUSY_WAIT=0 will prevent waiting for Channels DVR or channels-transcoder activity to cease, although it will still quit if 2+ instances of channels-transcoder are found.  

If you want something specific transcoded ASAP, and have no concerns about resources, you can override this behaviour with BUSY_WAIT=0, typically in conjunction with DAYS=0. 

**Preferences file**

The preferences file, typically in ~/.channels-transcoder/prefs or ~/Library/Application Support/channels-transcoder/prefs, has a lot of settings.  This might seem intimidating, but most are not needed for regular users, and all are commented extensively within the file.  The only critical one for MOST users is the DEST_DIR one, which points at somewhere Plex can see.  The install script will prompt you for it.  It is assumed that "TV Shows" and "Movies" are subdirectories in that file.  Once set up, you should easily be able to add these folders to Plex.  If you prefer to integrate with existing Plex folders, and your "TV Shows" and "Movies" folders are named or configured in that way, you can work around it using symbolic links.

Some interesting options are CHAPTERS=1 (selected by default), which uses Channels DVR commercial markers as chapter markers in the output file, and COMTRIM=1, which actually completely removes the commercial breaks.  I do not recommend  using this latter mode unless you are very confident in the commercial detection, which in my experience produces quite a few blunders unless you have tuned your comskip.ini file extremely carefully. Note that if both are set, COMTRIM will "win".

By default, the basic settings should be suitable for most modern devices and produce good quality output close to the original broadcast.  I'll add more details here on the settings soon.

If you would like something more suitable for limited upload bandwidth, I recommend using the MAXSIZE setting (e.g. MAXSIZE=720 for 720p; 576 is the lowest I would personally go for decent quality), which reduces resolution and substantially reduces filesize.  You could also lowering the speed to e.g. veryslow, which supposedly trades speed to processing time, but in reality these slower settings do not always produce smaller files.

Note that transcoding is done in software, and so will be a CPU hog on most systems, and thus it's worth running with "nice" set (default is 10, 0 is normal priority, 19 is lowest).  It should be possible to edit the script to use hardware transcoding if desired, but I haven't tested that yet (please contact me if you're interested).  I have attempted to balance output quality, file size and processor load so that it will work well for most end-users.

Finally, some "bonus" feature described below utilize IFTTT for phone notifications, GNU parallel for offloading transcoding to other machines, and more.  Some of these are documented below.

**Command line operation**

All of the default options within the script can be substituted for on the command line. In its most basic mode, simply run:

`channels-transcoder.sh`

from the command line and it will scan the source directory (the "TV" folder where Channels DVR stores its recordings).

If you would like to overload any of the options above, simply add them as arguments, e.g.

`channels-transcoder.sh DAYS=1 MAXSIZE=540 COMTRIM=1`

will only search for files created in the last 6 hours (360 minutes) and will create smaller 540p files with commercials trimmed. Note that it will not transcode previously finished shows until you re=initate your database (CLEAR_DB=1). Also, it should be noted that the arguments are case-sensitive.

An additional option for command line execution only is to specify specific recordings on the command line.  This is done without the VAR="parameter" format, and can use either a part of the filename, or the specific Channels DVR recording ID, e.g.:

`channels-transcoder.sh 11 12 14 OVERWRITE=1`

Recordings specified in this manner will be transcoded regardless of whether there is a record of a previous transcoding in transcode.db, but by default they will not overwrite anything in the Plex file structure.  The OVERWRITE=1 option forces it to copy over previous versions; leave it off if you don't need it.  

`channels-transcoder.sh "Sherlock"`

This version is a search expression on the filename, and so in this instance it would find ALL shows containing the search term Sherlock.  You can be as specific as you like with the search expression, and so the entire filename can be given to avoid ambiguity.  However, if you choose to search by directories, note that these are relative to the root of the Channels DVR database, so "Sherlock" would work, so "channels/TV/Sherlock" wouldn't.  If you had a file in "TV/Sherlock on Masterpiece/2017-01-19-0259 Sherlock on Masterpiece 2017-01-15 S04E03 The Final Problem.mpg", "Sherlock" would find it, and possibly multiple other matches.  You could be more specific and add "Sherlock on Masterpiece 2017-01-15",  but "Sherlock on Masterpiece S04E03" would not due to search parameter being split; I hope to improve on this soon, so that you can more easily specify Show and SxxExx code, but in the meantime be careful about how you word your searches.  

Given that there are limits to the number of instances (2) of channels-transcoder.sh that will run, there are circumstances under which running this manually may prevent automatic execution.  Mostly this shouldn't happen, but I do not recommend trying to manually run more than one instance simultaneously.

If, for whatever reason, you wish to reset your transcode database, you can always do so as per initial setup instructions, e.g. channels-transcoder.pl CLEAR_DB=1 DAYS=N.


**Daemon/cron management**

This should be set up for users that run the install script.

For most Linux users it's probably easiest to run this as a cron job, e.g. the default:

`1 0 * * * /usr/local/bin/channels-transcoder.sh >> ~/.channels-transcoder/log`

This would running at 12:01am every night (by default the script will also wait internally for up to 4 hours for Channels DVR to stop recording/comskipping before starting).

This would work for Mac users too, but it's better to use Launch Agents.  I've included a LaunchAgent file in this archive (com.getchannels.channels-transcoder.plist), which is installed by default on Macs if you run the installation script.  It is typically placed into the ~/Library/LaunchAgents directory. Once it's there, run the following:

`launchctl load ${HOME}/Library/LaunchAgents/com.getchannels.channels-transcoder.plist`
`launchctl start com.getchannels.channels-transcoder`

The log file is also in the prefs director, and so can be monitored easily (e.g. tail -f ~/.channels-transcoder/log).

I'm working on more daemon and file monitoring approaches, and would appreciate additions from others.

**Phone notifications**

This is a convenient way to monitor your jobs. Unfortunately IFTTT are restricting the ability to share applets at the moment, for anyone other than developers, but it's fairly easy to roll your own.

You will need to set up an IFTTT account and the app installed on your phone. Then you should add the Notifications (https://ifttt.com/if_notifications) and Maker (https://ifttt.com/maker_webhooks) services, before going to Settings setting up the latter and copying the 22-digit code at the end of the URL and adding it to the IFTTT_MAKER_KEY variable in the script. Finally, you'll set up an IFTTT Applet as per the graphic (ifttt-maker-transcode-plex.png), noting that IFTTT undergoes cosmetic details a fair amount, and so it might look a little different.

**Parallelization**

I have been experimenting with GNU parallel, giving the ability to (i) farm your processes out to other computers, and (ii) wait for available resources before encoding. It looks to be working fairly well, and so I added it as a feature, which is by default turned off. However, IF you want to give it a go, be my guest.  Simply add explicit reference to the PARALLEL_CLI entry under prefs, and set your -S (server) options within the PARALLEL_OPTS setting.  You might want to try running with BUSY_WAIT=0, but there are some (admittedly unlikely) circumstances under which multiple instances might end up transcoding the same file multiple times.

I do not recommend parallelizing between cores on a single machine (i.e. setting -j to more than 1), because (i) Handbrake with x264 is very scalable between cores already, and so even though you might see a marginal potential gain, there are plenty of other bottlenecks that could reverse that gain, and (ii) You'll actually see your files later on average, because of non-sequential delivery.

*Parallelisation Requirements:*

i) A RECENT version of GNU parallel installed both on this machine and any others you wish to send the commend to.
ii) The DEST_DIR must be visible in the same location on your drive on your remote system. This will involve drive mounting using NFS, AFP or SMB. I do not recommend SMB due to erratic file access. I also do not recommend trying this unless you have very smooth Gigabit networking or better. I'll work on different ways to implement this in the future that might be more efficient.
iii) Passwordless logins set up with ssh-keygen for remote ssh sessions on target machines.
iv) To read documentation on GNU parallel. This is not for beginners, and you will need to set up your system correctly to be able to use it.

Note that additional options (which can be edited in PARALLEL_OPTS) have been added to GNU parallel over the years, and at least one of those, specifically --memfree, I use. Please either update to a 2016+ version or, if you have problems, delete the "--memfree 700 M". (Note that my own tests have shown that the default settings {PRESET="AppleTV 3", SPEED="veryfast", MAXSIZE=1080} have shown that 700 MBytes is about right if the source is 1080p, and 425 Mbytes if the source is 720p. These things are best to tune for yourself.)

**Other scripts**

Over time I will be adding other scripts to this archive.
