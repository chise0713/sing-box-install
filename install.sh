#!/usr/bin/bash
set -e
ERROR="\e[1;31m"
WARN="\e[93m"
END="\e[0m"

ACTION=
TAGS=
TYPE=
GO_TYPE=
REMOVE_TYPE=
BETA=false
WIN=false
PURGE=false
CGO_ENABLED=0
RESTART_TEMP=$(mktemp)
BRANCH=
PREFIX=
CURRENT_USER=
CURRENT_GROUP=
NEED_REMOVE_TEMP="$(mktemp)"
NEED_REMOVE=( "$RESTART_TEMP" "$NEED_REMOVE_TEMP" )
REMOVE_TEMP=false

identify_the_operating_system_and_architecture() {
  if ! [[ "$(uname)" == 'Linux' ]]; then
    echo "${ERROR}ERROR:${END} This operating system is not supported."
    exit 1
  fi
  case "$(uname -m)" in
    'i386' | 'i686')
      MACHINE='386'
      ;;
    'amd64' | 'x86_64')
      MACHINE='amd64'
      ;;
    'armv5tel')
      MACHINE='arm'
      ;;
    'armv6l')
      MACHINE='arm'
      ;;
    'armv7' | 'armv7l')
      MACHINE='arm'
      ;;
    'armv8' | 'aarch64')
      MACHINE='arm64'
      ;;
    'mips')
      MACHINE='mips'
      ;;
    'mipsle')
      MACHINE='mipsle'
      ;;
    'mips64')
      MACHINE='mips64'
      lscpu | grep -q "Little Endian" && MACHINE='mips64le'
      ;;
    'mips64le')
      MACHINE='mips64le'
      ;;
    'ppc64')
      MACHINE='ppc64'
      ;;
    'ppc64le')
      MACHINE='ppc64le'
      ;;
    's390x')
      MACHINE='s390x'
      ;;
    *)
      echo "${ERROR}ERROR:${END} The architecture is not supported."
      exit 1
      ;;
  esac
  if [[ ! -f '/etc/os-release' ]]; then
    echo "${ERROR}ERROR:${END} Don't use outdated Linux distributions."
    exit 1
  fi
  # Do not combine this judgment condition with the following judgment condition.
  ## Be aware of Linux distribution like Gentoo, which kernel supports switch between Systemd and OpenRC.
  if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc' /proc/1/cgroup && [[ "$(type -P systemctl)" ]]; then
    true
  elif [[ -d /run/systemd/system ]] || grep -q systemd <(ls -l /usr/bin/init); then
    true
  else
    echo "${ERROR}ERROR:${END} Only Linux distributions using systemd are supported."
    exit 1
  fi
  if [[ "$(type -P apt)" ]]; then
    PACKAGE_MANAGEMENT_INSTALL='apt -y --no-install-recommends install'
    PACKAGE_MANAGEMENT_REMOVE='apt purge'
    package_provide_tput='ncurses-bin'
  elif [[ "$(type -P dnf)" ]]; then
    PACKAGE_MANAGEMENT_INSTALL='dnf -y install'
    PACKAGE_MANAGEMENT_REMOVE='dnf remove'
    package_provide_tput='ncurses'
  elif [[ "$(type -P yum)" ]]; then
    PACKAGE_MANAGEMENT_INSTALL='yum -y install'
    PACKAGE_MANAGEMENT_REMOVE='yum remove'
    package_provide_tput='ncurses'
  elif [[ "$(type -P zypper)" ]]; then
    PACKAGE_MANAGEMENT_INSTALL='zypper install -y --no-recommends'
    PACKAGE_MANAGEMENT_REMOVE='zypper remove'
    package_provide_tput='ncurses-utils'
  elif [[ "$(type -P pacman)" ]]; then
    PACKAGE_MANAGEMENT_INSTALL='pacman -Syy --noconfirm'
    PACKAGE_MANAGEMENT_REMOVE='pacman -Rsn'
    package_provide_tput='ncurses'
  elif [[ "$(type -P emerge)" ]]; then
    PACKAGE_MANAGEMENT_INSTALL='emerge -qv'
    PACKAGE_MANAGEMENT_REMOVE='emerge -Cv'
    package_provide_tput='ncurses'
  else
    echo "${ERROR}ERROR:${END} The script does not support the package manager in this operating system."
    exit 1
  fi
}

install_software() {
  package_name="$1"
  file_to_detect="$2"
  type -P "$file_to_detect" > /dev/null 2>&1 && return
  [[ $EUID != 0 ]] && echo -e "${ERROR}ERROR:${END} You need to install \"$package_name\" first." && exit 1
  echo -e "${WARN}WARN:${END} $package_name not installed, installing." && sleep 1
  if ${PACKAGE_MANAGEMENT_INSTALL} "$package_name"; then
    echo "INFO: $package_name is installed."
  else
    echo "${ERROR}ERROR:${END} Installation of $package_name failed, please check your network."
    exit 1
  fi
}

install_file() {
  if [[ "$1" == "/dev/stdin" ]];then
    STDIN=$(mktemp)
    cat /dev/stdin > $STDIN
    local SOURCE=$STDIN DEST=$2 METHO=$3
  else
    local SOURCE=$1 DEST=$2 METHO=$3
  fi

  if [[ ! -z "$5" ]];then
    OWNER=$4 GROUP=$5
  else
    OWNER=$CURRENT_USER GROUP=$CURRENT_GROUP
  fi

  if install $SOURCE $DEST -m $METHO -o $OWNER -g $GROUP;then
    echo -e "Installed: \"$DEST\""
  else
    echo -e "${ERROR}ERROR:${END} Failed to Install \"$DEST\""
    exit 1
  fi

  if ! [[ -z $STDIN ]];then
    echo $STDIN >> $NEED_REMOVE_TEMP
  fi
}

install_directory() {
  if [[ ! -z "$2" ]];then
    DIRECTORY=$1 METHO=$2
    if [[ ! -z "$4" ]];then
      OWNER=$3 GROUP=$4
    else
      OWNER=$CURRENT_USER GROUP=$CURRENT_GROUP
    fi
  else
    exit 1
  fi

  if install -dm $METHO $DIRECTORY -o $OWNER -g $GROUP;then
    echo -e "Installed: \"$DIRECTORY\""
  else
    echo -e "${ERROR}ERROR:${END} Failed to Install \"$DIRECTORY\""
    exit 1
  fi
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${ERROR}ERROR:${END} You have to use root to run this script"
    exit 1
  fi
}

curl() {
  if ! $(type -P curl) -# -L -q --retry 5 --retry-delay 5 --retry-max-time 60 "$@";then
    echo -e "${ERROR}ERROR:${END} Curl Failed, check your network"
    exit 1
  fi
}

install_building_components() {
  if [[ $PACKAGE_MANAGEMENT_INSTALL == 'apt -y --no-install-recommends install' ]]; then
    [[ $EUID != 0 ]] && echo -e "${ERROR}ERROR:${END} You need to install \"build-essential\" first." && exit 1
    if ! dpkg -l | awk '{print $2"\t","Version="$3,"ARCH="$4}' | grep build-essential ;then
      echo -e "${WARN}WARN:${END} Building components not found, Installing."
      ${PACKAGE_MANAGEMENT_INSTALL} build-essential
    fi
  elif [[ $PACKAGE_MANAGEMENT_INSTALL == 'dnf -y install' ]]; then
    [[ $EUID != 0 ]] && echo -e "${ERROR}ERROR:${END} You need to install \"Development Tools\" first." && exit 1
    if ! dnf list installed "Development Tools";then
      echo -e "${WARN}WARN:${END} Building components not found, Installing."
      ${PACKAGE_MANAGEMENT_INSTALL} "Development Tools"
    fi
  elif [[ $PACKAGE_MANAGEMENT_INSTALL == 'yum -y install' ]]; then
    [[ $EUID != 0 ]] && echo -e "${ERROR}ERROR:${END} You need to install \"Development Tools\" first." && exit 1
    if ! yum list installed "Development Tools";then
      echo -e "${WARN}WARN:${END} Building components not found, Installing."
      ${PACKAGE_MANAGEMENT_INSTALL} "Development Tools"
    fi
  elif [[ $PACKAGE_MANAGEMENT_INSTALL == 'zypper install -y --no-recommends' ]]; then
    [[ $EUID != 0 ]] && echo -e "${ERROR}ERROR:${END} You need to install \"gcc\" first." && exit 1
    if ! zypper se --installed-only gcc;then
      echo -e "${WARN}WARN:${END} Building components not found, Installing."
      ${PACKAGE_MANAGEMENT_INSTALL} gcc
    fi
  elif [[ $PACKAGE_MANAGEMENT_INSTALL == 'pacman -Syy --noconfirm' ]]; then
    [[ $EUID != 0 ]] && echo -e "${ERROR}ERROR:${END} You need to install \"base-devel\" first." && exit 1
    if ! pacman -Q base-devel;then
      echo -e "${WARN}WARN:${END} Building components not found, Installing."
      ${PACKAGE_MANAGEMENT_INSTALL} base-devel
    fi
  elif [[ $PACKAGE_MANAGEMENT_INSTALL == 'emerge -qv' ]]; then
    [[ $EUID != 0 ]] && echo -e "${ERROR}ERROR:${END} You need to install \"sys-devel/base-system\" first." && exit 1
    if ! emerge -p sys-devel/base-system;then
      echo -e "${WARN}WARN:${END} Building components not found, Installing."
      ${PACKAGE_MANAGEMENT_INSTALL} sys-devel/base-system
    fi
  fi
}

go_install() {
  [[ -z $PREFIX ]] && local PREFIX=$HOME/.cache
  ! [[ -d $PREFIX ]] && mkdir -p $PREFIX
  if [[ $REMOVE_TEMP == true ]];then
    NEED_REMOVE+=( "$PREFIX/sing-box" "$PREFIX/go" )
    remove_files
    exit 0
  fi
  if ! GO_PATH=$(type -P go);then
    [[ $EUID == 0 ]] && bash -c "$(curl -L https://github.com/chise0713/go-install/raw/master/install.sh)" @ install
    if [[ $EUID != 0 ]];then
      PATH="$PATH:$HOME/.cache/go/bin"     
      if ! GO_PATH=$(type -P go);then
        bash -c "$(curl -L https://github.com/chise0713/go-install/raw/master/install.sh)" @ install --path="$PREFIX"
      else
        echo "INFO: GO Found, PATH=$GO_PATH"
      fi
    fi
  else
    echo "INFO: GO Found, PATH=$GO_PATH"
  fi
  install_software "git" "git"
  [[ -z $BRANCH ]] && BRANCH="main-next"
  echo -e "INFO: Current compile \"releaseTag / branch\" is $BRANCH"
  BRANCH="origin/$BRANCH"
  if [[ $WIN == true ]];then 
    export GOOS=windows
    export GOARCH=amd64
    export GOAMD64=v3
  elif [[ $WIN == false ]];then
    if [[ $MACHINE == amd64 ]];then
      case "$(lscpu)" in
        *avx2*)
        export GOAMD=v3
        ;;
        *sse4_2*)
        export GOAMD=v2
        ;;
      esac
    fi
    export GOARCH=$MACHINE
  fi

  if [[ $CGO_ENABLED == 0 ]];then
    export CGO_ENABLED=0
  elif [[ $CGO_ENABLED == 1 ]];then
    export CGO_ENABLED=1
    install_building_components
  fi
  
  if grep -oqP with_lwip <<<"$TAGS" && [[ $CGO_ENABLED == 0 ]];then
    echo -e "${ERROR}ERROR:${END} Tag with_lwip \e[1mMUST HAVE environment variable CGO_ENABLED=1${END}\nExiting."
    exit 1
  fi

  if grep -oqP with_embedded_tor <<<"$TAGS" && [[ $CGO_ENABLED == 0 ]];then
    echo -e "${ERROR}ERROR:${END} Tag with_embedded_tor \e[1mMUST HAVE environment variable CGO_ENABLED=1${END}\nExiting."
    exit 1
  fi

  if [[ $GO_TYPE == default ]];then
    echo -e "\
Using offcial default Tags: with_gvisor,with_quic,with_dhcp,with_wireguard,with_ech,with_utls,with_reality_server,with_clash_api.\
"
    TAGS="with_gvisor,with_quic,with_dhcp,with_wireguard,with_ech,with_utls,with_reality_server,with_clash_api"
  elif [[ $GO_TYPE == custom ]]; then
    echo -e "\
Using custom config:
Tags: $TAGS\
"
  fi
  if ! [ -d $PREFIX/sing-box ];then
    if !(cd $PREFIX && git clone https://github.com/SagerNet/sing-box.git) ;then
      echo -e "${ERROR}ERROR:${END} Failed to clone repository, check your permission."
      exit 1
    fi
    if ! cd $PREFIX/sing-box;then
      echo -e "${ERROR}ERROR:${END} Failed to cd $PREFIX/sing-box"
      exit 1
    fi
  else
    if ! [ -w $PREFIX/sing-box ];then
      echo -e "${ERROR}ERROR:${END} No permission to write $PREFIX/sing-box."
      exit 1
    fi
    cd $PREFIX/sing-box
  fi
  if grep -qoP "v\d+\.\d+\.\d+.*" <<<"$BRANCH";then
    BRANCH="${BRANCH#origin/}"
  fi
  if ! (git checkout -b tmp 2>/dev/null || git checkout tmp && git fetch origin --tags -f && git fetch origin -f && git reset --hard $BRANCH);then
    echo -e "${ERROR}ERROR:${END} Failed to fetch and update repository."
    exit 1
  fi
  if ! go build -v -tags $TAGS -trimpath -ldflags "-X github.com/sagernet/sing-box/constant.Version=$(git describe --tags --always --dirty|sed 's/v//g') -s -w -buildid=" ./cmd/sing-box;then
    echo -e "${ERROR}ERROR:${END} Go build Failed.\nExiting."
    exit 1
  fi
  if [[ $WIN == false ]];then
    if [[ $ACTION == compile ]];then
      install_file $PREFIX/sing-box/sing-box $HOME/sing-box 755
      remove_files
      exit 0
    fi
  install_file $PREFIX/sing-box/sing-box /usr/local/bin/sing-box 755
  elif [[ $WIN == true ]];then
    install_file $PREFIX/sing-box/sing-box.exe $HOME/sing-box.exe 755
    remove_files
    exit 0
  fi
}

curl_install() {
  [[ $MACHINE == amd64 ]] && CURL_MACHINE=amd64
  [[ $MACHINE == arm ]] && CURL_MACHINE=armv7
  [[ $MACHINE == arm64 ]] && CURL_MACHINE=arm64
  [[ $MACHINE == s390x ]] && CURL_MACHINE=s390x
  if ! ([[ $CURL_MACHINE == amd64 ]] || [[ $CURL_MACHINE == arm64 ]] || [[ $CURL_MACHINE == armv7 ]] || [[ $CURL_MACHINE == s390x ]]); then
    echo -e "\
Machine Type Not Support
Try to use \"--type=go\" to install\
"
    exit 1
  fi

  if [[ "$(curl https://api.github.com/)" == *"\"message\":\"API rate limit exceeded for"* ]];then
    echo -e "${ERROR}ERROR:${END} API rate limit exceeded"
    exit 1
  fi

  if [[ -z $SING_VERSION ]];then
    if [[ $BETA == false ]];then
      SING_VERSION=$(curl https://api.github.com/repos/SagerNet/sing-box/releases | grep -oP "sing-box-\d+\.\d+\.\d+-linux-$CURL_MACHINE"| sort -Vru | head -n 1)
      echo "Newest version found: $SING_VERSION"
    elif [[ $BETA == true ]];then
      SING_VERSION=$(curl https://api.github.com/repos/SagerNet/sing-box/releases | grep -oP "sing-box-\d+\.\d+\.\d+.*-linux-$CURL_MACHINE"| sed "s/-linux-$CURL_MACHINE$/-zzzzz-linux-$CURL_MACHINE/" | sort -Vru | sed "s/-zzzzz-linux-$CURL_MACHINE$/-linux-$CURL_MACHINE/" | head -n 1)
      echo "Newest version found: $SING_VERSION"
      CURL_TAG=$(echo $SING_VERSION | grep -oP "\d+\.\d+\.\d+.*\.\d+" || echo $SING_VERSION | grep -oP "\d+\.\d+\.\d+")
    fi
  else
    CURL_TAG=$SING_VERSION
    if curl -L \
    https://github.com/SagerNet/sing-box/releases/download/v$CURL_TAG/sing-box-$SING_VERSION-linux-$CURL_MACHINE.tar.gz \
    --range 0-721 | grep 'Not Found'>/dev/null;then
      echo "No such a version."
      exit 1
    else
      SING_VERSION=$(echo "$SING_VERSION" | sed "s/$SING_VERSION/sing-box-$SING_VERSION-linux-$CURL_MACHINE/")
    fi
  fi

  if [ -f /usr/local/bin/sing-box ];then
    CURRENT_SING_VERSION=$(sing-box version | grep -oP "sing-box version \d+\.\d+\.\d+.*" | grep -oP "\d+\.\d+\.\d+.*")
    if grep -q "sing-box-$CURRENT_SING_VERSION-linux-$CURL_MACHINE" <<< "$SING_VERSION";then
      echo "INFO: Your sing-box is up to date"
      return 0
    fi
  fi

  if [[ -z $CURL_TAG ]];then 
    curl -o /tmp/$SING_VERSION.tar.gz https://github.com/SagerNet/sing-box/releases/latest/download/$SING_VERSION.tar.gz
  else
    curl -o /tmp/$SING_VERSION.tar.gz https://github.com/SagerNet/sing-box/releases/download/v$CURL_TAG/$SING_VERSION.tar.gz
  fi

  tar -xzf /tmp/$SING_VERSION.tar.gz -C /tmp
  install_file /tmp/$SING_VERSION/sing-box /usr/local/bin/sing-box 755
  echo -e "/tmp/$SING_VERSION.tar.gz\n/tmp/$SING_VERSION/" >> $NEED_REMOVE_TEMP
  echo true > $RESTART_TEMP
}

service_control() {
  restart(){
    if systemctl is-active --quiet sing-box.service; then
      echo "INFO: sing-box.service is running, restarting it"
      if ! systemctl restart sing-box.service;then
        echo -e "${ERROR}ERROR:${END} Failed to restart sing-box\nExiting."
        exit 1
      fi
    else
      echo "INFO: sing-box.service not running."
    fi
    services=$(systemctl list-units --full --all | grep 'sing-box@.*\.service' | grep running | awk '{print $1}')
    for service in $services;do
      echo "INFO: $service.service is running, restarting it"
      systemctl restart $service || ( echo -e "${ERROR}ERROR:${END} Failed to restart $service\nExiting." && exit 1 )
    done
  }
  start(){
    if systemctl start sing-box.service;then
      echo "INFO: Started sing-box.service."
    else
      echo -e "${ERROR}ERROR:${END} Failed to start sing-box\nExiting."
      exit 1
    fi
  }
  $1
}

service_file() {
  sing-box(){
    cat <<EOF
# In case you have a good reason to do so, goto the sing-box.service.d directory and make your customizes there.
# Or all changes you made will be lost!  # Refer: https://www.freedesktop.org/software/systemd/man/systemd.unit.html
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=$INSTALL_USER
WorkingDirectory=/var/lib/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
  }
  sing-box@(){
    cat <<EOF
# In case you have a good reason to do so, goto the sing-box@.service.d directory and make your customizes there.
# Or all changes you made will be lost!  # Refer: https://www.freedesktop.org/software/systemd/man/systemd.unit.html
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=$INSTALL_USER
WorkingDirectory=/var/lib/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/%i.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
  }
  sing-box-donot_touch(){
    cat <<EOF
# In case you have a good reason to do so, duplicate this file in the same directory and make your customizes there.
# Or all changes you made will be lost!  # Refer: https://www.freedesktop.org/software/systemd/man/systemd.unit.html
[Service]
ExecStart=
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json
EOF
  }
  sing-box@-donot_touch(){
    cat <<EOF
# In case you have a good reason to do so, duplicate this file in the same directory and make your customizes there.
# Or all changes you made will be lost!  # Refer: https://www.freedesktop.org/software/systemd/man/systemd.unit.html
[Service]
ExecStart=
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/%i.json
EOF
  }
  $1
}

install_service() {
  if [ -f /etc/systemd/system/sing-box.service ];then
    WAS_INSTALLED=true
    if [[ "$(service_file sing-box)" == "$(cat /etc/systemd/system/sing-box.service)" ]] && \
       [[ "$(service_file sing-box@)" == "$(cat /etc/systemd/system/sing-box@.service)" ]] && \
       [[ "$(service_file sing-box-donot_touch)" == "$(cat /etc/systemd/system/sing-box.service.d/10-donot_touch.conf)" ]] && \
       [[ "$(service_file sing-box@-donot_touch)" == "$(cat /etc/systemd/system/sing-box@.service.d/10-donot_touch.conf)" ]];then
      return 0
    fi
  fi

  service_file sing-box | install_file /dev/stdin /etc/systemd/system/sing-box.service 644
  if ! [ -d /etc/systemd/system/sing-box.service.d/ ];then
    install_directory /etc/systemd/system/sing-box.service.d/ 744
  fi
  service_file sing-box-donot_touch | install_file /dev/stdin /etc/systemd/system/sing-box.service.d/10-donot_touch.conf 644

  service_file sing-box@ | install_file /dev/stdin /etc/systemd/system/sing-box@.service 644
  if ! [ -d /etc/systemd/system/sing-box@.service.d/ ];then
    install_directory /etc/systemd/system/sing-box@.service.d/ 744
  fi
  service_file sing-box@-donot_touch | install_file /dev/stdin /etc/systemd/system/sing-box@.service.d/10-donot_touch.conf 644

  
  systemctl daemon-reload

  [[ $WAS_INSTALLED == true ]] && return 0

  wait $PID

  if systemctl enable sing-box ;then
    echo "INFO: Enabled sing-box.service"
    service_control start
    echo -n 'false' > $RESTART_TEMP
  else
    echo -e "${ERROR}ERROR:${END} Failed to enable sing-box.service"
    exit 1
  fi
}

install_config() {
  if [ ! -d /usr/local/etc/sing-box ];then
    install_directory /usr/local/etc/sing-box/ 700 $INSTALL_USER $INSTALL_GROUP
    echo -e "{\n\n}" | install_file /dev/stdin /usr/local/etc/sing-box/config.json 700 $INSTALL_USER $INSTALL_GROUP
  fi

  if [ -d /usr/local/share/sing-box ];then
    if mv /usr/local/share/sing-box /var/lib/sing-box -T;then
      echo -e "${WARN}WARN:${END} Migrated: \"/usr/local/share/sing-box\" to \"/var/lib/sing-box\""
    else
      echo -e "${ERROR}ERROR:${END} Failed to migrate \"/usr/local/share/sing-box\" to \"/var/lib/sing-box\""
      exit 1
    fi
  fi

  if [ ! -d /var/lib/sing-box ];then
    install_directory /var/lib/sing-box/ 700 $INSTALL_USER $INSTALL_GROUP
  fi
  chown -R $INSTALL_USER:$INSTALL_GROUP /usr/local/etc/sing-box/
}

install_user() {
  if ! getent passwd $INSTALL_USER>/dev/null;then
    useradd -c "sing-box service" -d /var/lib/sing-box -s /bin/nologin $INSTALL_USER
    SING_BOX_UID=$(id $INSTALL_USER -u) && SING_BOX_GID=$(id $INSTALL_USER -g)
    echo -e "Creating group '$INSTALL_USER' with GID $SING_BOX_GID."
    echo -e "Creating user '$INSTALL_USER' (sing-box service) with UID $SING_BOX_UID and GID $SING_BOX_GID."
    INSTALL_GROUP=$SING_BOX_GID
  fi
}

get_user() {
  if [[ -z $CURRENT_USER ]];then
    CURRENT_USER=$(whoami | awk '{print $1}')
  fi
  if [[ -z $CURRENT_GROUP ]];then
    CURRENT_GROUP=$(groups $CURRENT_USER | awk '{printf $1}')
  fi
}

install_compiletion() {
  if ! [ -f /usr/share/bash-completion/completions/sing-box ];then
    mkdir -p /usr/share/bash-completion/completions/
    sing-box completion bash | install_file "/dev/stdin" "/usr/share/bash-completion/completions/sing-box" 644
  fi
  if ! [ -f /usr/share/fish/vendor_completions.d/sing-box.fish ];then
    mkdir -p /usr/share/fish/vendor_completions.d/
    sing-box completion fish | install_file "/dev/stdin" "/usr/share/fish/vendor_completions.d/sing-box.fish" 644
  fi
  if ! [ -f /usr/share/zsh/site-functions/_sing-box ];then
    mkdir -p /usr/share/zsh/site-functions/
    sing-box completion zsh | install_file "/dev/stdin" "/usr/share/zsh/site-functions/_sing-box" 644
  fi
}

remove_files() {
  for file in "${NEED_REMOVE[@]}"; do
      if [[ -d $file ]] || [[ -f $file ]];then
        rm -rf $file || (echo -e "${ERROR}ERROR:${END} Failed remove $file" && exit 1)
        if echo $file | grep -E ".*/$">/dev/null ;then
          echo "Removed directory \"$file\""
        else
          echo "Removed \"$file\""
        fi
      fi
  done
}

uninstall() {
  if ! ([ -f /etc/systemd/system/sing-box.service ] || [ -f /usr/local/bin/sing-box ]) ;then
    echo -e "sing-box is not installed.\nExiting."
    exit 1
  fi
  if [ -f /etc/systemd/system/sing-box.service ];then
    if systemctl stop sing-box && systemctl disable sing-box ;then
      echo -e "INFO: Stoped and disabled sing-box.service"
    else
      echo -e "${ERROR}ERROR:${END} Failed to Stop and disable sing-box.service"
      exit 1
    fi
  fi

  NEED_REMOVE+=(
    '/etc/systemd/system/sing-box.service'
    '/etc/systemd/system/sing-box@.service'
    '/etc/systemd/system/sing-box.service.d/'
    '/etc/systemd/system/sing-box@.service.d/'
    '/usr/local/bin/sing-box'
    '/usr/lib/sysusers.d/sing-box.conf'
    '/usr/share/bash-completion/completions/sing-box'
    '/usr/share/fish/vendor_completions.d/sing-box.fish'
    '/usr/share/zsh/site-functions/_sing-box'
  )

  if [[ $PURGE == true ]];then
    NEED_REMOVE+=( '/usr/local/etc/sing-box/' '/var/lib/sing-box/' '/usr/local/share/sing-box' )
  fi
  remove_files
  if getent passwd sing-box>/dev/null;then
    SING_BOX_UID=$(id sing-box -u) && SING_BOX_GID=$(id sing-box -g)
    echo -e "Deleting group 'sing-box' with GID $SING_BOX_GID."
    userdel sing-box
    echo -e "Deleting user 'sing-box' (sing-box service) with UID $SING_BOX_UID and GID $SING_BOX_GID."
  fi

  systemctl daemon-reload
  
  exit 0
}

judgment() {
for arg in "$@"; do
  case $arg in
    --purge)
      PURGE=true
      ;;
    --win)
      WIN=true
      TYPE="go"
      ;;
    --user=*)
      INSTALL_USER="${arg#*=}"
      ;;
    --beta)
      BETA=true
      ;;
    --go)
      TYPE="go"
      ;;
    --cgo)
      CGO_ENABLED=1
      TYPE="go"
      ;;
    --tag=*)
      TAGS="${arg#*=}"
      GO_TYPE="custom"
      TYPE="go"
      ;;
    --version=*)
      SING_VERSION="${arg#*=}"
      ;;
    --branch=*)
      BRANCH="${arg#*=}"
      TYPE="go"
      ;;
    --prefix=*)
      PREFIX="${arg#*=}"
      TYPE="go"
      ;;
    help)
      help
      ;;
    remove)
      ACTION="uninstall"
      ;;
    install)
      ACTION="install"
      ;;
    compile)
      ACTION="compile"
      ;;
    --rm)
      REMOVE_TEMP=true
      ;;
    *)
      echo "Invalid argument: $arg"
      exit 1
      ;;
  esac
done
}

main() {
  judgment "$@"
  get_user
  identify_the_operating_system_and_architecture
  if [[ -z $ACTION ]];then
    echo "No action specified."
    help
  fi
  [[ $ACTION == uninstall ]] && check_root && uninstall

  if [[ $ACTION == compile ]];then
    [[ -z $GO_TYPE ]] && GO_TYPE=default
    go_install
    echo -e "${ERROR}ERROR:${END} How did we get here."
    exit 1
  fi

  if [[ $TYPE == go ]];then
    [[ -z $GO_TYPE ]] && GO_TYPE=default
    [[ $WIN == false ]] && check_root
    go_install &
    PID=$!
  else
    check_root
    curl_install &
    PID=$!
  fi

  if [[ $WIN == false ]];then
    if [[ -z $INSTALL_USER ]];then
      INSTALL_USER=sing-box
      install_user
    else
      if ! getent passwd $INSTALL_USER >/dev/null;then
        echo -e "${ERROR}ERROR:${END} No such a user $INSTALL_USER"
        exit 1
      fi
    fi
    [[ -z $INSTALL_GROUP ]] && INSTALL_GROUP=$(groups $INSTALL_USER | awk '{printf $1}')
    install_config
    install_service
    install_compiletion
  fi

  wait $PID

  RESTART=$(cat $RESTART_TEMP)
  if [[ $RESTART == true ]];then
    service_control restart
  fi
  
  for tmp in $(cat $NEED_REMOVE_TEMP); do
    NEED_REMOVE+=( "$tmp" )
  done
  NEED_REMOVE+=( "$NEED_REMOVE_TEMP" )
  echo -e "INFO: Removing temporary files."
  remove_files

  echo -e "INFO: sing-box is installed."

  exit 0
}

help() {
  echo -e "\
Thanks \033[38;5;208m@chika0801${END}.
usage: install.sh [ACTION] [OPTION]...

ACTION:
install                   Install/Update sing-box
compile                   Compile sing-box
remove                    Remove sing-box
help                      Show help
If no action is specified, then help will be selected

OPTION:
  install:
    --beta                    Install latest Pre-release version of sing-box. 
    --go                      If it's specified, the scrpit will use go to compile sing-box then install.
    --version=[Version]       sing-box version tag, if you specified it, the script will install your custom version sing-box. 
    --user=[User]             Install sing-box in specified user, e.g, --user=root

  compile: 
  [shared with install when it is using go &  If theres no \`go\` in the machine, script will install go to \`\$HOME/.cache\`]
    --tags=[Tags]             sing-box compile tags, the script will use your custom tags to compile sing-box. 
                              Default https://github.com/SagerNet/sing-box/blob/dev-next/Makefile#L5
    --prefix=[Path]           The path of scrpit store sing-box repository and go binary. 
                              Default \`\$HOME/.cache\`
    --branch=[Branch/Tag]     The scrpit will compile your custom \`branch\` / \`release tag\` of sing-box.
    --cgo                     Set \`CGO_ENABLED\` environment variable to 1
    --win                     The scrpit will use go to compile windows version of sing-box. 
    --rm                      Remove temporary files, include sing-box repository and go binary.
  
  remove:
    --purge                   Remove all the sing-box files, include configs, compiletion etc.
"
  exit 0
}

main "$@"
