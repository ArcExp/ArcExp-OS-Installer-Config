# Make pipes return last non-zero exit code, else return zero
set -o pipefail

declare -r workdir='/mnt'
declare -r osidir='/etc/os-installer'
declare -r rootlabel='ArcExp_root'

# Executes program or build-in and quits osi on non-zero exit code
task_wrapper () {
	if [[ -n $OSI_CONFIG_DEBUG ]]; then
		$* >> $HOME/installation.log
	else
		$*
	fi

	if [[ ! $? -eq 0  ]]; then
		printf "Task \"$*\" exited with non-zero exit code, quitting...\n"
		exit 1
	fi
}
