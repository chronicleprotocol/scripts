#!/bin/bash
set -euo pipefail # Enable strict mode for bash

EPOCH=$(date +%s)
LOG_FILE="/tmp/upgrader-crash-${EPOCH}.log"

touch "$LOG_FILE"

trap 'handle_error $LINENO' ERR

handle_error() {
    echo -e "\e[31m[ERROR]: Script failed at line $1 with status $?\e[0m" | tee -a "$LOG_FILE"
    display_usage

}

display_usage() {
    echo -e "\e[33m[NOTICE]: Usage:\e[0m"
    echo "======"
    echo "./upgrade.sh"
    echo "# export FEED_NAME=<MY_FEED_NAME>, set in .env file"
    echo "required: FEED_NAME"
}

# Source the .env file if it exists
validate_dot_env() {
    if [ -f ".env" ]; then
        source .env
        [[ -n "${FEED_NAME:-}" ]] && echo "FEED_NAME: $FEED_NAME" | tee -a "$LOG_FILE"
    else
        echo -e "\e[31m[ERROR]: Unable to locate .env file!\e[0m" | tee -a "$LOG_FILE"
        display_usage
    fi
    if [[ -z "${FEED_NAME:-}" ]]; then
        echo -e "\e[31m[ERROR]: FEED_NAME is not set! Exiting...\e[0m" | tee -a "$LOG_FILE"
        display_usage
        exit 1
    fi
    echo "OS Version: $(lsb_release -rs)" | tee -a "$LOG_FILE"
    echo "User: $USER" | tee -a "$LOG_FILE"
    echo "Date: $(date)" | tee -a "$LOG_FILE"
}

# validate if user is root, and if so, prompt user to switch to non-root user with sudo privileges
validate_user() {
    if [ "$USER" == "root" ]; then
        echo -e "\e[31m[ERROR]: This script should not be run as root!\e[0m"
        echo -e "\e[31m[ERROR]: Please run the script as a non-root user with sudo privileges.\e[0m"
        echo -e "\e[31m[ERROR]: Switch to the user created by the installer script and re-run the script.\e[0m" | tee -a "$LOG_FILE"
        display_usage
        exit 1
    fi
}

# install yq if not installed
validate_command() {
    command -v yq > /dev/null 2>&1 || {
        echo -e "\e[31m[ERROR]: yq is not installed!\e[0m"  | tee -a "$LOG_FILE"
        exit 1
        echo -e "\e[32m[INFO]:..........Installing yq.........\e[0m"
        sudo apt-get update -y
        sudo apt-get install -y yq
        validate_command yq
        echo -e "\e[32m[SUCCESS]: yq is now installed !!!\e[0m"
    }
}

sanitize_values() {
    echo -e "\e[32m[INFO]:..........Creating backup of generated-values.yaml.........\e[0m"
    # create a backup of the current generated-values.yaml as generated-values.yaml.bak
    helm get values $FEED_NAME -n $FEED_NAME  > $HOME/$FEED_NAME/generated-values.yaml.bak

    echo -e "\e[32m[INFO]:..........Sanitizing generated-values.yaml.........\e[0m"
    # remove .Values.musig from generated-values.yaml
    yq -y -i 'del(."musig")' $HOME/$FEED_NAME/generated-values.yaml
    # remove .Values.ghost.chainId from generated-values.yaml
    yq -y -i 'del(."ghost"."chainId")' $HOME/$FEED_NAME/generated-values.yaml
    # remove .Values.ghost.ethChainId from generated-values.yaml
    yq -y -i 'del(."ghost"."ethChainId")' $HOME/$FEED_NAME/generated-values.yaml
}

create_helm_upgrade() {
    # helm upgrade $FEED_NAME with --debug and --dry-run
    echo -e "\e[32m[INFO]:..........DRY RUN UPGRADE feed: $FEED_NAME in namespace: $FEED_NAME.........\e[0m"
    helm upgrade "$FEED_NAME" -f "$HOME/$FEED_NAME/generated-values.yaml" chronicle/validator --namespace "$FEED_NAME" --debug --dry-run

    # prompt user to confirm upgrade, accept a Y/N
    echo -e "\e[33m[NOTICE]: DRY RUN UPGRADE complete! Do you want to continue with the upgrade? (y/n): "
    read -r response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        echo -e "\e[33m[NOTICE]: Upgrading feed: $FEED_NAME in namespace: $FEED_NAME.\e[0m"
        helm upgrade "$FEED_NAME" -f "$HOME/$FEED_NAME/generated-values.yaml" chronicle/validator --namespace "$FEED_NAME"
    else
        echo -e "\e[33m[NOTICE]: Terminating the script as per user request.\e[0m"
        # print the helm command they will need to run
        echo -e "\e[33m[NOTICE]: You can run the following command to upgrade the feed:\e[0m"
        echo -e "\e[33m[NOTICE]: helm upgrade $FEED_NAME -f $HOME/$FEED_NAME/generated-values.yaml chronicle/validator --namespace $FEED_NAME\e[0m" | tee -a "$LOG_FILE"
        exit 0
    fi
}

main() {
    echo -e "\e[32m[INFO]:..........Attempting to upgrade Chronicle feed.........\e[0m"
    validate_user
    validate_dot_env
    validate_command
    sanitize_values
    create_helm_upgrade
    echo -e "\e[33m[SUCCESS]: Upgrade complete!\e[0m"
}

main "$@"