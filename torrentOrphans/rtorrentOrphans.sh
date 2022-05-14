#!/bin/bash

# v001 - 2022-05-01
# Written by warp for use on ultra.cc.
# Tested on rTorrent v0.9.6 without plugins that move completed downloads.
# Said plugins may break script.

# "WARNING: DO NOT RUN WITH -x ARGUMENT UNTIL YOU HAVE FULLY TESTEED THE CORRECT"
#             "FILES ARE IDENTIFIED. USED AT YOUR OWN RISK."

# Purpose is to create a list of files stored on disk in the rTorrent completed
# directory that are not referenced in rTorrent. This helps recover wasted space
# from files that were not deleted after removing from rTorrent and for files
# extracted  from archives that are not needed to successully seed.
# Leave enough time for copy/move/hardlink of files by *arrs before deleting
# media extracted from archives.

# Command line arguments:
# -p password   Required. Password to access RPC2 via ruTorrent
#
# -s directory	Optional. Scan for files in "directory". If omitted, use
#               the default "ruTorrent=>Settings=>Downloads=>Default directory for downloads"
#
# -x directory  Optional. Move the orphaned files to this directory. Consider this
#               like a trash can. There is no option to delete files in this script
#               as it's too dangerouse for noobs. You can easily delete the files
#               from the trash can yourself with the rm -r command.

# Examples:
#   rtorrentOrphans -p password
#        Scan the default download location and output orphaned_files.txt
#        No files will be moved from the default download location.
#
#   rtorrentOrphans -p password -s /home/user/mydownloads/rTorrent
#        Scan the directory /home/user/mydownloads/rTorrent and output orphaned_files.txt
#        No files will be moved from the specified -s download location.
#
#   rtorrentOrphans -p password -x /home/user/trashcan
#        Scan the default download location and output orphaned_files.txt
#        Move orphaned files from the default download location to the specified -x location
#
#   rtorrentOrphans -p password -s /home/user/mydownloads/rTorrent -x /home/user/trashcan
#        Scan the directory /home/user/mydownloads/rTorrent and output orphaned_files.txt
#        Move orphaned files from the specified -s download location to the specified -x location


# Extract script arguments
while getopts ":p:s:x:" params; do
  case "${params}" in
    p)
      PASSWORD=${OPTARG}
      ;;
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

# Check required password is set
if [ -z "$PASSWORD" ]
then
  printf "\n\033[0;33mError: you must provide the rTorrent RPC password with -p <password>\033[0m\n"
  exit
fi

# Set the directory to be scanned for orphans
if [ -z "$COMPLETEDIR" ]
then
  COMPLETEDIR=$(cat ~/.rtorrent.rc | grep "directory.default.set" | cut -d"=" -f2 | xargs | sed 's![^/]$!&/!')
  if [ -z $COMPLETEDIR ]
  then
    printf "\033[0;33mError: Can't extract rTorrent download directory\033[0m"
    exit
  fi
fi

COMPLETEDIR="${COMPLETEDIR/#\~/$HOME}"
if [ -d $COMPLETEDIR ]
then
  printf "\033[0;32mDirectory to scan:\033[0;33m $COMPLETEDIR\033[0m\n"
else
  printf "\033[0;33mError: directory $COMPLETEDIR does not exist\033[0m\n"
  exit
fi

# Get all torrent ID's from rTorrent daemon
curl -s -d  '<methodCall><methodName>d.multicall2</methodName><params><param><value><string></string></value></param><param><value><string></string></value></param><param><value><string>d.hash=</string></value></param><param><value><string>d.directory=</string></value></param></params></methodCall>' \
             https://$USER:$PASSWORD@$USER.$(hostname).usbx.me/RPC2 | grep -oP '(?<=string\>).*(?=\</string)' | sed '$!N;s/\n/|/' > torrents.tmp

if [ ! -s "torrents.tmp" ]
then
  printf "\n\033[0;33mWarning: No torrents found\033[0m\n"
  exit
fi

# Iterate through each found torrent ID and extract filenames
rm rTorrentfiles.tmp 2> /dev/null || true
while read torrentinfo
do
  torrent=$(echo "$torrentinfo" | cut -d"|" -f1)
  path=$(echo "$torrentinfo" | cut -d"|" -f2)
  curl -s -d "<methodCall><methodName>f.multicall</methodName><params><param><value><string>$torrent</string></value></param><param><value><string></string></value></param><param><value><string>f.path=</string></value></param></params></methodCall>" \
                https://$USER:$PASSWORD@$USER.$(hostname).usbx.me/RPC2 |
                grep -oP '(?<=string\>).*?(?=\</string)' > files.tmp
  if [ -s "torrents.tmp" ]
  then
    while read files
    do
      echo -e "$path/$files" | php -r 'while(($line=fgets(STDIN)) !== FALSE) echo html_entity_decode($line, ENT_QUOTES|ENT_HTML401);' >> rTorrentfiles.tmp
    done < files.tmp
  fi
done < torrents.tmp

sort -u rTorrentfiles.tmp | sort -o rTorrentfiles.tmp{,}


# Get list of files in torrent completed folder
find $COMPLETEDIR -type f > completedfiles.tmp
sort -o completedfiles.tmp{,}

# Run a diff to find files in COMPLETEDIR but not in rTorrent
diff completedfiles.tmp rTorrentfiles.tmp | grep '^<' | sed 's/^<\ //' | tail -n +2 > orphaned_files.txt

# Exit if nothing found
if [ ! -s "orphaned_files.txt" ]
then
  printf "\033[0;32mNo orphan files found\033[0m\n"
  rm "orphaned_files.txt"
  exit
fi

# Move orphaned files to trash directory
if [ ! -z "$TRASHCAN" ]
then
  printf "\033[0;32mMoving files to trash can: \033[0;33m$TRASHCAN\033[0m\n"
  while read movefiles;
  do
    printf "\033[0;32mMoving \033[0;33m$movefiles\033[0m\n"
    if [ -e "$movefiles" ]
    then
      trashdir="$TRASHCAN"$(echo $(dirname """$movefiles""") | sed "s|$COMPLETEDIR||")
      [ ! -e "$trashdir" ] && mkdir -p "$trashdir"
      mv "$movefiles" "$TRASHCAN${movefiles/$COMPLETEDIR}"
    fi
  done < orphaned_files.txt
  find "$COMPLETEDIR" -type d -empty -delete
  printf "\033[0;32mFinished. After checking, you can remove the trash can directory\033[0m\n"
  printf "\033[0;32mwith this command \033[0;33mrm -r \"$TRASHCAN\"\033[0m\n" 
else
  printf "\033[0;32mFiles in \033[0;33m$COMPLETEDIR\033[0;32m but not in rTorrent have been written to: \033[0;33morphaned_files.txt\033[0m\n" 
  printf "\033[0;32mReview the files with this command: \033[0;33mcat $PWD/orphaned_files.txt\033[0m\n"
fi

# Tidy up temp files
rm rTorrentfiles.tmp completedfiles.tmp torrents.tmp files.tmp 2> /dev/null || true
