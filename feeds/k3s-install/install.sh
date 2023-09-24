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

install_deps() {
    sudo apt-get update -y
    validate_command jq
    validate_command helm
    validate_command k3s
    validate_command keeman
    # ... (rest of the function as before)
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
        echo ">> Enter the Node External IP:"
        read -r NODE_EXT_IP
    fi
    validate_vars
}

generate_values() {
    validate_vars
    cat <<EOF > /home/chronicle/"${FEED_NAME}"/generated-values.yaml
# ... (rest of the function as before)
EOF
    echo "You need to install the helm chart with the following command:"
    echo "-------------------------------------------------------------------------------------------------------------------------------"
    echo "|   helm install "$FEED_NAME" -f /home/chronicle/"$FEED_NAME"/generated-values.yaml  chronicle/feed --namespace "$FEED_NAME"       |"
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
