#!/bin/bash
set -euo pipefail # Enable strict mode for bash

trap 'echo -e "\e[31m[ERROR]: Script failed at line $LINENO with status $?\e[0m"' ERR

# Source the .env file if it exists
if [ -f ".env" ]; then
    source .env
fi

display_usage() {
    echo -e "\e[33m[NOTICE]: Usage:\e[0m"
    echo "======"
    echo "./install.sh"
    echo "# follow the prompts if variables are not set in .env file"
    echo "required: FEED_NAME, ETH_FROM, ETH_PASS, KEYSTORE_FILE, NODE_EXT_IP, ETH_RPC_URL"
}

validate_vars() {
    if [[ -z "${FEED_NAME:-}" || -z "${ETH_FROM:-}" || -z "${ETH_PASS:-}" || -z "${KEYSTORE_FILE:-}" || -z "${NODE_EXT_IP:-}" || -z "${ETH_RPC_URL:-}" ]]; then
        echo -e "\e[31m[ERROR]: All variables are required!\e[0m"
        display_usage
        exit 1
    fi
}

validate_os() {
    OS_VERSION=$(lsb_release -rs)
    if [ "$OS_VERSION" != "22.04" ]; then
        echo -e "\e[31m[ERROR]: This script is designed for Ubuntu 22.04!\e[0m"
        exit 1
    fi
}

validate_user() {
    if [ "$USER" == "root" ]; then
        echo -e "\e[31m[ERROR]: This script should not be run as root!\e[0m"
        exit 1
    fi
}

validate_command() {
    command -v "$1" > /dev/null 2>&1 || {
        echo -e "\e[31m[ERROR]: $1 is not installed!\e[0m" >&2
        exit 1
    }
}

validate_sudo() {
    if ! sudo -n true 2>/dev/null; then
        echo -e "\e[31m[ERROR]: This script requires sudo privileges!\e[0m"
        exit 1
    fi
}

get_public_ip() {
    PUBLIC_IP=$(dig +short myip.opendns.com @resolver1.opendns.com)
    if [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$PUBLIC_IP"
        return
    fi
    PUBLIC_IP=$(curl -s ifconfig.me)
    if [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$PUBLIC_IP"
        return
    fi
    PUBLIC_IP=$(curl -s icanhazip.com)
    if [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$PUBLIC_IP"
        return
    fi
    echo -e "\e[31m[ERROR]: Unable to obtain public IP address!\e[0m"
    exit 1
}

install_deps() {
    echo -e "\e[32m[INFO]:..........Updating package lists for upgrades and new package installations.........\e[0m"
    sudo apt-get update -y
    
    for cmd in dig curl jq helm k3s keeman; do
        if ! command -v $cmd > /dev/null; then
            echo -e "\e[32m[INFO]:..........Installing $cmd.........\e[0m"
            sudo apt-get install -y $cmd
            validate_command $cmd
            echo -e "\e[32m[SUCCESS]: $cmd is now installed !!!\e[0m"
        fi
    done
}

set_kubeconfig() {
    if [ $(id -u) -eq 0 ]; then
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    else
      export KUBECONFIG=$HOME/.kube/config
    fi
}

collect_vars() {
    if [ -z "${FEED_NAME:-}" ]; then
        echo ">> Enter feed name (eg: chronicle-feed):"
        read -r FEED_NAME
    fi
    if [ -z "${ETH_FROM:-}" ]; then
        echo ">> Enter your ETH Address (eg: 0x3a...):"
        read -r ETH_FROM
    fi
    if [ -z "${ETH_PASS:-}" ]; then
        echo ">> Enter the path to your ETH password file (eg: /path/to/password.txt):"
        read -r ETH_PASS
    fi
    if [ -z "${KEYSTORE_FILE:-}" ]; then
        echo ">> Enter the path to your ETH keystore (eg: /path/to/keystore.json):"
        read -r KEYSTORE_FILE
    fi
    if [ -z "${NODE_EXT_IP:-}" ]; then
        echo ">> Obtaining the Node External IP..."
        NODE_EXT_IP=$(get_public_ip)
        echo ">> Node External IP is $NODE_EXT_IP"
    fi
        if [ -z "${ETH_RPC_URL:-}" ]; then
        echo ">> Enter your ETH rpc endpoint (eg: https://eth.llamarpc.com):"
        read -r ETH_RPC_URL
    fi
    
    validate_vars
}

create_namespace() {
    set_kubeconfig
    kubectl create namespace $FEED_NAME
}

create_eth_secret() {
    set_kubeconfig
    validate_vars
    ETH_PASS_CONTENT=$(sudo cat $ETH_PASS)
    sudo cp $KEYSTORE_FILE /home/chronicle/$FEED_NAME/keystore.json
    sudo chown chronicle:chronicle -R /home/chronicle/$FEED_NAME
    kubectl create secret generic $FEED_NAME-eth-keys \
    --from-file=ethKeyStore=/home/chronicle/$FEED_NAME/keystore.json \
    --from-literal=ethFrom=$ETH_FROM \
    --from-literal=ethPass=$ETH_PASS_CONTENT \
    --namespace $FEED_NAME
    echo -e "\e[33m-----------------------------------------------------------------------------------------------------\e[0m"
    echo -e "\e[33mThis is your Feed address:\e[0m"
    echo -e "\e[33m$ETH_FROM\e[0m"
    echo -e "\e[33m-----------------------------------------------------------------------------------------------------\e[0m"
}

create_tor_secret() {
    set_kubeconfig
    validate_vars
    keeman gen | tee >(cat >&2) | keeman derive -f onion > /home/chronicle/$FEED_NAME/torkeys.json
    sudo chown chronicle:chronicle -R /home/chronicle/$FEED_NAME
    kubectl create secret generic $FEED_NAME-tor-keys \
        --from-literal=hostname="$(jq -r '.hostname' < /home/chronicle/$FEED_NAME/torkeys.json)" \
        --from-literal=hs_ed25519_secret_key="$(jq -r '.secret_key' < /home/chronicle/$FEED_NAME/torkeys.json)" \
        --from-literal=hs_ed25519_public_key="$(jq -r '.public_key' < /home/chronicle/$FEED_NAME/torkeys.json)" \
        --namespace $FEED_NAME
    declare -g TOR_HOSTNAME="$(jq -r '.hostname' < /home/chronicle/$FEED_NAME/torkeys.json)"
    echo -e "\e[33m-----------------------------------------------------------------------------------------------------\e[0m"
    echo -e "\e[33mThis is your .onion address:\e[0m"
    echo -e "\e[33m$TOR_HOSTNAME\e[0m"
    echo -e "\e[33m-----------------------------------------------------------------------------------------------------\e[0m"
}

generate_values() {
    validate_vars
    
    DIRECTORY_PATH="/home/chronicle/${FEED_NAME}"
    mkdir -p "$DIRECTORY_PATH" || {
        echo -e "\e[31m[ERROR]: Unable to create directory $DIRECTORY_PATH\e[0m"
        exit 1
    }
    
    if [ ! -d "$DIRECTORY_PATH" ]; then
        echo -e "\e[31m[ERROR]: Directory $DIRECTORY_PATH does not exist and failed to be created\e[0m"
        exit 1
    fi
    
    VALUES_FILE="$DIRECTORY_PATH/generated-values.yaml"
    cat <<EOF > "$VALUES_FILE"
ghost:
  ethConfig:
    ethFrom:
      existingSecret: '${FEED_NAME}-eth-keys'
      key: "ethFrom"
    ethKeys:
      existingSecret: '${FEED_NAME}-eth-keys'
      key: "ethKeyStore"
    ethPass:
      existingSecret: '${FEED_NAME}-eth-keys'
      key: "ethPass"

  env:
    normal:
      CFG_LIBP2P_EXTERNAL_ADDR: '/ip4/${NODE_EXT_IP}'

  ethRpcUrl: "${ETH_RPC_URL}"
  ethChainId: 1

  rpcUrl: "${ETH_RPC_URL}"
  chainId: 1

musig:
  ethConfig:
    ethFrom:
      existingSecret: '${FEED_NAME}-eth-keys'
      key: "ethFrom"
    ethKeys:
      existingSecret: '${FEED_NAME}-eth-keys'
      key: "ethKeyStore"
    ethPass:
      existingSecret: '${FEED_NAME}-eth-keys'
      key: "ethPass"

  env:
    normal:
      CFG_LIBP2P_EXTERNAL_ADDR: "/ip4/${NODE_EXT_IP}"
      CFG_WEB_URL: "${TOR_HOSTNAME}"

  ethRpcUrl: "${ETH_RPC_URL}"
  ethChainId: 1

tor-proxy:
  torConfig:
    existingSecret: '${FEED_NAME}-tor-keys'
EOF
    
    if [ ! -f "$VALUES_FILE" ]; then
        echo -e "\e[31m[ERROR]: Failed to create $VALUES_FILE\e[0m"
        exit 1
    fi
    
    echo "You need to install the helm chart with the following command:"
    echo -e "\e[33m-------------------------------------------------------------------------------------------------------------------------------\e[0m"
    echo -e "\e[33m|   helm install \"$FEED_NAME\" -f \"$VALUES_FILE\"  chronicle/feed --namespace \"$FEED_NAME\"       |\e[0m"
    echo -e "\e[33m-------------------------------------------------------------------------------------------------------------------------------\e[0m"
}

create_helm_release() {
    set_kubeconfig
    validate_vars
    helm repo add chronicle https://chronicleprotocol.github.io/charts/
    helm repo update
    helm install "$FEED_NAME" -f /home/chronicle/"$FEED_NAME"/generated-values.yaml  chronicle/feed --namespace "$FEED_NAME"
}

main() {
    echo -e "\e[32m[INFO]:..........running preflight checks.........\e[0m"
    validate_os
    validate_user
    validate_sudo
    echo -e "\e[32m[INFO]:..........installing dependencies.........\e[0m"
    install_deps
    echo -e "\e[32m[INFO]:..........gather input variables.........\e[0m"
    collect_vars
    echo -e "\e[32m[INFO]:..........installing k8s chronicle stack..........\e[0m"
    echo -e "\e[32m[INFO]:..........create namespace $FEED_NAME..........\e[0m"
    create_namespace
    echo -e "\e[32m[INFO]:..........create secret with ETH keys..........\e[0m"
    create_eth_secret
    echo -e "\e[32m[INFO]:..........create secret with TOR keys..........\e[0m"
    create_tor_secret
    echo -e "\e[32m[INFO]:..........generate helm values file..........\e[0m"
    generate_values
    echo -e "\e[32m[INFO]:..........create helm release..........\e[0m"
    create_helm_release
    echo -e "\e[33m[NOTICE]: setup complete!\e[0m"
}

main "$@"
