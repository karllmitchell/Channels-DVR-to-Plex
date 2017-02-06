# Channels-DVR-to-Plex

Channels DVR is an extremely user friendly piece of software for recording TV from Silicondust HDHomeRun network TV tuners and, primarily, for serving to the Channels app on the Apple TV 4.  However, it is somewhat limited in its ability to serve to other clients and outside of a local network, so I have found it convenient to automatically transcode recording shows to an h.264 format, added to Plex, with the added benefit that it avoids the need for live transcoding to most devices.

Please note that this has not been thoroughly tested on all systems, and that it is to be used at your own risk. It has so far been tested on (at least) Ubuntu 16.04 Xenial (arm64) and Mac OS Sierra 10.12 (intel x86-64).  This is sub-beta quality right now! Feel free to take it and make it your own, or contribute to this archive, as long as you share your work and operate within the license.

**The main script**

*transcode-plex.sh* requires bash, and is designed primarily to run as a nightly job, preferably after all commercial scanning is over (12:01 AM by default), although it can be run from the command line too. I recommend placing it in /usr/local/bin.  It can be run as root or user, but make sure that you can write to the destination directory and read from the source directory (if held locally).  It accepts various settings from a preference file or command line (see below).  When run for the first time, make sure to place the prefs file (see below) either in ~/.transcode-plex/prefs, /var/lib/transcode-plex/prefs or /Library/Application Support/transcode-plex/.  You may also wish to initialise the database (instruction below), although it should do a good job on its own.  

HandBrakeCLI is used for transcoding via ffmpeg and x264. This is easy to obtain (http://handbrake.fr/ or via apt-get, macports, etc.) and by default I have it set up to produce high quality full resolution outputs that look good on a full HDTV with Apple TV: the "Apple 1080p30 Surround" preset; This is suitable for most modern devices, but if it doesn't work for you just change it, or over-ride from the command line (see below). Both subtitles and sound are preserved from the original MPEG, and if surround sound exists then a stereo track is added for more universal compatibility. If you would like something more suitable for limited upload bandwidth, I recommend using the MAXSIZE setting (e.g. MAXSIZE=720 for 720p).  You could also try changing speed to e.g. veryslow (the speed setting trades processing load with file size, in theory, but in reality slower settings do not always produce smaller files).  Note that transcoding is done in software, and so will be a CPU hog on most systems, and thus it's worth running with "nice" set (default is 10).  It should be possible to edit the script to use hardware transcoding if desired.  I have attempted to balance output quality, file size and processor load so that it will work well for most end-users.

Although this will run on extremely underpowered systems, including ARM-based SOCs, by default I do not recommend anything with less than 1 GByte, preferable 2 GBytes, of RAM (certainly at least 750 MBytes unused).  If you are accessing the inputs files across a network, you will want a fast one (Gigabit throughout, ideally), or to set aside at least a few tens of GBytes of storage and use the TEMP_COPY=1 argument.  Many modern intel systems can almost certainly process faster-than-realtime (i.e. a 1-hr show will take less than 1-hr), but an ARM SOC like a Raspberry Pi would probably be about 6x slower than real-time, and might not keep up with your TV viewing.

**Preferences file**
There is also a preferences file (transcode-plex.prefs) that probably best belongs in /var/lib/transcode-plex/ for Linux users or /Library/Application Support/transcode-plex/ with filename just "prefs".  There are a lot of settings, which are quite extensively commented within the file. Before running, you should read through and edit these, certainly if you're going to run it nightly (see below). All of these can be substituted on the command line (see examples below).  This was previously embedded in the script, but then people had to keep re-editing on each update; This seems more convenient.  A database of previously transcoded shows will be placed in the same directory.  You can reset this by running with CLEAR_DB=1, and selected DAYS=n, where n is the the number of days ago you wish to initialise up to, e.g. if you set DAYS=2, then it will mark all present shows of more than 2 days old as being previously processed.

By default, the script looks shows that it hasn't recorded before.  You can limit it to shows recorded in the past N days using the DAYS=N option (e.g. transcode-plex.sh DAYS=2). 

Other interesting options are COMTRIM=1, which removes the commercials based on Channels DVR commercial detection, and CHAPTERS=1, which doesn't remove them, but does add chapter markers based on the start and end points that Plex can read. I recommend using this latter mode unless you are very confident in the commercial detection, which in my experience produces quite a few blunders unless you have tuned your comskip.ini file extremely carefully. Note that if both are set, COMTRIM will "win".

Finally, some "bonus" feature described below utilize IFTTT for phone notifications and GNU parallel for offloading to other machines. 

**Command line operation**

All of the default options within the script can be substituted for on the command line. In its most basic mode, simply run:

transcode-plex.sh

from the command line and it will scan the source directory (the "TV" folder where Channels DVR stores its recordings).

If you would like to overload any of the options above, simply add them as arguments, e.g.

transcode-plex.sh DAYS=1 MAXSIZE=540 COMTRIM=1

will only search for files created in the last 6 hours (360 minutes) and will create smaller 540p files with commercials trimmed. Note that it will not transcode previously finished shows until you re=initate your database (CLEAR_DB=1). Also, it should be noted that the arguments are case-sensitive.

An additional option for command line execution only is to specify the show you want to convert using the SOURCE_FILE option, which can either specify the full file name, with or without path, or simply a part of that file name. It will also work if the full file path is given too, for compatibility with folder watching scripts. So both of these should work:

convert-plex.sh SOURCE_FILE="2017-01-14-2059 Sherlock on Masterpiece 2017-01-08 S04E02 The Lying Detective.mpg"
convert-plex.sh SOURCE_FILE="Sherlock"

One again, if it's in your database it will not run it.  To force an old version, run twice:

convert-plex.sh CLEAR_DB=1 DAYS=10000 SOURCE_FILE="Sherlock"
convert-plex.sh CLEAR_DB=1 DAYS=0

will convert all shows with "Sherlock" in the title recorded in the past 10000 days, and then will reinitiatlise the database, marking all shows present in Channels DVR as having previously been transcoded.

**Daemon/cron management**

For most Linux users it's probably easiest to run this as a cron job, preferably with a high "niceness". Something like:

1 0 * * * nice /usr/local/bin/transcode-plex.sh > ~/convert-plex.log

which starts it running at 12:01am every night.  For Mac users, I've included a LaunchAgent file in this archive (com.getchannels.transcode-plex.plist), typically placed into the /Library/LaunchAgents directory. Once it's there, run the following:

sudo launchctl load /Library/LaunchAgents/com.getchannels.transcode-plex.plist
sudo launchctl start com.getchannels.transcode-plex

The log files (transcode-plex.log and transcode-plex.err) are in /var/log, and so can be monitored easily (e.g. tail -f transcode-plex.log).

I'm working on more daemon and file monitoring approaches, and would appreciate additions from others.

**Phone notifications**

This is a convenient way to monitor your jobs. Unfortunately IFTTT are restricting the ability to share applets at the moment, for anyone other than developers, but it's fairly easy to roll your own.

You will need to set up an IFTTT account and the app installed on your phone. Then you should add the Notifications (https://ifttt.com/if_notifications) and Maker (https://ifttt.com/maker) services, before going to Maker settings (linked from https://ifttt.com/maker), copying the 22-digit code at the end of the URL under Account Settings and adding it to the IFTTT_MAKER_KEY variable in the script. Finally, you'll set up an IFTTT applet thus as per the graphic (ifttt-maker-transcode-plex.png).

**Parallelization**

I have been experimenting with GNU parallel, giving the ability to (i) farm your processes out to other computers, and (iii) wait for available resources before encoding. It looks to be working fairly well, and so I added it as a feature, which is by default turned off. However, IF you want to give it a go, be my guest. For those of you that know what you're doing, you'll want to set your -S (server) options within the PARALLEL_OPTS setting.

I do not recommend parallelizing between cores on a single machine (i.e. setting -j to more than 1), because (i) Handbrake with x264 is very scalable between cores already, and so even though you might see a marginal potential gain, there are plenty of other bottlenecks that could reverse that gain, and (ii) You'll actually see your files later on average, because of non-sequential delivery.

*Parallelisation Requirements:*

i) A RECENT version of GNU parallel (some of the options I use aren't on older releases) installed both on this machine and any others you wish to send the commend to.
ii) Both the WORKING_DIR and the DEST_DIR must be visible in the same location on your drive on your remote system. This will involve drive mounting using NFS, AFP or SMB. I do not recommend SMB due to erratic file access. I also do not recommend trying this unless you have very smooth Gigabit networking or better. I'll work on different ways to implement this in the future that might be more efficient.
iii) Passwordless logins set up with ssh-keygen for remote ssh sessions on target machines.
iv) To read documentation on GNU parallel. This is not for beginners, and you will need to set up your system correctly to be able to use it.

Note that additional options (which can be edited in PARALLEL_OPTS) have been added to GNU parallel over the years, and at least one of those, specifically --memfree, I use. Please either update to a 2016+ version or, if you have problems, delete the "--memfree 700 M". (Note that my own tests have shown that the default settings {PRESET="Apple 1080p Surround", SPEED="veryfast", MAXSIZE=1080} have shown that 700 MBytes is about right if the source is 1080p, and 425 Mbytes if the source is 720p. These things are best to tune for yourself.)
