#!/bin/bash
set -euo pipefail # Enable strict mode for bash

LOG_FILE="installer-crash.log"

trap 'handle_error $LINENO' ERR

handle_error() {
    echo -e "\e[31m[ERROR]: Script failed at line $1 with status $?\e[0m" | tee -a "$LOG_FILE"
    echo "OS Version: $(lsb_release -rs)" | tee -a "$LOG_FILE"
    echo "User: $USER" | tee -a "$LOG_FILE"
    echo "Date: $(date)" | tee -a "$LOG_FILE"

    # Log environment variables, but be cautious with sensitive information
    [[ -n "${FEED_NAME:-}" ]] && echo "FEED_NAME: $FEED_NAME" | tee -a "$LOG_FILE"
    [[ -n "${ETH_FROM:-}" ]] && echo "ETH_FROM: $ETH_FROM" | tee -a "$LOG_FILE"
    [[ -n "${ETH_PASSWORD:-}" ]] && echo "ETH_PASSWORD: $ETH_PASSWORD" | tee -a "$LOG_FILE"
    [[ -n "${ETH_KEYSTORE:-}" ]] && echo "ETH_KEYSTORE: $ETH_KEYSTORE" | tee -a "$LOG_FILE"
    [[ -n "${ETH_RPC_URL:-}" ]] && echo "ETH_RPC_URL: $ETH_RPC_URL" | tee -a "$LOG_FILE"
    [[ -n "${NODE_EXT_IP:-}" ]] && echo "ETH_RPC_URL: $NODE_EXT_IP" | tee -a "$LOG_FILE"
}


# Source the .env file if it exists
if [ -f ".env" ]; then
    source .env
fi

display_usage() {
    echo -e "\e[33m[NOTICE]: Usage:\e[0m"
    echo "======"
    echo "./install.sh"
    echo "# follow the prompts if variables are not set in .env file"
    echo "required: FEED_NAME, ETH_FROM, ETH_PASSWORD, ETH_KEYSTORE, NODE_EXT_IP, ETH_RPC_URL"
}

validate_vars() {
    if [[ -z "${FEED_NAME:-}" || -z "${ETH_FROM:-}" || -z "${ETH_PASSWORD:-}" || -z "${ETH_KEYSTORE:-}" || -z "${NODE_EXT_IP:-}" || -z "${ETH_RPC_URL:-}" ]]; then
        echo -e "\e[31m[ERROR]: All variables are required!\e[0m"
        display_usage
        exit 1
    fi
}

validate_os() {
    OS_VERSION=$(lsb_release -rs)
    if [[ ! "$OS_VERSION" =~ ^(22\.04|23\.04)(\..*)?$ ]]; then
        echo -e "\e[31m[ERROR]: This script is designed for Ubuntu 22.04 and 23.04!\e[0m"
        exit 1
    fi
}

validate_user() {
    if [ "$USER" == "root" ]; then
        echo -e "\e[31m[ERROR]: This script should not be run as root!\e[0m"
        echo "Would you like to create a new user to run this script? (y/n)"
        read -r response
        if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            echo "Enter the username for the new user:"
            read -r new_user
            sudo useradd -m -s /bin/bash "$new_user"
            sudo passwd "$new_user"
            sudo usermod -aG sudo "$new_user"
            echo "$new_user ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers
            echo -e "\e[32m[INFO]: User $new_user created and added to the sudoers group. Please log in as $new_user and run the script again.\e[0m"
            echo -e "\e[33m[NOTICE]: You may need to log in anew or start a new terminal session as $new_user for the group changes to take effect.\e[0m"

            exit 0
        else
            echo -e "\e[31m[ERROR]: Please run the script as a non-root user with sudo privileges.\e[0m"
            exit 1
        fi
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

    for cmd in dig curl jq; do
        if ! command -v $cmd > /dev/null; then
            echo -e "\e[32m[INFO]:..........Installing $cmd.........\e[0m"
            sudo apt-get install -y $cmd
            validate_command $cmd
            echo -e "\e[32m[SUCCESS]: $cmd is now installed !!!\e[0m"
        fi
    done

    # Validate and install helm
    if ! command -v helm > /dev/null; then
        echo -e "\e[32m[INFO]:..........Installing helm.........\e[0m"
        curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        validate_command helm
        echo -e "\e[32m[SUCCESS]: helm is now installed !!!\e[0m"
    fi

    # Validate and install k3s
    if ! command -v k3s > /dev/null; then
        if [ -z "${NODE_EXT_IP:-}" ]; then
            echo -e "\e[31m[ERROR]: NODE_EXT_IP is not set! Exiting...\e[0m"
            exit 1
        fi
        echo -e "\e[32m[INFO]:..........Installing k3s.........\e[0m"
        curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -s - --node-external-ip $NODE_EXT_IP
        mkdir -p $HOME/.kube
        sudo cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config
        sudo chown $USER:$USER -R $HOME/.kube
        sudo chmod 600 $HOME/.kube/config
        echo "export KUBECONFIG=$HOME/.kube/config" >> $HOME/.bashrc
        echo "source <(kubectl completion bash)" >> $HOME/.bashrc
        source $HOME/.bashrc
        validate_command k3s
        echo -e "\e[32m[SUCCESS]: k3s is now installed !!!\e[0m"
    fi

    # Validate and install keeman
    if ! command -v keeman > /dev/null; then
        echo -e "\e[32m[INFO]:..........Installing keeman.........\e[0m"
        wget https://github.com/chronicleprotocol/keeman/releases/download/v0.4.1/keeman_0.4.1_linux_amd64.tar.gz -O - | tar -xz
        sudo mv keeman /usr/local/bin
        validate_command keeman
        echo -e "\e[32m[SUCCESS]: keeman is now installed !!!\e[0m"
    fi
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
        while true; do
            echo ">> Enter your ETH Address (eg: 0x3a...):"
            read -r ETH_FROM
            if [[ "$ETH_FROM" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
                break
            else
                echo -e "\e[31m[ERROR]: Invalid ETH Address! It should start with 0x and be 42 characters long.\e[0m"
            fi
        done
    fi
    if [ -z "${ETH_KEYSTORE:-}" ]; then
        while true; do
            echo ">> Enter the path to your ETH keystore (eg: /path/to/keystore.json):"
            read -r ETH_KEYSTORE
            if sudo test -f "$ETH_KEYSTORE"; then
                break
            else
                echo -e "\e[31m[ERROR]: The file $ETH_KEYSTORE does not exist! Please enter a valid file path.\e[0m"
            fi
        done
    fi

    if [ -z "${ETH_PASSWORD:-}" ]; then
        while true; do
            echo ">> Enter the path to your ETH password file (eg: /path/to/password.txt):"
            read -r ETH_PASSWORD
            if sudo test -f "$ETH_PASSWORD"; then
                break
            else
                echo -e "\e[31m[ERROR]: The file $ETH_PASSWORD does not exist! Please enter a valid file path.\e[0m"
            fi
        done
    fi
    if [ -z "${NODE_EXT_IP:-}" ]; then
        echo ">> Obtaining the Node External IP..."
        NODE_EXT_IP=$(get_public_ip)
        echo ">> Node External IP is $NODE_EXT_IP"
    fi
    if [ -z "${ETH_RPC_URL:-}" ]; then
        while true; do
            echo ">> Enter your ETH rpc endpoint (eg: https://eth.llamarpc.com):"
            read -r ETH_RPC_URL
            if [[ "$ETH_RPC_URL" =~ ^https?:// ]]; then
                break
            else
                echo -e "\e[31m[ERROR]: The URL must start with http:// or https://\e[0m"
            fi
        done
    fi
    validate_vars
}

create_namespace() {
    set_kubeconfig
    if kubectl get namespace "$FEED_NAME" > /dev/null 2>&1; then
        echo -e "\e[33m[WARN]: Namespace $FEED_NAME already exists!\e[0m"
        read -p "Would you like to continue using the existing namespace? (y/n): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "\e[33m[NOTICE]: User chose not to use the existing namespace $FEED_NAME. Please change the value of FEED_NAME if needed.\e[0m"
            return 1
        fi
    else
        kubectl create namespace $FEED_NAME
    fi
    mkdir -p $HOME/$FEED_NAME
}

create_eth_secret() {
    set_kubeconfig
    validate_vars
    ETH_PASSWORD_CONTENT=$(sudo cat $ETH_PASSWORD)
    sudo cp $ETH_KEYSTORE $HOME/$FEED_NAME/keystore.json
    sudo chown $USER:$USER -R $HOME/$FEED_NAME

    # Check if the secret already exists
    if kubectl get secret $FEED_NAME-eth-keys --namespace $FEED_NAME > /dev/null 2>&1; then
        echo -e "\e[33m[WARN]: Secret $FEED_NAME-eth-keys already exists. Updating...\e[0m"
        kubectl delete secret $FEED_NAME-eth-keys --namespace $FEED_NAME
    fi

    # Create or update the secret
    kubectl create secret generic $FEED_NAME-eth-keys \
    --from-file=ethKeyStore=$HOME/$FEED_NAME/keystore.json \
    --from-literal=ethFrom=$ETH_FROM \
    --from-literal=ethPass=$ETH_PASSWORD_CONTENT \
    --namespace $FEED_NAME || {
        echo -e "\e[31m[ERROR]: Failed to create/update secret $FEED_NAME-eth-keys\e[0m"
        exit 1
    }

    echo -e "\e[33m-----------------------------------------------------------------------------------------------------\e[0m"
    echo -e "\e[33mThis is your Feed address:\e[0m"
    echo -e "\e[33m$ETH_FROM\e[0m"
    echo -e "\e[33m-----------------------------------------------------------------------------------------------------\e[0m"
}

create_tor_secret() {
    set_kubeconfig
    validate_vars

    # Check if torkeys.json already exists
    if [ ! -f "$HOME/$FEED_NAME/torkeys.json" ]; then
        keeman gen | tee >(cat >&2) | keeman derive -f onion > "$HOME/$FEED_NAME/torkeys.json"
    else
        echo -e "\e[33m[INFO]: Using existing torkeys.json file.\e[0m"
    fi

    # Check if the secret already exists
    if kubectl get secret $FEED_NAME-tor-keys --namespace $FEED_NAME > /dev/null 2>&1; then
        echo -e "\e[33m[WARN]: Secret $FEED_NAME-tor-keys already exists. Updating...\e[0m"
        kubectl delete secret $FEED_NAME-tor-keys --namespace $FEED_NAME
    fi

    # Create or update the secret
    kubectl create secret generic $FEED_NAME-tor-keys \
        --from-literal=hostname="$(jq -r '.hostname' < $HOME/$FEED_NAME/torkeys.json)" \
        --from-literal=hs_ed25519_secret_key="$(jq -r '.secret_key' < $HOME/$FEED_NAME/torkeys.json)" \
        --from-literal=hs_ed25519_public_key="$(jq -r '.public_key' < $HOME/$FEED_NAME/torkeys.json)" \
        --namespace $FEED_NAME || {
        echo -e "\e[31m[ERROR]: Failed to create/update secret $FEED_NAME-tor-keys\e[0m"
        exit 1
    }

    declare -g TOR_HOSTNAME="$(jq -r '.hostname' < $HOME/$FEED_NAME/torkeys.json)"
    echo -e "\e[33m-----------------------------------------------------------------------------------------------------\e[0m"
    echo -e "\e[33mThis is your .onion address:\e[0m"
    echo -e "\e[33m$TOR_HOSTNAME\e[0m"
    echo -e "\e[33m-----------------------------------------------------------------------------------------------------\e[0m"
}

generate_values() {
    validate_vars

    DIRECTORY_PATH="$HOME/${FEED_NAME}"
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
  logLevel: "${LOG_LEVEL:-warning}"
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
  logLevel: "${LOG_LEVEL:-warning}"
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

    # Check if release already exists in the specified namespace
    if helm list -n "$FEED_NAME" | grep -q "^$FEED_NAME"; then
        echo -e "\e[33m[WARNING]: Helm release $FEED_NAME already exists in namespace $FEED_NAME.\e[0m"
        echo "1) Upgrade the release"
        echo "2) Terminate the script"
        echo "3) Delete the release and install again"
        read -p "Enter your choice [1/2/3]: " choice

        case "$choice" in
            1)
                echo -e "\e[33m[WARN]: Attempting to upgrade existing feed: $FEED_NAME in namespace: $FEED_NAME.\e[0m"
                helm upgrade "$FEED_NAME" -f "$HOME/$FEED_NAME/generated-values.yaml" chronicle/feed --namespace "$FEED_NAME"
                ;;
            2)
                echo -e "\e[33m[WARN]: Terminating the script as per user request.\e[0m"
                exit 0
                ;;
            3)
                echo -e "\e[33m[WARN]: Deleting the release, and installing again.\e[0m"
                helm uninstall "$FEED_NAME" --namespace "$FEED_NAME"
                helm install "$FEED_NAME" -f "$HOME/$FEED_NAME/generated-values.yaml" chronicle/feed --namespace "$FEED_NAME"
                ;;
            *)
                echo -e "\e[31m[ERROR]: Invalid choice. Terminating the script.\e[0m"
                exit 1
                ;;
        esac
    else
        echo -e "\e[33m[INFO]: First attempt at installing feed: $FEED_NAME in namespace: $FEED_NAME.\e[0m"
        helm install "$FEED_NAME" -f "$HOME/$FEED_NAME/generated-values.yaml" chronicle/feed --namespace "$FEED_NAME"
    fi
}

main() {
    echo -e "\e[32m[INFO]:..........running preflight checks.........\e[0m"
    validate_os
    validate_user
    validate_sudo
    echo -e "\e[32m[INFO]:..........gather input variables.........\e[0m"
    collect_vars
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
    echo -e "\e[33m[SUCCESS]: setup complete!\e[0m"
}

main "$@"
