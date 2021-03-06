#!/usr/bin/env bash
set -o noglob

USE_COLORS=true

# --- PLACEHOLDER FUNC

trap ctrl_c INT
ctrl_c() {
  tput cnorm
  exit
}

main() {
  if [ "$(id -u)" != "0" ]; then
    printf "${RED_BOLD}Change to root account required${PLAIN}\n"
    su root
  fi

  if [ "$(id -u)" != "0" ]; then
    printf "${RED_BOLD}Still not root, aborting${PLAIN}\n"
    exit    
  fi

  . /etc/os-release

  if [ -z "$ID" ]; then
    printf "${RED_BOLD}OS ould not detected. Try to install the package lsb-release${PLAIN}\n"
    exit
  fi

  if [ "$ID" != "debian" ] && [ "$ID" != "raspbian" ]; then
    printf "${RED_BOLD}Currently only the OS Debian is supported!${PLAIN}\n"
    exit
  fi
  
  if [ "$VERSION_CODENAME" != "bullseye" ] && [ "$OSBRANCH" != "buster" ]; then
    printf "${RED_BOLD}Currently only the Version bullseye or buster is supported!${PLAIN}\n"
    exit
  fi

  log "updating repository"
  apt-get update

  clear -x
  
  if [ "$USE_COLORS" == "true" ]; then
    init_colors
  fi
  
  printf "${RED_BOLD}#############################################\n"
  printf "${RED_BOLD}###${GREEN_BOLD}            www.mc8051.de              ${RED_BOLD}###\n"
  printf "${RED_BOLD}###${BLUE_BOLD}        CM4 Blade k3s Installer        ${RED_BOLD}###\n"
  printf "${RED_BOLD}###${BLUE_BOLD}                                       ${RED_BOLD}###\n"
  printf "${RED_BOLD}###${BLUE_BOLD}             07.01.2022                ${RED_BOLD}###\n"
  printf "${RED_BOLD}###${YELLOW_BOLD}          Niklas Schütrumpf            ${RED_BOLD}###\n"
  printf "${RED_BOLD}#############################################\n"
  printf "${PLAIN}\n\n"
   
  ALREADY_INSTALLED=$(command_exists k3s)

  printf "\n${PLAIN}Alright, let's get started with a few questions. Just press enter if you want to use the ${GREEN_BOLD}default${PLAIN} value.\n\n"

  if $ALREADY_INSTALLED; then
    log "${YELLOW_BOLD}k3s is already installed. we do not reinstall it${PLAIN}"
  fi

  if [ -z "$CM4_NODE_TYPE" ]; then
    CM4_NODE_TYPE="MASTER"
    log "install master node"
  fi

  FLOATING_IP=$CM4_FLOATING_IP
  if [ -z "$FLOATING_IP" ]; then
    ask FLOATING_IP "What is your floating ip for keepalived?"
  else
    log "${BLUE}using floating ip ${GREEN_BOLD}${FLOATING_IP}${PLAIN}"
  fi
  printf "\n"

  GLUSTER_FS_VOL=$CM4_GLUSTER_FS_VOL
  if [ -z "$GLUSTER_FS_VOL" ]; then
    ask GLUSTER_FS_VOL "What is your glusterfs volume name?" "vol1"
  else
    log "${BLUE}using glusterfs volume name ${GREEN_BOLD}${GLUSTER_FS_VOL}${PLAIN}"
  fi
  printf "\n"

  if [ -z "$CM4_CUSTOM_REGISTRY" ]; then
    if yesno "Do you want to setup a custom registry?" "no"; then
      printf "\n"
      ask CM4_CUSTOM_REGISTRY "What is the container registry hostname?" "ghcr.io"
      ask CM4_CUSTOM_REGISTRY_USERNAME "What is the username for the container registry? Leave empty for none." ""
      ask CM4_CUSTOM_REGISTRY_PASSWORD "What is the password for this user?" ""
    else
      CM4_CUSTOM_REGISTRY="none"
    fi
  fi

  MP="/mnt/${GLUSTER_FS_VOL}"
  BRICK_MP="${MP}/brick1"

  HOSTNAME=$(cat /etc/hostname)
  get_physical_interfaces IF

  guess_private_ip PRIVATE_IP
  guess_private_interface PRIVATE_IP_IF

  if $ALREADY_INSTALLED; then
    log "skipping - k3s is already installed"
  else
    printf "\nGreat. Now, let's check if you have the all requirements:\n\n"

    system_verify "curl"

    mkdir -p ${MP}

    if [[ $CM4_NODE_TYPE == "MASTER" ]]; then
      system_verify "glusterfs-server"

      if [ -z "$CM4_NODE_TOKEN" ]; then
        log "install as new cluster master"
        curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--cluster-init --tls-san ${FLOATING_IP}" sh -
      else
        log "install as extra master"
        curl -sfL https://get.k3s.io | K3S_TOKEN=${CM4_NODE_TOKEN} sh -s server --server https://${FLOATING_IP}:6443
      fi

      # TODO: Mount /dev/sda

      mkdir -p ${BRICK_MP}

      kubectl taint nodes ${HOSTNAME} node-role.kubernetes.io/master="":NoSchedule

      echo -e "alias k='kubectl'\n" > /etc/profile.d/69-kubernetes.sh
      echo -e "source <(kubectl completion bash)\n" >> /etc/profile.d/69-kubernetes.sh
      echo -e "complete -o default -F __start_kubectl k\n" >> /etc/profile.d/69-kubernetes.sh
    else
      system_verify "glusterfs-client"

      log "install as extra agent"
      curl -sfL https://get.k3s.io | K3S_URL=https://${FLOATING_IP}:6443 K3S_TOKEN=${CM4_NODE_TOKEN} sh -

      log "enabling glusterfs in fstab"
      echo -e "${FLOATING_IP}:/${GLUSTER_FS_VOL} ${MP} glusterfs defaults,_netdev       0  0\n" >> /etc/fstab
    fi

    if [[ $CM4_CUSTOM_REGISTRY != "none" ]]; then
      mkdir -p /etc/rancher/k3s
      echo "" > tee /etc/rancher/k3s/registries.yaml
      tee /etc/rancher/k3s/registries.yaml >/dev/null << EOF
mirrors:
  ${CM4_CUSTOM_REGISTRY}:
    endpoint:
      - "https://${CM4_CUSTOM_REGISTRY}.de"

EOF

          if [ "$CM4_CUSTOM_REGISTRY_USERNAME" != "" ] || [ "$CM4_CUSTOM_REGISTRY_PASSWORD" != "" ]; then
            tee -a /etc/rancher/k3s/registries.yaml >/dev/null << EOF
configs:
  "${CM4_CUSTOM_REGISTRY}":
    auth:
      username: ${CM4_CUSTOM_REGISTRY_USERNAME}
      password: ${CM4_CUSTOM_REGISTRY_PASSWORD}

EOF
          fi
      fi

      log "restarting k3s service to apply custom configs"
      if [[ $CM4_NODE_TYPE == "MASTER" ]]; then
        service k3s restart
        log "enable glusterfs service"
        systemctl enable --now glusterd
      else
        service k3s-agent restart
      fi
  fi

  printf "${PLAIN}"

  
  # Output Variables
  clear -x

  if $ALREADY_INSTALLED; then
    printf "\n\n${GREEN_BOLD} k3s was already installed. Here are your join commands again.\n\n"
  else
    printf "\n\n${GREEN_BOLD} Setup finished!\n\n"
  fi
  
  if [[ $CM4_NODE_TYPE == "MASTER" ]]; then
    if [ -z "$NODE_TOKEN" ]; then
      TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
      printf "${GREEN} K3S Cluster Token: ${PLAIN}${TOKEN}\n"
      printf "${GREEN} Keepalived: ${PLAIN}curl -s https://raw.githubusercontent.com/Gurkengewuerz/kubealived/main/manifests/kubealived.yaml | \ \n  sed -e 's/_IFACE_/${PRIVATE_IP_IF}/' -e 's/_IP_/${PRIVATE_IP}/' | \ \n  kubectl apply -f-\n"
      printf "${PLAIN}\n\n"

      for i in AGENT MASTER; do
        printf "${GREEN} K3s join command for ${BLUE_BOLD}${i}${GREEN}:${PLAIN} "
        printf "CM4_NODE_TYPE=\"${i}\" \ \n  "
        printf "CM4_NODE_TOKEN=\"${TOKEN}\" \ \n  "
        printf "CM4_GLUSTER_FS_VOL=\"${GLUSTER_FS_VOL}\" \ \n  "
        printf "CM4_FLOATING_IP=\"${FLOATING_IP}\" \ \n  "
        printf "CM4_CUSTOM_REGISTRY=\"${CM4_CUSTOM_REGISTRY}\" \ \n  "
        if [ "$CM4_CUSTOM_REGISTRY_USERNAME" != "" ]; then
          printf "CM4_CUSTOM_REGISTRY_USERNAME=\"${CM4_CUSTOM_REGISTRY_USERNAME}\" \ \n  "
        fi
        if [ "$CM4_CUSTOM_REGISTRY_PASSWORD" != "" ]; then
          printf "CM4_CUSTOM_REGISTRY_PASSWORD=\"${CM4_CUSTOM_REGISTRY_PASSWORD}\" \ \n  "
        fi
        printf "bash <(curl -sfL _URL_)\n"
      done
      printf "${PLAIN}\n\n"
    fi

    printf "${GREEN} GlusterFS add peer: ${PLAIN}gluster peer probe ${PRIVATE_IP}\n"
    printf "${GREEN} GlusterFS create volume: ${PLAIN}gluster volume create ${GLUSTER_FS_VOL} replica 3 server1:${BRICK_MP} server2:${BRICK_MP} ${PRIVATE_IP}:${BRICK_MP}\n"
    printf "${GREEN} GlusterFS start volume: ${PLAIN}gluster volume start ${GLUSTER_FS_VOL}\n"
  else
    printf "${YELLOW} Please ${RED_BOLD}reboot${YELLOW} your system.\n"
  fi
  printf "${PLAIN}\n\n\n"
}

main $@
