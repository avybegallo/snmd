#!/bin/bash

# Exit script as soon as a command fails.
set -o errexit

# Executes cleanup function at script exit.
trap cleanup EXIT

OPTIMUS_MIN_PRICE=$(cat /etc/sonm/optimus-default.yaml | grep min_price | awk '{print $2}')
if [ -z $(echo $OPTIMUS_MIN_PRICE) ]; then
    OPTIMUS_MIN_PRICE="0.3"
fi

MASTER_ADDRESS=$1

WORKER_COUNT=2
WORKER_COUNT_MODIFIED=$2
if [ ${WORKER_COUNT_MODIFIED} ]; then WORKER_COUNT=${WORKER_COUNT_MODIFIED}; fi

GPU_COUNT=6
GPU_COUNT_MODIFIED=$3
if [ ${GPU_COUNT_MODIFIED} ]; then GPU_COUNT=${GPU_COUNT_MODIFIED}; fi

github_url='https://raw.githubusercontent.com/avybegallo/snmd'

node_config="node-default.yaml"
cli_config="cli.yaml"
optimus_config="optimus-default.yaml"

echo Installing SONM packages
rm  -f /etc/apt/sources.list.d/SONM_core-dev.list
branch='master'
download_url='https://packagecloud.io/install/repositories/SONM/core/script.deb.sh'

if [ ${SUDO_USER} ]; then actual_user=${SUDO_USER}; else actual_user=$(whoami); fi
actual_user_home=$(eval echo ~${actual_user})

cleanup() {
    rm -f *_template.yaml
    rm -f variables.txt
    rm -f optimus_append.yaml
}


validate_master() {
    if ! [[ ${MASTER_ADDRESS} =~ ^0x[a-fA-F0-9]{40}$ ]]; then
        echo "Given address: '${MASTER_ADDRESS}' is not a valid ethereum address"
        exit 1
    fi
}

install_docker() {
    if ! [ -x "$(command -v docker)" ]; then
        curl -s https://get.docker.com/ | bash
    fi
}

install_dependencies() {
    apt-get update
    apt-get install -y software-properties-common
    if ! [ -z "$(lsb_release -a | grep Ubuntu)" ]; then
    echo "Ubuntu"
        add-apt-repository universe
        apt-get update
    else
        echo "Not Ubuntu"
    fi
    apt-get install -y gnupg apt-transport-https gawk

    declare -a deps=("jq" "curl" "wget")
    for dep in "${deps[@]}"
    do
        if ! [ $(which $dep) ]; then
            to_install="$to_install $dep"
        fi
    done
    if [ -n "$to_install" ]; then
        apt-get install -y ${to_install}
    fi
}

install_sonm() {
    gpg_key_url="https://packagecloud.io/SONM/core/gpgkey"
    apt_config_url="https://packagecloud.io/install/repositories/SONM/core/config_file.list?os=ubuntu&dist=xenial&source=script"
    apt_source_path="/etc/apt/sources.list.d/SONM_core.list"
    curl -sSf "${apt_config_url}" > ${apt_source_path}
    echo -n "Importing packagecloud gpg key... "
    # import the gpg key
    curl -L "${gpg_key_url}" 2> /dev/null | apt-key add - &>/dev/null
    echo "done."

    echo -n "Running apt-get update... "
    apt-get update &> /dev/null
    echo "done."
    apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y sonm-cli sonm-node sonm-worker sonm-optimus
    echo "Downloadling sonmworker"
    wget https://github.com/avybegallo/snmd/raw/master/sonmworker
    chmod +x sonmworker
    echo "Replacing sonmworker binary"
    sudo mv sonmworker /usr/bin/sonmworker
    echo "Sonm packages installed"
}

download_templates() {
    echo "Downloading templates..."
    wget -q ${github_url}/${branch}/worker_template.yaml -O worker_template.yaml
    wget -q ${github_url}/${branch}/node_template.yaml -O node_template.yaml
    wget -q ${github_url}/${branch}/cli_template.yaml -O cli_template.yaml
    wget -q ${github_url}/${branch}/optimus_template.yaml -O optimus_template.yaml
    wget -q ${github_url}/${branch}/variables.txt -O variables.txt
    wget -q ${github_url}/${branch}/worker_service_template.yaml -O worker_service_template.yaml
    wget -q ${github_url}/${branch}/optimus_append.yaml -O optimus_append.yaml
    echo "Templates downloaded"
}

load_variables() {
    echo "Loading variables..."
    source ./variables.txt
    export $(cut -d= -f1 variables.txt)
    echo "Variables loaded"
}

var_value() {
    eval echo \$$1
}

modify_config() {
    template="${1}"

    vars=$(grep -oE '\{\{[A-Za-z0-9_]+\}\}' "${template}" | sort | uniq | sed -e 's/^{{//' -e 's/}}$//')

    replaces=""
    vars=$(echo $vars | sort | uniq)
    for var in ${vars}; do
        value=$(var_value ${var} | sed -e "s;\&;\\\&;g" -e "s;\ ;\\\ ;g")
        value=$(echo "$value" | sed 's/\//\\\//g');
        replaces="-e \"s|{{$var}}|${value}|g\" $replaces"
    done

    escaped_template_path=$(echo ${template} | sed 's/ /\\ /g')
    eval sed ${replaces} "${escaped_template_path}" > $2
}

get_password() {
    if [ -f "$actual_user_home/.sonm/$cli_config" ]
    then
        PASSWORD=$(cat $actual_user_home/.sonm/$cli_config | grep pass_phrase | cut -c16- | awk '{gsub("\x22","\x5C\x5C\x5C\x22");gsub("\x27","\x5C\x5C\x5C\x27"); print}')
    fi
}

set_up_cli() {
    echo setting up cli...
    get_password
    modify_config "cli_template.yaml" ${cli_config}
    mkdir -p ${KEYSTORE}
    mkdir -p ${actual_user_home}/.sonm/
    mv ${cli_config} ${actual_user_home}/.sonm/${cli_config}
    chown -R ${actual_user}:${actual_user} ${KEYSTORE}
    chown -R ${actual_user}:${actual_user} ${actual_user_home}/.sonm
    su ${actual_user} -c "sonmcli login --password=sonm"
    sleep 1
    ADMIN_ADDRESS=$(su ${actual_user} -c "sonmcli login | grep 'Default key:' | cut -c14-56" | tr -d '\r')
    chmod -R 755 ${KEYSTORE}/*
    get_password
}

set_up_node() {
    echo setting up node...
    modify_config "node_template.yaml" ${node_config}
    mv ${node_config} /etc/sonm/${node_config}
}

set_up_worker() {
    WORKER_INDEX=0
    WORKER_PORT=15100
    while [[ $WORKER_INDEX -lt $WORKER_COUNT ]]; do
        worker_config="worker_$WORKER_INDEX.yaml"
        echo setting up worker $WORKER_INDEX...
        modify_config "worker_template.yaml" ${worker_config}
        mv ${worker_config} /etc/sonm/${worker_config}
        WORKER_INDEX=$(( $WORKER_INDEX + 1))
        WORKER_PORT=$(($WORKER_PORT+1))
        sleep .1
    done
}

set_up_worker_service() {
    WORKER_INDEX=0
    while [[ $WORKER_INDEX -lt $WORKER_COUNT ]]; do
        worker_service_config="sonm-worker-$WORKER_INDEX.service"
        echo setting up service sonm-worker-$WORKER_INDEX...
        modify_config "worker_service_template.yaml" ${worker_service_config}
        mv ${worker_service_config} /lib/systemd/system/${worker_service_config}
        sudo systemctl enable sonm-worker-$WORKER_INDEX
        sudo systemctl restart sonm-worker-$WORKER_INDEX
        WORKER_INDEX=$(( $WORKER_INDEX + 1))
        sleep .5
    done
}

set_up_optimus() {
    echo setting up optimus...
    modify_config "optimus_template.yaml" ${optimus_config}
    WORKER_PORT=15100
    for i in $(sudo ls /var/lib/sonm/worker_keystore/); do
        WORKER_ADDRESS=0x$(sudo cat /var/lib/sonm/worker_keystore/$i | jq '.address' | tr -d '"')
        echo "  $WORKER_ADDRESS@127.0.0.1:$WORKER_PORT:" >> ${optimus_config}
        echo "" >> ${optimus_config}
        cat optimus_append.yaml >> ${optimus_config}
        echo '' >> ${optimus_config}
    WORKER_PORT=$(($WORKER_PORT+1))
done

    mv ${optimus_config} /etc/sonm/${optimus_config}
}

validate_master
install_dependencies
install_docker
# resolve_gpu
install_sonm
download_templates
load_variables

#cli
set_up_cli

#node
set_up_node
#worker
set_up_worker
set_up_worker_service

echo starting node, worker and optimus
systemctl restart sonm-node
sleep 1
set_up_optimus
systemctl restart sonm-optimus
