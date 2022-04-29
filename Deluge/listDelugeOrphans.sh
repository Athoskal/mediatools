#!/bin/bash

# v002 - 2022-04-29
# Written by warp for use on ultra.cc.
# Tested on Deluge v1.3.15 without plugins that move completed downloads.
# Said plugins may break script.

# "WARNING: DO NOT RUN WITH -x ARGUMENT UNTIL YOU HAVE FULLY TESTEED THE CORRECT"
#             "FILES ARE IDENTIFIED. USED AT YOUR OWN RISK."

# Purpose is to create a list of files stored on disk in the deluge completed
# directory that are not referenced in deluge. This helps recover wasted space
# from files that were not deleted after removing from deluge and for files
# extracted  from archives that are not needed to successully seed.
# Leave enough time for copy/move/hardlink of files by *arrs before deleting
# media extracted from archives.

# Command line arguments:
# -s directory	Optional. Scan for files in "directory". If omitted, use
#               the default "Deluge=>Preferences=>Downloads=>Move completed to"
# -x directory  Optional. Move the orphaned files to this directory. Consider this
#               like a trash can. There is no option to delete files in this script
#               as it's too dangerouse for noobs. You can easily delete the files
#               from the trash can yourself with the rm -r command.

# Examples:
#   listDelugeOrphans
#        Scan the default download location and output orphaned_files.txt
#        No files will be moved from the default download location.
#
#   listDelugeOrphans -s /home/user/mydownloads/deluge
#        Scan the directory /home/user/mydownloads/deluge and output orphaned_filex.txt
#        No files will be moved from the specified -s download location.
#
#   listDelugeOrphans -x /home/user/trashcan
#        Scan the default download location and output orphaned_files.txt
#        Move orphaned files from the default download location to the specified -x location
#
#   listDelugeOrphans -s /home/user/mydownloads/deluge -x /home/user/trashcan
#        Scan the directory /home/user/mydownloads/deluge and output orphaned_filex.txt
#        Move orphaned files from the specified -s download location to the specified -x location


# Extract script arguments
while getopts ":s:x:" params; do
  case "${params}" in
    s)
      directory=${OPTARG}
      COMPLETEDIR=$(echo $directory | sed 's![^/]$!&/!')
      ;;
    x)
      directory=${OPTARG}
      TRASHCAN=$(echo $directory | sed 's![^/]$!&/!')
      [[ "$TRASHCAN" != /* ]] && TRASHCAN="$PWD/$TRASHCAN"
      [ ! -d "$TRASHCAN" ] && mkdir "$TRASHCAN"
      [ ! -w "$TRASHCAN" ] && printf "\033[0;33m$TRASHCAN is not writable\033[0m\n" && exit
      ;;
   :)
      printf "\033[0;33mError: -${OPTARG} requires a directory\033[0m\n"
      exit
      ;;
   *)
      printf "\033[0;33mError: Invalid argument\033[0m\n"
      exit
      ;;
  esac
done

# Set the directory to be scanned for orphans
if [ -z "$COMPLETEDIR" ]
then
  COMPLETEDIR=$(cat ~/.config/deluge/core.conf | grep "move_completed_path\"" | cut -d":" -f2 | cut -c2- | cut -d"," -f1 | sed 's/\"//g' | sed 's![^/]$!&/!')
  if [ -z "$COMPLETEDIR" ]
  then
    printf "\033[0;33mError: Can't extract deluge completed torrents directory\033[0m"
    exit
  fi
fi

if [ -d $COMPLETEDIR ]
then
  printf "\033[0;32mDirectory to scan:\033[0;33m $COMPLETEDIR\033[0m"
else
  printf "\033[0;33mError: directory $COMPLETEDIR does not exist\033[0m\n"
  exit
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

# Exit if nothing found
if [ ! -s "orphaned_files.txt" ]
then
  printf "\033[0;32mNo orphan files found\033[0m\n"
  rm "orphaned_files.txt"
  exit
fi

sort -r -o orphaned_files.txt{,}

# Determine whether to move files. If no files in deluge are in scan directory, abort as probably user entered wrong directory to scan!
if [ ! -z "$TRASHCAN" ]
then
  if [ $(awk 'a[$0]++' completedfiles.tmp delugefiles.tmp | wc -l) = 0 ]
  then
    printf "\033[0;31mWARNING:\033[0;32m Suspected incorrect scan directory detected. To protect your files the move has been cancelled.\033[0m\n"
    printf "\033[0;32mReview the files that would have been moved with this command: \033[0;33mcat $PWD/orphaned_files.txt\033[0m\n"
  else
    printf "\033[0;32mMoving files to trash can: \033[0;33m$TRASHCAN\033[0m\n"
    while read movefiles;
    do
      printf "\033[0;32mMoving \033[0;33m$movefiles\033[0m\n"
      mv -u "$movefiles" "$TRASHCAN" 
    done < orphaned_files.txt
    printf "\033[0;32mFinished. After checking, you can remove the trash can directory\033[0m\n"
    printf "\033[0;32mwith this command \033[0;33mrm -r \"$TRASHCAN\"\033[0m\n" 
  fi
else 
  printf "\033[0;32mFiles in \033[0;33m$COMPLETEDIR\033[0;32m but not in deluge have been written to: \033[0;33morphaned_files.txt\033[0m\n" 
  printf "\033[0;32mReview the files with this command: \033[0;33mcat $PWD/orphaned_files.txt\033[0m\n"
fi

# Tidy up temp files
rm curl.tmp cookie_deluge.tmp delugefiles.tmp completedfiles.tmp 2> /dev/null || true
