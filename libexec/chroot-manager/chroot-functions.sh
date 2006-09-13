
source "/sbin/functions.sh" 2>/dev/null || die "Failed to source /sbin/functions.sh"
CHROOT_PREFIX=$(dirname ${0})/.. # is there a better way?
source "${CHROOT_PREFIX}/etc/chroot-manager.conf" 2>/dev/null || die "failed to source chroot-manager.conf"

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

list_chroots() {
	for vm_chroot in $(find ${CHROOT_HOME} -maxdepth 1 -type d); do
		vm_chroot=${vm_chroot#${CHROOT_HOME}}
		vm_chroot=${vm_chroot//\//}
		echo ${vm_chroot}
	done
}

sudo_wrapper() {
	local command=${*}

	if [ ${UID} != 0 ]; then
		sudo ${command}
	else
		${command}
	fi
}

setup_initial_chroot() {
	setup_chroot
	enter_chroot java-config -S ${TARGET_VM}
	enter_chroot env-update
	enter_chroot sed -e 's/buildpkg//' -i /etc/make.conf
	if [ ! -z ${NOJIKES} ]; then
		enter_chroot sed -e 's/jikes//' -i /etc/make.conf
	fi
	teardown_chroot
}


# we have a few helper methods, bind_dir and unbind_dir.
# these do the heavy lifting of, uh, binding and unbinding :)
# we pass the names here, because they get eval'd later on.
# basically, we're trying to avoid excessively redudant code


function bind_chroot_dirs() {
	chroot_dirs_helper "bind_dir"
}

function unbind_chroot_dirs() {
	chroot_dirs_helper "unbind_dir"
}

function chroot_dirs_helper() {
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
		mount -o bind ${real_path} ${chrooted_path}
		eend $?
	else
		verbose && ewarn "${chrooted_path} already mounted, skipping."
	fi
}

# binding helper function. takes a path on the real system, and binds it to
# a path living inside the chroot
unbind_dir() {
	local chroot_path="${1}"
	local chrooted_path="${CHROOT_HOME}${chroot_path}"
	local real_path="${2}"

	if is_mounted "${chrooted_path}"; then
		verbose && ebegin "Unbinding ${real_path} from ${chrooted_path}"

		umount "${chrooted_path}"
		verbose && eend $?
	fi
}

function mounts_loop_helper() {
	local function="${1}"
	shift

	local line
	read line
	local result=$?
	while [[ ${result} == 0 ]]; do
		# Ignore comments
		[[ ${line%%#*} == "" ]] && continue

		# get rid of any spaces
		line="${line// /}"

		local chroot_path="${line%%=*}"
		local real_path="${line##*=}"

		eval "${function}" "${chroot_path}" "${real_path}"

		read line
		result=$?
	done
}

function is_mounted() {
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
