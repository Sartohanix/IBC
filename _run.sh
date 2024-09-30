#!/bin/bash


#################"""  TTTTTTTTTOOOOOOOOOOOODDDDDDDDDDOOOOOOOOOO "###############
# DEPENDENCY PACKAGES : "libxtst6", "libxi6"

#########################################
#                                       #
#    Generate the IBC.ini config file   #
#                                       #
#########################################


json_file="$l_dir/IBconfig.json"
# Check if the JSON file exists
if [ ! -f "$json_file" ]; then
	echo "Error: IBC JSON config file not found at $json_file"
	exit 1
fi

# Process the JSON and write to IBC.ini
ini_file="$l_dir/IBconfig.ini"

# Use jq to extract setting-value pairs
jq -r '
  def extract_pairs:
    to_entries
    | map(
        if .value | type == "object" and has("value") then
          "\(.key)=\(.value.value)"
        elif .value | type == "object" or type == "array" then
          .value | extract_pairs
        else
          empty
        end
      )
    | .[];

  extract_pairs
' "$json_file" > "$ini_file"

# Check proper generation of .ini file
if [ ! -f "$ini_file" ]; then
	echo "Error: $ini_file file not generated properly."
	exit 1
fi


#########################################
#                                       #
#     Global variables: definitions     #
#                                       #
#########################################


program=Gateway
entry_point=ibcalpha.ibc.IbcGateway

ibg_path="$g_path/modules/ibg"
tws_settings_path="$ibg_path/Jts"
	mkdir -p "$tws_settings_path" # Make sure the settings dir exists
ibc_ini="$l_dir/IBconfig.ini"

java_path="$ibg_path/jre/bin"
jars="$ibg_path/jars"
install4j="$ibg_path/.install4j"

vmoptions_source="$ibg_path/ibgateway.vmoptions"

got_api_credentials=1
hidden_credentials="*** ***"

# errorlevel set by IBC if second factor authentication dialog times out and
# ExitAfterSecondFactorAuthenticationTimeout setting is true
let E_2FA_DIALOG_TIMED_OUT=$((1111 % 256))

# errorlevel set by IBC if login dialog is not displayed within the time
# specified in the LoginDialogDisplayTimeout setting
E_LOGIN_DIALOG_DISPLAY_TIMEOUT=$((1112 % 256))


#########################################
#                                       #
#        Construct the classpath        #
#                                       #
#########################################


declare ibc_classpath

for jar in "${jars}"/*.jar; do
	if [[ -n "${ibc_classpath}" ]]; then
		ibc_classpath="${ibc_classpath}:"
	fi
	ibc_classpath="${ibc_classpath}${jar}"
done

ibc_classpath="${ibc_classpath}:$install4j/i4jruntime.jar:${l_dir}/IBC.jar"


########################################
#                                      #
#     Generate the JAVA VM options     #
#                                      #
########################################


declare -a vm_options

index=0
while read line; do
	if [[ -n ${line} && ! "${line:0:1}" = "#" && ! "${line:0:2}" = "-D" ]]; then
		vm_options[$index]="$line"
		((index++))
	fi
done <<< $(cat ${vmoptions_source})

java_vm_options=${vm_options[*]}
java_vm_options="$java_vm_options -Dtwslaunch.autoupdate.serviceImpl=com.ib.tws.twslaunch.install4j.Install4jAutoUpdateService"
java_vm_options="$java_vm_options -Dchannel=latest"
java_vm_options="$java_vm_options -Dexe4j.isInstall4j=true"
java_vm_options="$java_vm_options -Dinstall4jType=standalone"
java_vm_options="$java_vm_options -DjtsConfigDir=${tws_settings_path}"

ibc_session_id=$(mktemp -u XXXXXXXX)
java_vm_options="$java_vm_options -Dibcsessionid=$ibc_session_id"



########################################
#                                      #
#       Auto-restart handling          #
#                                      #
########################################

find_auto_restart() {
	local autorestart_path=""
	local f=""
	restarted_needed=
	for i in $(find $tws_settings_path -type f -name "autorestart"); do
		local x=${i/$tws_settings_path/}
		local y=$(echo $x | xargs dirname)/.
		local e=$(echo "$y" | cut -d/ -f3)
		if [[ "$e" = "." ]]; then
			if [[ -z $f ]]; then
				f="$i"
				echo "autorestart file found at $f"
				autorestart_path=$(echo "$y" | cut -d/ -f2)
			else
				autorestart_path=
				echo "WARNING: deleting extra autorestart file found at $i"
				rm $i
				echo "WARNING: deleting first autorestart file found"
				rm $f
			fi
		fi
	done

	if [[ -z $autorestart_path ]]; then
		if [[ -n $f ]]; then
			echo "*******************************************************************************"
			echo "WARNING: More than one autorestart file was found. IBC can't determine which is"
			echo "         the right one, so they've all been deleted. Full authentication will"
			echo "         be required."
			echo
			echo "         If you have two or more TWS/Gateway instances with the same setting"
			echo "         for TWS_SETTINGS_PATH, you should ensure that they are configured with"
			echo "         different autorestart times, to avoid creation of multiple autorestart"
			echo "         files."
			echo "*******************************************************************************"
			echo
			restarted_needed=yes
		else
			echo "autorestart file not found"
			echo
			restarted_needed=
		fi
	else
		echo "AUTORESTART_OPTION is -Drestart=${autorestart_path}"
		autorestart_option=" -Drestart=${autorestart_path}"
		restarted_needed=yes
	fi
}

find_auto_restart


########################################
#                                      #
#               Main loop              #
#                                      #
########################################

run_ibg() {
	while :; do
		# forward signals (see https://veithen.github.io/2014/11/16/sigterm-propagation.html)
		trap 'kill -TERM $PID' TERM INT

		"$java_path/java" -cp "$ibc_classpath" $java_vm_options$autorestart_option $entry_point $ibc_ini ${mode} &

		PID=$!
		wait $PID
		trap - TERM INT
		wait $PID

		exit_code=$(($? % 256))
		echo "IBC returned exit status $exit_code"

		if [[ $exit_code -eq $E_LOGIN_DIALOG_DISPLAY_TIMEOUT ]]; then
			:
		elif [[ -e "${tws_settings_path}/COLDRESTART$ibc_session_id" ]]; then
			rm "${tws_settings_path}/COLDRESTART$ibc_session_id"
			autorestart_option=
			echo "IBC will cold-restart shortly"
		else
			find_auto_restart
			if [[ -n $restarted_needed ]]; then
				restarted_needed=
				# restart using the TWS/Gateway-generated autorestart file
				:
			elif [[ $exit_code -ne $E_2FA_DIALOG_TIMED_OUT  ]]; then
				break;
			elif [[ ${twofa_to_action_upper} != "RESTART" ]]; then
				break;
			fi
		fi

		# wait a few seconds before restarting
		echo "IBC will restart shortly"
		echo sleep 2
	done
}

# Global variable storing the xvfb display number
_current_xvfb_display_=

source "$l_dir/scripts/xvfb-functions.sh"

start_xvfb

# Set DISPLAY environment variable
export DISPLAY=":$_current_xvfb_display_"

echo "[DEBUG] DISPLAY was set to $DISPLAY"

# prevent other Java tools interfering with IBC
_JAVA_TOOL_OPTIONS=$JAVA_TOOL_OPTIONS
JAVA_TOOL_OPTIONS=

pushd "$tws_settings_path" > /dev/null

run_ibg

popd > /dev/null

JAVA_TOOL_OPTIONS=$_JAVA_TOOL_OPTIONS

stop_xvfb $_current_xvfb_display_

exit $exit_code