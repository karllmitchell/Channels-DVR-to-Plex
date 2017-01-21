# Channels-DVR-to-Plex
Scripts to enable transcoding from Channels DVR recordings and addition to Plex file structure

I run both Channels DVR and Plex. I've found it convenient to automatically transcode to an h.264 format under Plex for streaming that avoids the need for live transcoding, which requires a more powerful processing. I figured it might be appreciated to share my work with you, here: https://gist.github.com/karllmitchell8. Please note that this has not been thoroughly tested on all systems, and that it is to be used at your own risk. This is sub-beta quality right now! Feel free to take it and make it your own, as long as you share your work.

**The main script**

*transcode-plex.sh* requires bash, and is designed primarily to run as a nightly job, preferably after all commercial scanning is over (12:01 AM by default), although it can be run from the command line too. I recommend placing it in /usr/local/bin.

At the top of the file there are a lot of settings, which are quite extensively commented within the script. Before running, you should read through and edit these, certainly if you're going to run it nightly (see below). All of these can be substituted on the command line (see examples below).

HandBrakeCLI is used for transcoding via ffmpeg and x264. This is easy to obtain (http://handbrake.fr/ or via apt-get, macports, etc.) and by default I have it set up to produce high quality full resolution outputs that look good on a full HDTV with Apple TV: the "Apple 1080p30 Surround" preset; This is suitable for most modern devices, but if it doesn't work for you just change it, or over-ride from the command line (see below). Both subtitles and sound are preserved from the original MPEG, and if surround sound exists then a stereo track is added for more universal compatibility. If you would like something more suitable for limited upload bandwidth, I recommend using the MAXSIZE setting (e.g. MAXSIZE=720 for 720p).  You could also try changing speed to e.g. veryslow (which trades processing load with file size, in theory).  Note that transcoding is done in software, and so will be a CPU hog on most systems, and so it's worth running with "nice" set (default is 10).  I have attempted to balance output quality, file size and processor load so that it will work well for most of you.

By default, the script looks for the last 24 hours of recordings (the FIND_METHOD="-mtime -1" setting) and only converts those. If you comment this line out, or leave it blank (e.g. FIND_METHOD="") it will convert every single folder. I do not recommend this unless you're running it with DELETE_ORIG=1 (which deletes the source file).  An eventual intent is to run automatically as soon as commercial skipping is complete.

Other interesting options are COMTRIM=1, which removes the commercials based on Channels DVR commercial detection, and CHAPTERS=1, which doesn't remove them, but does add chapter markers based on the start and end points that Plex can read. I recommend using this latter mode unless you are very confident in the commercial detection, which in my experience produces quite a few blunders unless you have tuned your comskip.ini file extremely carefully. Note that if both are set, COMTRIM will "win".

**Command line operation**

All of the default options within the script can be substituted for on the command line. In its most basic mode, simply run:

transcode-plex.sh

from the command line and it will scan the source directory (the "TV" folder where Channels DVR stores its recordings).

If you would like to overload any of the options above, simply add them as arguments, e.g.

transcode-plex.sh FIND_METHOD="-mmin 360" MAXSIZE=540 COMTRIM=1"

will only search for files created in the last 6 hours (360 minutes) and will create smaller 540p files with commercials trimmed. Note that if previously converted this will over-write it. At some point I may implement versioning based on preset. Also, it should be noted that the arguments are case-sensitive.

An additional option for command line execution only is to specify the show you want to convert using the SOURCE_FILE option, which can either specify the full file name, with or without path, or simply a part of that file name. It will also work if the full file path is given too, for compatibility with folder watching scripts. So both of these should work:

convert-plex.sh SOURCE_FILE="2017-01-14-2059 Sherlock on Masterpiece 2017-01-08 S04E02 The Lying Detective.mpg"
convert-plex.sh SOURCE_FILE="Sherlock"

Finally, some "bonus" feature described below utilize IFTTT for phone  notifications and GNU parallel for offloading to other machines. 

**Daemon/cron management**

For most Linux users it's probably easiest to run this as a cron job, preferably with a high "niceness". Something like:

1 12 * * * nice /usr/local/bin/transcode-plex.sh > ~/convert-plex.log

For Mac users, I've included a LaunchAgent file (com.getchannels.transcode-plex.plist), typically placed into the /Library/LaunchAgents directory. Once it's there, run the following:

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

*Requirements:*

i) A RECENT version of GNU parallel (some of the options I use aren't on older releases) installed both on this machine and any others you wish to send the commend to.
ii) Both the WORKING_DIR and the DEST_DIR must be visible in the same location on your drive on your remote system. This will involve drive mounting using NFS, AFP or SMB. I do not recommend SMB due to erratic file access. I also do not recommend trying this unless you have very smooth Gigabit networking or better. I'll work on different ways to implement this in the future that might be more efficient.
iii) Passwordless logins set up with ssh-keygen for remote ssh sessions on target machines.
iv) To read documentation on GNU parallel. This is not for beginners, and you will need to set up your system correctly to be able to use it.

Note that additional options (which can be edited in PARALLEL_OPTS) have been added to GNU parallel over the years, and at least one of those, specifically --memfree, I use. Please either update to a 2016+ version or, if you have problems, delete the "--memfree 700 M". (Note that my own tests have shown that the default settings {PRESET="Apple 1080p Surround", SPEED="veryfast", MAXSIZE=1080} have shown that 700 MBytes is about right if the source is 1080p, and 425 Mbytes if the source is 720p. These things are best to tune for yourself.)
