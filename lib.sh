# Make pipes return last non-zero exit code, else return zero
set -o pipefail

declare -r workdir='/mnt'
declare -r osidir='/etc/os-installer'

# Ensure user is able to run sudo
for group in $(groups); do

	if [[ $group == 'wheel' || $group == 'sudo' ]]; then
		declare -ri sudo_ok=1
	fi

done

# Executes program or build-in and quits osi on non-zero exit code
task_wrapper () {
	if [[ ! $? -eq 0  ]]; then
		printf "Task \"$*\" exited with non-zero exit code, quitting...\n"
		exit 1
	fi
}
