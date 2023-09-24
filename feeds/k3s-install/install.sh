#!/bin/bash
set -euo pipefail # Enable strict mode for bash

trap 'echo "Script failed at line $LINENO with status $?"' ERR

# Source the .env file if it exists
if [ -f ".env" ]; then
    source .env
fi

display_usage() {
    echo "Usage:"
    echo "======"
    echo "./install.sh"
    echo "# follow the prompts if variables are not set in .env file"
    echo "required: FEED_NAME, ETH_FROM, ETH_PASS, KEYSTORE_FILE, NODE_EXT_IP"
}

validate_vars() {
    if [[ -z "${FEED_NAME:-}" || -z "${ETH_FROM:-}" || -z "${ETH_PASS:-}" || -z "${KEYSTORE_FILE:-}" || -z "${NODE_EXT_IP:-}" ]]; then
        echo "[ERROR]: All variables are required!"
        display_usage
        exit 1
    fi
}

validate_os() {
    OS_VERSION=$(lsb_release -rs)
    if [ "$OS_VERSION" != "22.04" ]; then
        echo "[ERROR]: This script is designed for Ubuntu 22.04!"
        exit 1
    fi
}

validate_user() {
    if [ "$USER" == "root" ]; then
        echo "[ERROR]: This script should not be run as root!"
        exit 1
    fi
}

validate_command() {
    command -v "$1" > /dev/null 2>&1 || {
        echo "[ERROR]: $1 is not installed!" >&2
        exit 1
    }
}

create_user() {
    sudo useradd -m -s /bin/bash chronicle
    sudo passwd -d chronicle
    sudo usermod -aG sudo chronicle
    echo "[NOTICE]: User chronicle created with no password and added to the sudoers group."
}

get_public_ip() {
    # Try using dig +short myip.opendns.com @resolver1.opendns.com
    PUBLIC_IP=$(dig +short myip.opendns.com @resolver1.opendns.com)
    if [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$PUBLIC_IP"
        return
    fi
    
    # Fallback to curl ifconfig.me
    PUBLIC_IP=$(curl -s ifconfig.me)
    if [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$PUBLIC_IP"
        return
    fi
    
    # Fallback to curl icanhazip.com
    PUBLIC_IP=$(curl -s icanhazip.com)
    if [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$PUBLIC_IP"
        return
    fi
    
    echo "[ERROR]: Unable to obtain public IP address!"
    exit 1
}

install_deps() {
    echo "[INFO]:..........Updating package lists for upgrades and new package installations........."
    sudo apt-get update -y
    
    # Validate and install dig
    if ! command -v dig > /dev/null; then
        echo "[INFO]:..........Installing dnsutils for dig command........."
        sudo apt-get install -y dnsutils
        validate_command dig
        echo "[SUCCESS]: dig is now installed !!!"
    fi
    
    # Validate and install curl
    if ! command -v curl > /dev/null; then
        echo "[INFO]:..........Installing curl........."
        sudo apt-get install -y curl
        validate_command curl
        echo "[SUCCESS]: curl is now installed !!!"
    fi
    
    # Validate and install jq
    if ! command -v jq > /dev/null; then
        echo "[INFO]:..........Installing jq........."
        sudo apt-get install -y jq
        validate_command jq
        echo "[SUCCESS]: jq is now installed !!!"
    fi
    
    # Validate and install helm
    if ! command -v helm > /dev/null; then
        echo "[INFO]:..........Installing helm........."
        curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        validate_command helm
        echo "[SUCCESS]: helm is now installed !!!"
    fi
    
    # Validate and install k3s
    if ! command -v k3s > /dev/null; then
        echo "[INFO]:..........Installing k3s........."
        curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -s - --node-external-ip $NODE_EXT_IP
        mkdir -p /home/chronicle/.kube
        sudo cp /etc/rancher/k3s/k3s.yaml /home/chronicle/.kube/config
        sudo chown chronicle:chronicle -R /home/chronicle/.kube
        sudo chmod 600 /home/chronicle/.kube/config
        echo "export KUBECONFIG=/home/chronicle/.kube/config " >> /home/chronicle/.bashrc
        source "/home/chronicle/.bashrc"
        validate_command k3s
        echo "[SUCCESS]: k3s is now installed !!!"
    fi
    
    # Validate and install keeman
    if ! command -v keeman > /dev/null; then
        echo "[INFO]:..........Installing keeman........."
        wget https://github.com/chronicleprotocol/keeman/releases/download/v0.4.1/keeman_0.4.1_linux_amd64.tar.gz -O - | tar -xz
        sudo mv keeman /usr/local/bin
        validate_command keeman
        echo "[SUCCESS]: keeman is now installed !!!"
    fi
}


create_namespace() {
    validate_vars
    kubectl create namespace $FEED_NAME
}

create_eth_secret() {
    validate_vars
    ETH_PASS_CONTENT=$(sudo cat $ETH_PASS)
    sudo cp $KEYSTORE_FILE /home/chronicle/$FEED_NAME/keystore.json
    sudo chown chronicle:chronicle -R /home/chronicle/$FEED_NAME
    kubectl create secret generic $FEED_NAME-eth-keys \
    --from-file=ethKeyStore=/home/chronicle/$FEED_NAME/keystore.json \
    --from-literal=ethFrom=$ETH_FROM \
    --from-literal=ethPass=$ETH_PASS_CONTENT \
    --namespace $FEED_NAME
    echo "-----------------------------------------------------------------------------------------------------"
    echo "This is your Feed address:"
    echo "$ETH_FROM"
    echo "-----------------------------------------------------------------------------------------------------"
}

create_tor_secret() {
    validate_vars
    keeman gen | tee >(cat >&2) | keeman derive -f onion > /home/chronicle/$FEED_NAME/torkeys.json
    sudo chown chronicle:chronicle -R /home/chronicle/$FEED_NAME
    kubectl create secret generic $FEED_NAME-tor-keys \
        --from-literal=hostname="$(jq -r '.hostname' < /home/chronicle/$FEED_NAME/torkeys.json)" \
        --from-literal=hs_ed25519_secret_key="$(jq -r '.secret_key' < /home/chronicle/$FEED_NAME/torkeys.json)" \
        --from-literal=hs_ed25519_public_key="$(jq -r '.public_key' < /home/chronicle/$FEED_NAME/torkeys.json)" \
        --namespace $FEED_NAME
    declare -g TOR_HOSTNAME="$(jq -r '.hostname' < /home/chronicle/$FEED_NAME/torkeys.json)"
    echo "-----------------------------------------------------------------------------------------------------"
    echo "This is your .onion address:"
    echo "$TOR_HOSTNAME"
    echo "-----------------------------------------------------------------------------------------------------"
}

create_helm_release() {
    validate_vars
    helm repo add chronicle https://chronicleprotocol.github.io/charts/
    helm repo update
    helm install "$FEED_NAME" -f /home/chronicle/"$FEED_NAME"/generated-values.yaml  chronicle/feed --namespace "$FEED_NAME"
}

collect_vars() {
    if [ -z "${FEED_NAME:-}" ]; then
        echo ">> Enter feed name (eg chronicle-feed):"
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
    validate_vars
}

generate_values() {
    validate_vars
    
    # Ensure the directory exists
    DIRECTORY_PATH="/home/chronicle/${FEED_NAME}"
    mkdir -p "$DIRECTORY_PATH" || {
        echo "[ERROR]: Unable to create directory $DIRECTORY_PATH"
        exit 1
    }
    
    # Check if the directory was created successfully
    if [ ! -d "$DIRECTORY_PATH" ]; then
        echo "[ERROR]: Directory $DIRECTORY_PATH does not exist and failed to be created"
        exit 1
    fi
    
    # Generate the values.yaml file
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

  # ethereum RPC client
  ethRpcUrl: "${ETH_RPC_URL}"
  ethChainId: 1

  # default RPC client
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
    
    # Check if the file was created successfully
    if [ ! -f "$VALUES_FILE" ]; then
        echo "[ERROR]: Failed to create $VALUES_FILE"
        exit 1
    fi
    
    echo "You need to install the helm chart with the following command:"
    echo "-------------------------------------------------------------------------------------------------------------------------------"
    echo "|   helm install \"$FEED_NAME\" -f \"$VALUES_FILE\"  chronicle/feed --namespace \"$FEED_NAME\"       |"
    echo "-------------------------------------------------------------------------------------------------------------------------------"
}


main() {
    echo "[INFO]:..........running preflight checks........."
    validate_os
    validate_user
    echo "[INFO]:..........installing dependencies........."
    install_deps
    echo "[INFO]:..........gather input variables........."
    collect_vars
    echo "[INFO]:..........installing k8s chronicle stack.........."
    echo "[INFO]:..........create namespace $FEED_NAME.........."
    create_namespace
    echo "[INFO]:..........create secret with ETH keys.........."
    create_eth_secret
    echo "[INFO]:..........create secret with TOR keys.........."
    create_tor_secret
    echo "[INFO]:..........generate helm values file.........."
    generate_values
    echo "[INFO]:..........create helm release.........."
    create_helm_release
    echo "[NOTICE]: setup complete!"
}

main "$@"
