#!/bin/bash

# v001 - 2022-04-27
# Written by warp for use on ultra.cc.
# Tested on Deluge v1.3.15 without plugins that move completed downloads.
# Said plugins may break script.

# Purpose is to create a list of files stored on disk in the deluge completed
# directory that are not referenced in deluge. This helps recover wasted space
# from files that were not deleted after removing from deluge and for files
# extracted  from archives that are not needed to successully seed.
# Leave enough time for copy/move/hardlink of files by *arrs before deleting
# media extracted from archives.

# Command line arguments:
# -d directory	Optional. Scan for files in "directory". If omitted, use
#               the default "Deluge=>Preferences=>Downloads=>Move completed to"

# Get the directory to scan for orphaned files

getopts ":d:" flag
if [ $flag == 'd' ]
then
  directory=$OPTARG
  COMPLETEDIR=$(echo $directory | sed 's![^/]$!&/!')
else
  COMPLETEDIR=$(cat ~/.config/deluge/core.conf | grep "move_completed_path\"" | cut -d":" -f2 | cut -c2- | cut -d"," -f1 | sed 's/\"//g' | sed 's![^/]$!&/!')
fi

if [ -z "$COMPLETEDIR" ]
then
  printf "\033[0;33mError: Can't extract deluge completed torrents directory\033[0m"
  exit
else
  printf "\033[0;32mDirectory to scan:\033[0;33m $COMPLETEDIR\033[0m"
fi

# Extract the Deluge port numbers
DAEMONPORT=$(app-ports show | grep -i "deluge daemon" | awk '{print $1}')
if [ -z "$DAEMONPORT" ]
then
  printf "\n\033[0;33mError: Can't find the deluge daemon port\033[0m\n"
  exit
fi

WEBPORT=$(app-ports show | grep -i "deluge web" | awk '{print $1}')
if [ -z "$WEBPORT" ]
then
  printf "\n\033[0;33mError: Can't find the deluge web port\033[0m\n"
  exit
fi

# Extract the Deulge username
USERNAME=$(grep -v "localclient" ~/.config/deluge/auth | cut -d":" -f1)
if [ -z "$USERNAME" ]
then
  printf "\n\033[0;33mError: Can't find the deluge username\033[0m\n"
  exit
fi

# Extract the Deulge password
PASSWORD=$(grep -v "localclient" ~/.config/deluge/auth | cut -d":" -f2)
if [ -z "$PASSWORD" ]
then
  printf "\n\033[0;33mError: Can't find the deluge password\033[0m\n"
  exit
fi

# Get all torrent ID's from deluge daemon
# Hiding error - yuck! - better to fix but can't do in a pssive manner here.
printf "\033[30;40m"
TORRENTS=($(deluge-console "connect \"127.0.0.1\":\"$DAEMONPORT\" \"$USERNAME\" \"$PASSWORD\"; info -v" | grep "ID:" | cut -c5-)) &> /dev/null
printf "\033[0m\n"
if [ -z "$TORRENTS" ]
then
  printf "\n\033[0;33mWarning: No torrents found\033[0m\n"
  exit
fi

# Create http header to communicate with deluge web
echo "request = \"POST\"
compressed
cookie = \"cookie_deluge.tmp\"
cookie-jar = \"cookie_deluge.tmp\"
header = \"Content-Type: application/json\"
header = \"Accept: application/json\"
url = \"http://localhost:${WEBPORT}/json\"
write-out = \"\\n\"
" > curl.tmp

# Authenticate and set session cookie
authenticated=$(curl -s -d "{\"method\": \"auth.login\", \"params\": [\"${PASSWORD}\"], \"id\": 1}" -K curl.tmp | grep -o '"result": true')
if [ -z "$authenticated" ] 
then
  printf "\n\033[0;33mError: Cannot connect to deluge web client\033[0m\n"
  exit
fi

# Iterate through each found torrent ID and extract filenames
rm delugefiles.tmp 2> /dev/null || true
for torrent in "${TORRENTS[@]}"
do
  fixencoding=$(curl -s -d "{\"method\": \"web.get_torrent_files\", \"params\": [\"$torrent\"], \"id\" : 1}" -K curl.tmp | grep -o 'path": "[^"]*' | grep -o '[^"]*$')
  echo -e "$fixencoding" >> delugefiles.tmp
done
sort -o delugefiles.tmp{,}

# Get list of files in torrent completed folder
find $COMPLETEDIR | sed "s|$COMPLETEDIR||" > completedfiles.tmp 
sort -o completedfiles.tmp{,}

# Run a diff to find files in COMPLETEDIR but not in Deluge
diff completedfiles.tmp delugefiles.tmp | grep '^<' | sed 's/^<\ //' | sed  "s|^|$COMPLETEDIR|" | tail -n +2 > orphaned_files.txt
sort -r -o orphaned_files.txt{,}

printf "\033[0;32mFiles on file system but not in deluge are in: \033[0;33morphaned_files.txt\033[0m\n"

printf "\nNo files are harmed during the making of utility\n"
printf "It is your responsibiity to remove the orphaned files. Review orphaned_files.txt NOW!\n\n"
printf "The following command attempts to delete all the files in orphaned_files.txt\n"
printf "\033[0;31mDANGER: Copy and paste this command at your own risk!\033[0m\n"
printf "\033[0;33mwhile read deletefiles; do  echo Deleting \"\$deletefiles\"; rm -d \"\$deletefiles\"; done < orphaned_files.txt ; rm orphaned_files.txt\033[0m\n"
printf "\033[0;31m************** YOU HAVE BEEN WARNED! **************\033[0m\n"

# Tidy up temp files
rm curl.tmp cookie_deluge.tmp delugefiles.tmp completedfiles.tmp 2> /dev/null || true

