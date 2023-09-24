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
    echo "required: FEED_NAME, ETH_FROM, ETH_PASS, KEYSTORE_FILE, NODE_EXT_IP"
}

validate_vars() {
    if [[ -z "${FEED_NAME:-}" || -z "${ETH_FROM:-}" || -z "${ETH_PASS:-}" || -z "${KEYSTORE_FILE:-}" || -z "${NODE_EXT_IP:-}" ]]; then
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

main() {
    echo -e "\e[32m[INFO]:..........running preflight checks.........\e[0m"
    validate_os
    validate_user
    validate_sudo
    validate_command sudo
    validate_command curl
    validate_command wget
    echo -e "\e[32m[INFO]:..........installing dependencies.........\e[0m"
    install_deps
    echo -e "\e[32m[INFO]:..........gather input variables.........\e[0m"
    collect_vars
    echo -e "\e[32m[INFO]:..........installing k8s chronicle stack..........\e[0m"
    echo -e "\e[32m[INFO]:..........create namespace $FEED_NAME..........\e[0m"
    create_namespace
    echo -e "\e[32m[INFO]:..........create secret with ETH keys..........\e[0m"
    create_eth_secret
    echo -e "\e[32m[
