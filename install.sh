#!/usr/bin/bash
set -e

action=
tag=
type=
go_type=
remove_type=
beta=false
win=false
PURGE=false
CGO_ENABLED=0
RESTART_TEMP=$(mktemp)

identify_the_operating_system_and_architecture() {
  if [[ "$(uname)" == 'Linux' ]]; then
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
        echo "error: The architecture is not supported."
        exit 1
        ;;
    esac
    if [[ ! -f '/etc/os-release' ]]; then
      echo "error: Don't use outdated Linux distributions."
      exit 1
    fi
    # Do not combine this judgment condition with the following judgment condition.
    ## Be aware of Linux distribution like Gentoo, which kernel supports switch between Systemd and OpenRC.
    if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc' /proc/1/cgroup && [[ "$(type -P systemctl)" ]]; then
      true
    elif [[ -d /run/systemd/system ]] || grep -q systemd <(ls -l /sbin/init); then
      true
    else
      echo "error: Only Linux distributions using systemd are supported."
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
      PACKAGE_MANAGEMENT_INSTALL='pacman -Syu --noconfirm'
      PACKAGE_MANAGEMENT_REMOVE='pacman -Rsn'
      package_provide_tput='ncurses'
     elif [[ "$(type -P emerge)" ]]; then
      PACKAGE_MANAGEMENT_INSTALL='emerge -qv'
      PACKAGE_MANAGEMENT_REMOVE='emerge -Cv'
      package_provide_tput='ncurses'
    else
      echo "error: The script does not support the package manager in this operating system."
      exit 1
    fi
  else
    echo "error: This operating system is not supported."
    exit 1
  fi
}

install_software() {
  package_name="$1"
  file_to_detect="$2"
  type -P "$file_to_detect" > /dev/null 2>&1 && return
  if ${PACKAGE_MANAGEMENT_INSTALL} "$package_name" >/dev/null 2>&1; then
    echo "info: $package_name is installed."
  else
    echo "error: Installation of $package_name failed, please check your network."
    exit 1
  fi
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "\033[1;31m\033[1mERROR:\033[0m You have to use root to run this script"
    exit 1
  fi
}

curl() {
  if ! $(type -P curl) -# -L -q --retry 5 --retry-delay 5 --retry-max-time 60 "$@";then
    echo -e "\033[1;31m\033[1mERROR:\033[0m Curl Failed, check your network"
    exit 1
  fi
}

install_building_components() {
  if [[ $PACKAGE_MANAGEMENT_INSTALL == 'apt -y --no-install-recommends install' ]]; then
    if ! dpkg -l | awk '{print $2"\t","Version="$3,"ARCH="$4}' | grep build-essential ;then
      echo -e "\e[93mWARN\e[0m: Building components not found, Installing."
      ${PACKAGE_MANAGEMENT_INSTALL} build-essential
    fi
  elif [[ $PACKAGE_MANAGEMENT_INSTALL == 'dnf -y install' ]]; then
    if ! dnf list installed "Development Tools";then
      echo -e "\e[93mWARN\e[0m: Building components not found, Installing."
      ${PACKAGE_MANAGEMENT_INSTALL} "Development Tools"
    fi
  elif [[ $PACKAGE_MANAGEMENT_INSTALL == 'yum -y install' ]]; then
    if ! yum list installed "Development Tools";then
      echo -e "\e[93mWARN\e[0m: Building components not found, Installing."
      ${PACKAGE_MANAGEMENT_INSTALL} "Development Tools"
    fi
  elif [[ $PACKAGE_MANAGEMENT_INSTALL == 'zypper install -y --no-recommends' ]]; then
    if ! zypper se --installed-only gcc;then
      echo -e "\e[93mWARN\e[0m: Building components not found, Installing."
      ${PACKAGE_MANAGEMENT_INSTALL} gcc
    fi
  elif [[ $PACKAGE_MANAGEMENT_INSTALL == 'pacman -Syu --noconfirm' ]]; then
    if ! pacman -Q base-devel;then
      echo -e "\e[93mWARN\e[0m: Building components not found, Installing."
      ${PACKAGE_MANAGEMENT_INSTALL} base-devel
    fi
  elif [[ $PACKAGE_MANAGEMENT_INSTALL == 'emerge -qv' ]]; then
    if ! emerge -p sys-devel/base-system;then
      echo -e "\e[93mWARN\e[0m: Building components not found, Installing."
      ${PACKAGE_MANAGEMENT_INSTALL} sys-devel/base-system
    fi
  fi
}

go_install() {
  install_building_components

  if ! GO_PATH=$(type -P go);then
    bash -c "$(curl -L https://github.com/chise0713/go-install/raw/master/install.sh)" @ install
  else
    echo "INFO: GO Found, PATH=$GO_PATH"
  fi

  if [[ $win == true ]];then 
    export GOOS=windows
    export GOARCH=amd64 && export GOAMD64=v3
  elif [[ $win == false ]];then
    export GOOS=linux
    [[ $MACHINE == amd64 ]] && export GOAMD64=v2
  fi

  if [[ $CGO_ENABLED == 0 ]];then
    export CGO_ENABLED=0
  elif [[ $CGO_ENABLED == 1 ]];then
    export CGO_ENABLED=1
  fi
  
  if echo $tag |grep -oP with_lwip >> /dev/null && [[ $CGO_ENABLED == 0 ]];then
    echo -e "\033[1;31m\033[1mERROR:\033[0m Tag with_lwip \e[1mMUST HAVE environment variable CGO_ENABLED=1\e[0m\nExiting."
    exit 1
  fi

  if echo $tag |grep -oP with_embedded_tor >> /dev/null && [[ $CGO_ENABLED == 0 ]];then
    echo -e "\033[1;31m\033[1mERROR:\033[0m Tag with_embedded_tor \e[1mMUST HAVE environment variable CGO_ENABLED=1\e[0m\nExiting."
    exit 1
  fi

  if [[ $go_type == default ]];then
    echo -e "\
Using offcial default Tags: with_gvisor,with_quic,with_dhcp,with_wireguard,with_ech,with_utls,with_reality_server,with_clash_api.\
"
    tag="with_gvisor,with_quic,with_dhcp,with_wireguard,with_ech,with_utls,with_reality_server,with_clash_api"
  elif [[ $go_type == custom ]]; then
    echo -e "\
Using custom config:
Tags: $tag\
"
  fi

  if ! GOARCH=$MACHINE go install -v -tags $tag github.com/sagernet/sing-box/cmd/sing-box@dev-next;then
    echo -e "Go Install Failed.\nExiting."
    exit 1
  fi

  if [[ $win == false ]];then
    if install -m 755 /root/go/bin/sing-box /usr/local/bin/sing-box;then
      echo -e "Installed \"/usr/local/bin/sing-box\""
      echo -n 'true' > $RESTART_TEMP
    else
      echo -e "\033[1;31m\033[1mERROR:\033[0m Failed to Install \"/usr/local/bin/sing-box\""
      exit 1
    fi
  elif [[ $win == true ]];then
    cp -rf /root/go/bin/windows_amd64/sing-box.exe /root/sing-box.exe
    echo -e "Installed: /root/go/bin/sing-box.exe\nInstalled: /root/sing-box.exe"
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

  if [[ -z $SING_VERSION ]];then
    if [[ $beta == false ]];then
      SING_VERSION=$(curl https://api.github.com/repos/SagerNet/sing-box/releases | grep -oP "sing-box-\d+\.\d+\.\d+-linux-$CURL_MACHINE"| sort -Vru | head -n 1)
      echo "Newest version found: $SING_VERSION"
    elif [[ $beta == true ]];then
      SING_VERSION=$(curl https://api.github.com/repos/SagerNet/sing-box/releases | grep -oP "sing-box-\d+\.\d+\.\d+.*-linux-$CURL_MACHINE"| sed "s/-linux-$CURL_MACHINE$/-zzzzz-linux-$CURL_MACHINE/" | sort -Vru | sed "s/-zzzzz-linux-$CURL_MACHINE$/-linux-$CURL_MACHINE/" | head -n 1)
      echo "Newest version found: $SING_VERSION"
      CURL_TAG=$(echo $SING_VERSION | (grep -oP "\d+\.\d+\.\d+.*\.\d+" || grep -oP "\d+\.\d+\.\d+"))
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
    CURRENT_SING_VERSION=$(sing-box version | (grep -oP "\d+\.\d+\.\d+.*"|| grep -oP "\d+\.\d+\.\d+") | head -1)
    if echo "$SING_VERSION" | grep "sing-box-$CURRENT_SING_VERSION-linux-$CURL_MACHINE">/dev/null;then
      echo "Your sing-box is up to date"
      return 0
    fi
  fi

  if [[ -z $CURL_TAG ]];then 
    curl -o /tmp/$SING_VERSION.tar.gz https://github.com/SagerNet/sing-box/releases/latest/download/$SING_VERSION.tar.gz
  else
    curl -o /tmp/$SING_VERSION.tar.gz https://github.com/SagerNet/sing-box/releases/download/v$CURL_TAG/$SING_VERSION.tar.gz
  fi

  tar -xzf /tmp/$SING_VERSION.tar.gz -C /tmp
  if install -m 755 /tmp/$SING_VERSION/sing-box /usr/local/bin/sing-box;then
    echo -e "Installed \"/usr/local/bin/sing-box\""
    echo -n 'true' > $RESTART_TEMP
  else
    echo -e "\033[1;31m\033[1mERROR:\033[0m Failed to Install \"/usr/local/bin/sing-box\""
    exit 1
  fi
}

service_control() {
  restart(){
    if systemctl is-active --quiet sing-box.service; then
      echo "INFO: sing-box.service is running, restarting it"
      if ! systemctl restart sing-box.service;then
        echo -e "\033[1;31m\033[1mERROR:\033[0m Failed to restart sing-box\nExiting."
        exit 1
      fi
    else
      echo "INFO: sing-box.service not running."
    fi
    services=$(systemctl list-units --full --all | grep 'sing-box@.*\.service' | grep running | awk '{print $1}')
    for service in $services;do
      echo "INFO: $service.service is running, restarting it"
      systemctl restart $service || ( echo -e "\033[1;31m\033[1mERROR:\033[0m Failed to restart $service\nExiting." && exit 1 )
    done
  }
  start(){
    if systemctl start sing-box.service;then
      echo "INFO: Started sing-box.service."
    else
      echo -e "\033[1;31m\033[1mERROR:\033[0m Failed to start sing-box\nExiting."
      exit 1
    fi
  }
  ([[ $1 == start ]] && start )||([[ $1 == restart ]] && restart )
}

install_service() {
  [ -f /etc/systemd/system/sing-box.service ] && local WAS_INSTALLED=true
  if [[ $WAS_INSTALLED == true ]];then
    local Old1=$(cat /etc/systemd/system/sing-box.service)
    local Old2=$(cat /etc/systemd/system/sing-box.service)
  fi
  ( cat <<EOF > /etc/systemd/system/sing-box.service && echo -e "Installed \"/etc/systemd/system/sing-box.service\"" ) || \
  ( echo -e "\033[1;31m\033[1mERROR:\033[0m Failed to Install \"/etc/systemd/system/sing-box.service\"" && exit 1 )
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=$INSTALL_USER
WorkingDirectory=/usr/local/share/sing-box
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
  (cat <<EOF > /etc/systemd/system/sing-box@.service && echo -e "Installed \"/etc/systemd/system/sing-box@.service\"" ) || \
  ( echo -e "\033[1;31m\033[1mERROR:\033[0m Failed to Install \"/etc/systemd/system/sing-box@.service\"" && exit 1 )
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=$INSTALL_USER
WorkingDirectory=/usr/local/share/sing-box
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
  systemctl daemon-reload
  if [[ "$Old1" == "$(cat /etc/systemd/system/sing-box.service)" ]] || [[ "$Old2" == "$(cat /etc/systemd/system/sing-box@.service)" ]];then
    service_control restart
  fi
  wait $PID
  [[ $WAS_INSTALLED == true ]] && return 0
  if systemctl enable sing-box ;then
    echo "INFO: Enabled sing-box.service"
    service_control start
    echo -n 'false' > $RESTART_TEMP
  else
    echo -e "\033[1;31m\033[1mERROR:\033[0m Failed to enable sing-box.service"
    exit 1
  fi
}

install_config() {
  if [ ! -d /usr/local/etc/sing-box ];then
    if ! install -d -m 700 -o $INSTALL_USER -g $INSTALL_GROUP /usr/local/etc/sing-box;then
      echo -e "\033[1;31m\033[1mERROR:\033[0m Failed to Install \"/usr/local/etc/sing-box\""
      exit 1
    else
      echo "Installed \"/usr/local/etc/sing-box\""
    fi
    if ! install -m 700 -o $INSTALL_USER -g $INSTALL_GROUP /dev/null /usr/local/etc/sing-box/config.json;then
      echo -e "\033[1;31m\033[1mERROR:\033[0m Failed to Install \"/usr/local/etc/sing-box/config.json\""
      exit 1
    else
      echo -e "Installed \"/usr/local/etc/sing-box/config.json\""
      echo -e "{\n\n}" > /usr/local/etc/sing-box/config.json
    fi
  elif ! ls /usr/local/etc/sing-box -dl | grep -E "$INSTALL_USER $INSTALL_GROUP" >/dev/null;then
    chown -R $INSTALL_USER:$INSTALL_GROUP /usr/local/etc/sing-box
  fi
  if [ ! -d /usr/local/share/sing-box ];then
    if ! install -d -m 700 -o $INSTALL_USER -g $INSTALL_GROUP /usr/local/share/sing-box;then
      echo -e "\033[1;31m\033[1mERROR:\033[0m Failed to Install \"/usr/local/share/sing-box\""
      exit 1
    else
      echo -e "Installed \"/usr/local/share/sing-box\""
    fi
  elif ! ls /usr/local/share/sing-box -dl | grep -E "$INSTALL_USER $INSTALL_GROUP" >/dev/null;then
    chown -R $INSTALL_USER:$INSTALL_GROUP /usr/local/share/sing-box
  fi
}

install_sysuser() {
  if [ -f /usr/lib/sysusers.d/sing-box.conf ];then
    return 0
  fi
  cat <<EOF > /usr/lib/sysusers.d/sing-box.conf
u sing-box - "sing-box service" /usr/local/share/sing-box -
EOF
  echo -e "Installed \"/usr/lib/sysusers.d/sing-box.conf\""
  systemd-sysusers /usr/lib/sysusers.d/sing-box.conf
}

install_compiletion() {
  if ! [ -f /usr/share/bash-completion/completions/sing-box ];then
    if \
      sing-box completion bash |\
        install -Dm644 /dev/stdin "/usr/share/bash-completion/completions/sing-box";then
      echo -e "Installed \"/usr/share/bash-completion/completions/sing-box\""
    else
        echo -e "\033[1;31m\033[1mERROR:\033[0m Failed to Install \"/usr/share/bash-completion/completions/sing-box\""
        exit 1
    fi
  fi
  if ! [ -f /usr/share/fish/vendor_completions.d/sing-box.fish ];then
    if \
      sing-box completion fish |\
        install -Dm644 /dev/stdin "/usr/share/fish/vendor_completions.d/sing-box.fish";then
      echo -e "Installed \"/usr/share/fish/vendor_completions.d/sing-box.fish\""
    else
        echo -e "\033[1;31m\033[1mERROR:\033[0m Failed to Install \"/usr/share/fish/vendor_completions.d/sing-box.fish\""
        exit 1
    fi
  fi
  if ! [ -f /usr/share/zsh/site-functions/_sing-box ];then
    if \
      sing-box completion zsh |\
        install -Dm644 /dev/stdin "/usr/share/zsh/site-functions/_sing-box";then
      echo -e "Installed \"/usr/share/zsh/site-functions/_sing-box\""
    else
        echo -e "\033[1;31m\033[1mERROR:\033[0m Failed to Install \"/usr/share/zsh/site-functions/_sing-box\""
        exit 1
    fi
  fi
}

uninstall() {
  if ! ([ -f /etc/systemd/system/sing-box.service ] || [ -f /usr/local/bin/sing-box ]) ;then
    echo -e "sing-box not Installed.\nExiting."
    exit 1
  fi
  if [ -f /etc/systemd/system/sing-box.service ];then
    if systemctl stop sing-box && systemctl disable sing-box ;then
      echo -e "INFO: Stoped and disabled sing-box.service"
    else
      echo -e "\033[1;31m\033[1mERROR:\033[0m Failed to Stop and disable sing-box.service"
      exit 1
    fi
  fi

  NEED_REMOVE+=(
    '/etc/systemd/system/sing-box.service'
    '/etc/systemd/system/sing-box@.service'
    '/usr/local/bin/sing-box'
    '/usr/lib/sysusers.d/sing-box.conf'
    '/usr/share/bash-completion/completions/sing-box'
    '/usr/share/fish/vendor_completions.d/sing-box.fish'
    '/usr/share/zsh/site-functions/_sing-box'
  )

  if [[ $PURGE == true ]];then
    NEED_REMOVE+=( '/usr/local/etc/sing-box/' '/usr/local/share/sing-box/' )
  fi

  for file in "${NEED_REMOVE[@]}"; do
      if [[ -d $file ]] || [[ -f $file ]];then
        rm -rf $file || (echo -e "\033[1;31m\033[1mERROR:\033[0m Failed remove $file" && exit 1)
        if echo $file | grep -E ".*/$">/dev/null ;then
          echo "Removed directory \"$file\""
        else
          echo "Removed \"$file\""
        fi
      fi
  done

  if getent passwd sing-box>/dev/null;then
    SING_BOX_UID=$(id sing-box -u) && SING_BOX_GID=$(id sing-box -g)
    echo -e "Deleting group 'sing-box' with GID $SING_BOX_GID."
    userdel sing-box
    echo -e "Deleting user 'sing-box' (sing-box service) with UID $SING_BOX_UID and GID $SING_BOX_GID."
  fi

  systemctl daemon-reload
  
  exit 0
}

main() {
  check_root
  identify_the_operating_system_and_architecture
  
  [[ $action == uninstall ]] && uninstall

  if [[ $type == go ]];then
    [[ -z $go_type ]] && go_type=default
    go_install &
    PID=$!
  else
    curl_install &
    PID=$!
  fi

  if [[ $win == false ]];then
    if [[ -z $INSTALL_USER ]];then
      install_sysuser
      INSTALL_USER=sing-box
    else
      if ! getent passwd $INSTALL_USER >/dev/null;then
        echo -e "\033[1;31m\033[1mERROR:\033[0m No such a user $INSTALL_USER"
        exit 1
      fi
    fi
    INSTALL_GROUP=$(groups $INSTALL_USER | awk '{printf $1}')
    install_config
    install_service
    install_compiletion
  fi

  wait $PID

  RESTART=$(cat $RESTART_TEMP)
  if [[ $RESTART == true ]];then
    service_control restart
  fi
  rm -f $RESTART_TEMP

  exit 0
}

help() {
  echo -e "\
Thanks \033[38;5;208m@chika0801\033[0m.
usage: install.sh ACTION [OPTION]...

ACTION:
install                   Install/Update sing-box
remove                    Remove sing-box
help                      Show help
If no action is specified, then help will be selected

OPTION:
  install:
    --beta                    If it's specified, the scrpit will install latest Pre-release version of sing-box. 
                              If it's not specified, the scrpit will install latest release version by default.
    --go                      If it's specified, the scrpit will use go to install sing-box. 
                              If it's not specified, the scrpit will use curl by default.
    --tag=[Tags]              sing-box Install tag, if you specified it, the script will use go to install sing-box, and use your custom tags. 
                              If it's not specified, the scrpit will use offcial default Tags by default.
    --cgo                     Set \`CGO_ENABLED\` environment variable to 1
    --version=[Version]       sing-box Install version, if you specified it, the script will install your custom version sing-box. 
    --user=[User]             Install sing-box in specified user, e.g, --user=root
    --win                     If it's specified, the scrpit will use go to compile windows version of sing-box. 
  remove:
    --purge                   Remove all the sing-box files, include logs, configs, etc
"
  exit 0
}

for arg in "$@"; do
  case $arg in
    --purge)
      PURGE=true
      ;;
    --win)
      win=true
      type="go"
      ;;
    --user=*)
      INSTALL_USER="${arg#*=}"
      ;;
    --beta)
      beta=true
      ;;
    --go)
      type="go"
      ;;
    --cgo)
      CGO_ENABLED=1
      type="go"
      ;;
    --tag=*)
      tag="${arg#*=}"
      go_type=custom
      type="go"
      ;;
    --version=*)
      SING_VERSION="${arg#*=}"
      ;;
    help)
      help
      ;;
    remove)
      action="uninstall"
      ;;
    install)
      action="install"
      ;;
    *)
      echo "Invalid argument: $arg"
      exit 1
      ;;
  esac
done

([[ $action == install ]] || [[ $action == uninstall ]]) && main
echo "No action specified."
help