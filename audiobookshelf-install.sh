#!/bin/bash

set -euo pipefail
BASE_DIR="${HOME}/.config/audiobookshelf"

#Disclaimer

printf "\033[0;31mDisclaimer: This installer is unofficial and Ultra.cc staff will not support any issues with it.\033[0m\n"
read -rp "Type confirm if you wish to continue: " input
if [ ! "$input" = "confirm" ]; then
    exit
fi

clear

cd "${HOME}" || exit 1

#Functions

port_picker() {
  port=''
  while [ -z "${port}" ]; do
    app-ports show
    echo "Pick any application from the list above, that you're not currently using."
    echo "We'll be using this port for audiobookshelf."
    read -rp "$(tput setaf 4)$(tput bold)Application name in full[Example: pyload]: $(tput sgr0)" appname
    proper_app_name=$(app-ports show | grep -i "${appname}" | head -n 1 | cut -c 7-) || proper_app_name=''
    port=$(app-ports show | grep -i "${appname}" | head -n 1 | awk '{print $1}') || port=''
    if [ -z "${port}" ]; then
      echo "$(tput setaf 1)Invalid choice! Please choose an application from the list and avoid typos.$(tput sgr0)"
      echo "$(tput bold)Listing all applications again..$(tput sgr0)"
      sleep 10
      clear
    elif netstat -ntpl | grep "${port}" > /dev/null 2>&1; then
      echo "$(tput setaf 1)Port ${port} is already in use by ${proper_app_name}.$(tput sgr0)"
      port=''
      echo "$(tput setaf 1)Please choose another application from the list.$(tput sgr0)"
      echo "$(tput bold)Listing all applications again..$(tput sgr0)"
      sleep 10
      clear
    fi
  done
  echo "$(tput setaf 2)Are you sure you want to use ${proper_app_name}'s port? type 'confirm' to proceed.$(tput sgr0)"
  read -r input
  if [ ! "${input}" = "confirm" ]; then
    exit
  fi
  echo
}

ask_yes_or_no() {
    echo "Input 1 or 2: "
    select choice in "Yes" "No"; do
        case ${choice} in
            Yes)
                break
                ;;
            No)
                exit 0
                ;;
            *) 
                exit 0
                ;;
        esac
    done
    echo
}

required_paths() {
    declare -a paths
    paths[1]="$BASE_DIR/ffmpeg"
    paths[2]="${HOME}/.config/systemd/user"
    paths[3]="${HOME}/.apps/nginx/proxy.d"
    paths[4]="${HOME}/bin"
    paths[5]="${HOME}/.apps/backup"

    for i in {1..5}; do
        if [ ! -d "${paths[${i}]}" ]; then
            mkdir -p "${paths[${i}]}"
        fi
    done
}

latest_version() {
    echo "Getting latest version of audiobookshelf.."
    LATEST_RELEASE="https://raw.githubusercontent.com/advplyr/audiobookshelf-ppa/master/"$(curl -s https://github.com/advplyr/audiobookshelf-ppa/ |
                   grep  -o "audiobookshelf_.*deb" | tail -1 | awk -F\" '{print $1'})
    mkdir -p "${HOME}/.audiobookshelf-tmp" && cd "${HOME}/.audiobookshelf-tmp"
    rm -rf "$BASE_DIR/audiobookshelf"
    wget -qO audiobookshelf.deb "${LATEST_RELEASE}" || {
        echo "Failed to get latest release of audiobookshelf." && exit 1
    }
    ar x audiobookshelf.deb data.tar.xz
    tar xf data.tar.xz
    cp usr/share/audiobookshelf/audiobookshelf "$BASE_DIR"
    cd "${HOME}" && rm -rf "${HOME}/.audiobookshelf-tmp"
    echo
}

latest_version_ffmpeg() {
    echo "Getting latest version of audiobookshelf-ffmpeg"
    mkdir -p "${HOME}/.audiobookshelf-ffmpeg-tmp" && cd "${HOME}/.audiobookshelf-ffmpeg-tmp"
    rm -rf "$BASE_DIR/ffmpeg/*"
    wget -qO ffmpeg.tar.xz "https://johnvansickle.com/ffmpeg/builds/ffmpeg-git-amd64-static.tar.xz" || {
        echo "Failed to get latest release of audiobookshelf-ffmpeg." && exit 1
    }

    tar xf ffmpeg.tar.xz -C "$BASE_DIR/ffmpeg" --strip-components 1
    cd "${HOME}" && rm -rf "${HOME}/.audiobookshelf-ffmpeg-tmp"
    echo
}


nginx_conf() {
    cat <<EOF | tee "${HOME}/.apps/nginx/proxy.d/audiobookshelf.conf" >/dev/null
location /audiobookshelf/ {
    proxy_pass                         http://127.0.0.1:${port};
    proxy_http_version                 1.1;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Host              \$host;
    proxy_set_header Upgrade           \$http_upgrade;
    proxy_set_header Connection        "upgrade";
}
EOF
    app-nginx restart
}

systemd_service() {
    cat <<EOF | tee "${HOME}"/.config/systemd/user/audiobookshelf.service >/dev/null
[Unit]
Description=Self-hosted audiobook server for managing and playing audiobooks

[Service]
Type=simple
Environment=SOURCE=local
Environment=PORT=${port}
Environment=CONFIG_PATH=$BASE_DIR/config
Environment=METADATA_PATH=$BASE_DIR/metadata
Environment=FFMPEG_PATH=$BASE_DIR/ffmpeg/ffmpeg
Environment=FFPROBE_PATH=$BASE_DIR/ffmpeg/ffprobe
WorkingDirectory=$BASE_DIR
ExecStart=$BASE_DIR/audiobookshelf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
}

create_backup() {
    backup="${HOME}/.apps/backup/audiobookshelf-$(date +%Y-%m-%d_%H-%M-%S).bak.tar.gz"
    echo
    echo "Creating a backup of the data directory.."
    tar -czf "${backup}" -C "${HOME}/.config/" "audiobookshelf" || {
        backup=''
        return 1
    }
    echo "Backup created."
}

uninstall() {
    echo
    echo "Uninstalling audiobookshelf.."
    if systemctl --user is-enabled --quiet "audiobookshelf.service" || [ -f "${HOME}/.config/systemd/user/audiobookshelf.service" ]; then
        systemctl --user stop audiobookshelf.service
        systemctl --user disable audiobookshelf.service
    fi
    create_backup || {
        echo "Failed to create a backup."
        echo "Do you still wish to continue?"
        ask_yes_or_no
    }
    rm -f "${HOME}/.config/systemd/user/audiobookshelf.service"
    systemctl --user daemon-reload
    systemctl --user reset-failed
    rm -rf "${HOME}/.config/audiobookshelf"
    rm -f "${HOME}/.apps/nginx/proxy.d/audiobookshelf.conf"
    app-nginx restart
    rm -rf "${HOME}/bin"/audiobookshelf*
    echo
    echo "Uninstallation Complete."
}

fresh_install() {
    if [ ! -d "${HOME}/.config/audiobookshelf" ]; then
        echo
        echo "Fresh install of audiobookshelf"
        sleep 3
        clear
        port_picker
        required_paths
        latest_version
        latest_version_ffmpeg
        systemd_service
        nginx_conf

        systemctl --user --quiet enable --now audiobookshelf.service
        sleep 3

        if systemctl --user is-active --quiet "audiobookshelf.service" && systemctl --user is-active --quiet "nginx.service"; then
            echo
            echo "audiobookshelf installation is complete."
#           echo "Access audiobookshelf at the following URL:https://${USER}.${HOSTNAME}.usbx.me/audiobookshelf"
            echo "Access audiobookshelf at the following URL:http://${HOSTNAME}.usbx.me:${port}"
            echo "Your library paths have to be entered manually as the File Browser function does not work"
            echo "Your path MUST start with $(pwd -P) followed with with path to your audio books. e.g. $(pwd -P)/media/AudioBooks"
            [ -n "${backup}" ] && echo "Backup of old instance has been saved at ${backup}."
            echo
            exit
        else
            echo "Something went wrong. Run the script again." && exit
        fi
    fi
}

# Script

backup=''
fresh_install

if [ -d "${HOME}/.config/audiobookshelf" ]; then
    echo "Old installation of audiobookshelf detected."
    echo "How do you wish to proceed? In all cases except quit, audiobookshelf will be backed up."

#    select status in 'Fresh Install' 'Update & Repair' 'Change Password' 'Uninstall' 'Quit'; do
     select status in 'Fresh Install' 'Uninstall' 'Quit'; do
        case ${status} in
        'Fresh Install')
            uninstall
            fresh_install
            break
            ;;
        'Update & Repair')
            systemctl --user stop audiobookshelf.service || {
                echo "audiobookshelf's systemd service not found. Update & Repair failed." && exit 1
            }
            create_backup || {
                echo "Failed to create a backup. Old install of audiobookshelf does not exist to update." && exit 1 
            }
            echo
            echo "Update & Repair"
            sleep 3
            clear
            port_picker
            required_paths
            latest_version
            nginx_conf
            systemd_service
            systemctl --user restart audiobookshelf.service
            echo "audiobookshelf has been updated."
            echo
            exit
            break
            ;;
        'Uninstall')
            uninstall
            [ -n "${backup}" ] && echo "Backup of old instance created at ${backup}."
            echo
            exit
            break
            ;;
        'Quit')
            exit 0
            ;;
        *)
            echo "Invalid option $REPLY."
            ;;
        esac
    done
fi
