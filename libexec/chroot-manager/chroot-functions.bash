#!/usr/bin/env bash

# Copyright 2006 - 2008 Joshua Nichols
# Copyright 2008 Ingmar Vanhassel, Wulf C. Krueger
#
# This file is part of chroot-manager.
#
# chroot-manager is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 2 or 3 of the License at your
# option.
#
# chroot-manager is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with chroot-manager.  If not, see <http://www.gnu.org/licenses/>.

die() {
    local ret=${1}
    shift
    echo "${*}"
    exit ${ret}
}

source /usr/libexec/paludis/echo_functions.bash || die "Failed to source echo_functions.bash"
CHROOT_PREFIX=$(dirname ${0})/.. # is there a better way?
source "${CHROOT_PREFIX}/etc/chroot-manager.conf" || die "failed to source chroot-manager.conf"

verbose() {
    [[ -n ${CHROOT_VERBOSE} ]]
}

init_chroot_env() {
    CHROOT_NAME="${1}"

    local chroot_config="${CHROOT_ETC}/chroots/${CHROOT_NAME}"
    if [[ ! -f "${chroot_config}" ]]; then
        eerror "${chroot_config} is not a file or does not exist"
        return 1
    fi
    source "${chroot_config}"
    CHROOT_HOME="${CHROOTS_HOME}/${CHROOT_NAME}"

    # If we're using a device for chroot
    if [[ -n ${CHROOT_DEV} ]]; then
        # attempt to mount if it isn't already
        if ! is_mounted "${CHROOT_HOME}"; then
            verbose && ebegin "Mounting ${CHROOT_DEV} to ${CHROOT_HOME}"
            mount ${CHROOT_DEV} ${CHROOT_HOME}
            local result=$?
            verbose && eend ${result}
            if [[ ${result} != 0 ]]; then
                eerror "Problem mounting ${CHROOT_DEV} to ${CHROOT_HOME}"
                exit 1
            fi
        fi
    fi
}

de_init_chroot_env() {
    CHROOT_NAME="${1}"

    local chroot_config="${CHROOT_ETC}/chroots/${CHROOT_NAME}"
    if [[ ! -f "${chroot_config}" ]]; then
        eerror "${chroot_config} is not a file or does not exist"
        return 1
    fi
    source "${chroot_config}"
    CHROOT_HOME="${CHROOTS_HOME}/${CHROOT_NAME}"
}

list_chroots() {
    for vm_chroot in $(find ${CHROOT_HOME} -maxdepth 1 -type d); do
        vm_chroot=${vm_chroot#${CHROOT_HOME}}
        vm_chroot=${vm_chroot//\//}
        echo ${vm_chroot}
    done
}

sudo_wrapper() {
    local command=${*}

    if [[ ${UID} != 0 ]]; then
        sudo ${command}
    else
        ${command}
    fi
}

setup_initial_chroot() {
    setup_chroot
    enter_chroot source /etc/profile
    teardown_chroot
}

copy_chroot_files() {
        local action="$1"
    local chroot_config="${CHROOT_ETC}/chroots/${CHROOT_NAME}"
    verbose && echo "Reading config file for ${CHROOT_NAME} at ${chroot_config}"

    if [[ ! -f ${chroot_config} ]]; then
        echo "File does not exist: ${chroot_config}"
        return 1
    fi

    local file_configs=$(source ${chroot_config} >/dev/null 2>&1; echo ${FILE_CONFIGS})
    local file_config
    for file_config in ${file_configs}; do
        verbose && einfo "Processing '${file_config}' file set"
        local file_config_path="${CHROOT_ETC}/chroot-files/${file_config}.files"
        mounts_loop_helper "${action}" < ${file_config_path}
    done
}


# we have a few helper methods, bind_dir and unbind_dir.
# these do the heavy lifting of, uh, binding and unbinding :)
# we pass the names here, because they get eval'd later on.
# basically, we're trying to avoid excessively redudant code

bind_chroot_dirs() {
    chroot_dirs_helper "bind_dir"
}

unbind_chroot_dirs() {
    chroot_dirs_helper "unbind_dir"
}

chroot_dirs_helper() {
    local action="$1"
    local chroot_config="${CHROOT_ETC}/chroots/${CHROOT_NAME}"
    verbose && echo "Reading config file for ${CHROOT_NAME} at ${chroot_config}"

    if [[ ! -f ${chroot_config} ]]; then
        echo "File does not exist: ${chroot_config}"
        return 1
    fi

    local mount_configs=$(source ${chroot_config} >/dev/null 2>&1; echo ${MOUNT_CONFIGS})
    local mount_config
    for mount_config in ${mount_configs}; do
        verbose && einfo "Processing '${mount_config}' mounts"
        local mount_config_path="${CHROOT_ETC}/chroot-mounts/${mount_config}.mounts"
        mounts_loop_helper ${action} < ${mount_config_path}
    done
}

copy_files() {
    local chroot_path="${1}"
    local real_path="${2}"
    local chrooted_path="${CHROOT_HOME}${chroot_path}"
    local chrooted_dir=$(dirname "${chrooted_path}")

    if [[ ! -d "${chrooted_dir}" ]]; then
        ebegin "Creating ${chrooted_dir}"
        mkdir -p "${chrooted_dir}"
        if [[ "$?" != 0 ]]; then
            eerror "Could not create ${chrooted_dir}"
            return 1
        fi
        eend
    fi

    ebegin "Copying ${real_path} to ${chrooted_path}"
    cp -pf ${real_path} ${chrooted_path}
    eend $?
}

# binding helper function. takes a path on the real system, and binds it to
# a path living inside the chroot
bind_dir() {
    local chroot_path="${1}"
    local real_path="${2}"
    local chrooted_path="${CHROOT_HOME}${chroot_path}"

    if ! is_mounted "${chrooted_path}"; then
        if [[ ! -d "${chrooted_path}" ]]; then
            ebegin "Creating ${chrooted_path}"
            mkdir -p "${chrooted_path}"
            if [[ "$?" != 0 ]]; then
                eerror "Could not create ${chrooted_path}"
                return 1
            fi
            eend
        fi

        ebegin "Binding ${real_path} to ${chrooted_path}"
        mount -o rbind ${real_path} ${chrooted_path}
        eend $?
    else
        verbose && ewarn "${chrooted_path} already mounted, skipping."
    fi
}

# unbinding helper function. unbinds a path living inside the chroot.
unbind_dir() {
    local chroot_path="${1}"
    local chrooted_path="${CHROOT_HOME}${chroot_path}"
    local real_path="${2}"

    if is_mounted "${chrooted_path}"; then
        ebegin "Unbinding ${real_path} from ${chrooted_path}"

        umount "${chrooted_path}" || umount -l "${chrooted_path}"
        eend $?
    fi
}

mounts_loop_helper() {
    local function="${1}"
    shift

    declare -a command_list
    local line

    read line
    local result=$?
    while [[ ${result} == 0 ]]; do
        # Ignore comments
        if [[ ${line%%#*} == "" ]]; then
             read line
             result=$?
             continue
        fi

        # get rid of any spaces
        line="${line// /}"

        local chroot_path="${line%%=*}"
        local real_path="${line##*=}"

#        eval "${function}" "${chroot_path}" "${real_path}"
#        echo "${function}" "${chroot_path}" "${real_path}"

        if [[ "${function}" == "bind_dir" ]]; then
            command_list=( "${command_list[@]}" "${function} ${chroot_path} ${real_path}" )
        elif [[ "${function}" == "unbind_dir" ]]; then
            command_list=( "${function} ${chroot_path} ${real_path}" "${command_list[@]}" )
        elif [[ "${function}" == "copy_files" ]]; then
            command_list=( "${command_list[@]}" "${function} ${real_path} ${chroot_path}" )
        fi

        read line
        result=$?
    done

    for command in "${command_list[@]}"; do
#        echo "${command}"
        eval "${command}"
    done
}

is_mounted() {
    local mount_point="${1}"

    # replace double-slashes with single ones
    mount_point="${mount_point/\/\///}"

    # strip trailing slash
    [[ ${mount_point} =~ "\/$" ]] && mount_point="${mount_point%%/}"

    local mounted_dir
    for mounted_dir in $(awk '{print $2}' /etc/mtab); do
        if [[ "${mounted_dir}" == "${mount_point}" ]]; then
            return 0
        fi
    done

    return 1
}
