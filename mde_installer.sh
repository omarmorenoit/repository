#!/bin/bash
###
# Microsoft Defender for Endpoint installer for Linux for Accenture internal use
# based on https://github.com/microsoft/mdatp-xplat/blob/master/linux/installation/mde_installer.sh
# originaly published under MIT license
# ACN maintainer: petr.vyhnal@accenture.com
#
# Changelog
# 0.1 - Initial release, added custom configs and steps to original script
# 0.2 - AV Eicar test on demand only, other post-inst checks split to multiple functions,
#	Checks org_id association when existing installation is found. Tries to upgrade as well.
#	URL-list connecitivyt test set as hard pre-inst dep. Exits when FANOTIFY or systemd are not available.
#	Informational validation of sys requirements. Checks for other 'mdatp scan' cron jobs with warning if found.
# 0.3 - Make initial connectivity test mandatory, so exit if nc is not available.
#	Wait up to 3 minutes to get healthy status
#	Confirms if cron job was successfully created
# 0.4	Fixed cron job
# 0.5	Added logging of whole installation process
# 0.6	Removed 3rd party AV uninstallation routine; minor cleanup
# 0.7	Updated install_on_debian function to handle MS apt source and gpg keyring in more widely compatible and also secure manner
# 0.8	Base script updated to 0.4.2; added tag by default (ACNTAGS)
# 0.9	Do not exit when conflisting apps are foud. Just show warning and let server owner to action on that.
# 1.0	Removed acn_test_connectivity, made verify_connectivity soft test
# 1.1	improved tags
# 1.2   update tag handling
# 1.3   removed yum makecache
# 1.4   Changed diagnosticLevel to "required"
# 1.5   Improved Tag validation
# 1.6	Static tag only
# 1.7   Improved TAG updates, allows to force re-onboard using -o (requires onboarding script to be specified), added image mode switch, minor updates

# Accenture specific config variables
ACNSCRIPT_VERSION=1.7
ACNEXAMINE=
ACNMDESTATUS=
ACNORGID="b15dadbd-8dc4-4951-a6c4-c260f0067ee1"
ACNONBOARDING_SCRIPT=MicrosoftDefenderATPOnboardingLinuxServer.py
ACNCONFIG=mdatp_managed.json
ACNCRONSCAN="0 2 * * sat" # At 02:00 on Saturday.; more at https://crontab.guru/
ACNLOGFILE="mde-install.log"
ACNTAGS="GROUP package:acnstandard_20220314" #update when there is a new version of the IS MDE policy
ACNUPDATETAG=0
ACNREONBOARD=0

# Original script variables
SCRIPT_VERSION="0.4.2"
ASSUMEYES=-y
CHANNEL=prod
DISTRO=
DISTRO_FAMILY=
PKG_MGR=
INSTALL_MODE=
DEBUG=
VERBOSE=
MDE_VERSION_CMD="mdatp health --field app_version"
PMC_URL=https://packages.microsoft.com/config
SCALED_VERSION=
VERSION=
ONBOARDING_SCRIPT=
MIN_REQUIREMENTS=
SKIP_CONFLICTING_APPS=
PASSIVE_MODE=
MIN_CORES=2
MIN_MEM_MB=4096
MIN_DISK_SPACE_MB=1280
declare -a tags

# Error codes
SUCCESS=0
ERR_INTERNAL=1
ERR_INVALID_ARGUMENTS=2
ERR_INSUFFICIENT_PRIVILAGES=3
ERR_NO_INTERNET_CONNECTIVITY=4
ERR_CONFLICTING_APPS=5
ERR_UNSUPPORTED_DISTRO=10
ERR_UNSUPPORTED_VERSION=11
ERR_INSUFFICIENT_REQUIREMENTS=12
ERR_MDE_NOT_INSTALLED=20
ERR_INSTALLATION_FAILED=21
ERR_UNINSTALLATION_FAILED=22
ERR_FAILED_DEPENDENCY=23
ERR_FAILED_REPO_SETUP=24
ERR_INVALID_CHANNEL=25
ERR_ONBOARDING_NOT_FOUND=30
ERR_ONBOARDING_FAILED=31
ERR_TAG_NOT_SUPPORTED=40
ERR_PARAMETER_SET_FAILED=41

# Predefined values
export DEBIAN_FRONTEND=noninteractive


script_exit()
{
    if [ -z "$1" ]; then
        echo "[!] INTERNAL ERROR. script_exit requires an argument" >&2
        exit 1
    fi

    if [ "$INSTALL_MODE" != "m" ]; then
        print_state
    fi

    if [ "$2" = "0" ]; then
        echo "[v] $1"
    else
	    echo "[x] $1" >&2
    fi

    if [ -z "$2" ]; then
        exit 1
    else
        echo "[*] exiting ($2)"
	    exit $2
    fi
}

print_state()
{
    if [ -z $(which mdatp) ]; then
        echo "[S] MDE not installed."
    else
        echo "[S] MDE installed."
        echo "[S] Onboarded: $(mdatp health --field licensed)"
        echo "[S] Org ID: $(mdatp health --field org_id)"
        local CURRENTTAGS=$(mdatp health --field edr_device_tags)
        if [ "$CURRENTTAGS" = "[]" ]; then
          echo "[S] Device tags: No MDE Tag(s) defined"
        else
          echo "$CURRENTTAGS" | grep -c "key\":\"GROUP\",\"value\":\"" >/dev/null && echo "[S] Device tags: $CURRENTTAGS" || echo "[S] Device tags: Unable to get MDE Tag in expected format"
        fi
        echo "[S] Subsystem: $(mdatp health --field real_time_protection_subsystem)"
        echo "[S] Conflicting applications: $(mdatp health --field conflicting_applications)"
    fi
}

run_quietly()
{
    # run_quietly <command> <error_msg> [<error_code>]
    # use error_code for script_exit

    if [ $# -lt 2 ] || [ $# -gt 3 ]; then
        echo "[!] INTERNAL ERROR. run_quietly requires 2 or 3 arguments" >&2
        exit 1
    fi

    local out=$(eval $1 2>&1; echo "$?")
    local exit_code=$(echo "$out" | tail -n1)

    if [ -n "$VERBOSE" ]; then
        echo "$out"
    fi
    
    if [ "$exit_code" -ne 0 ]; then
        if [ -n $DEBUG ]; then             
            echo "command: $1"
            echo "output: $out"
            echo "exit_code: $exit_code"
        fi

        if [ $# -eq 2 ]; then
            echo $2 >&2
        else
            script_exit "$2" $3
        fi
    fi

    return $exit_code
}

retry_quietly()
{
    # retry_quietly <retries> <command> <error_msg> [<error_code>]
    # use error_code for script_exit
    
    if [ $# -lt 3 ] || [ $# -gt 4 ]; then
        echo "[!] INTERNAL ERROR. retry_quietly requires 3 or 4 arguments" >&2
        exit 1
    fi

    local exit_code=
    local retries=$1

    while [ $retries -gt 0 ]
    do

        if run_quietly "$2" "$3"; then
            exit_code=0
        else
            exit_code=1
        fi

        if [ $exit_code -ne 0 ]; then
            sleep 1
            ((retries--))
            echo "[r] $(($1-$retries))/$1"
        else
            retries=0
        fi
    done

    if [ $# -eq 4 ] && [ $exit_code -ne 0 ]; then
        script_exit $3 $4
    fi

    return $exit_code
}


detect_distro()
{
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
        VERSION=$VERSION_ID
        VERSION_NAME=$VERSION_CODENAME
    elif [ -f /etc/redhat-release ]; then
        if [ -f /etc/oracle-release ]; then
            DISTRO="ol"
        elif [[ $(grep -o -i "Red\ Hat" /etc/redhat-release) ]]; then
            DISTRO="rhel"
        elif [[ $(grep -o -i "Centos" /etc/redhat-release) ]]; then
            DISTRO="centos"
        fi
        VERSION=$(grep -o "release .*" /etc/redhat-release | cut -d ' ' -f2)
    else
        script_exit "unable to detect distro" $ERR_UNSUPPORTED_DISTRO
    fi

    if [ "$DISTRO" == "debian" ] || [ "$DISTRO" == "ubuntu" ]; then
        DISTRO_FAMILY="debian"
    elif [ "$DISTRO" == "rhel" ] || [ "$DISTRO" == "centos" ] || [ "$DISTRO" == "ol" ] || [ "$DISTRO" == "fedora" ] || [ "$DISTRO" == "amzn" ]; then
        DISTRO_FAMILY="fedora"
    elif [ "$DISTRO" == "sles" ] || [ "$DISTRO" == "sle-hpc" ] || [ "$DISTRO" == "sles_sap" ]; then
        DISTRO_FAMILY="sles"
    else
        script_exit "unsupported distro $DISTRO $VERSION" $ERR_UNSUPPORTED_DISTRO
    fi

    echo "[>] detected: $DISTRO $VERSION $VERSION_NAME ($DISTRO_FAMILY)"
}

verify_connectivity()
{
    if [ -z "$1" ]; then
        script_exit "Internal error. verify_connectivity require a parameter" $ERR_INTERNAL
    fi

    if which wget; then
        connect_command="wget -O - --quiet --no-verbose --timeout 2 https://cdn.x.cp.wd.microsoft.com/ping --no-check-certificate"
    elif which curl; then
        connect_command="curl --silent --connect-timeout 2 --insecure https://cdn.x.cp.wd.microsoft.com/ping"
    else
        echo "ERROR: Unable to find wget/curl commands. Skipping..."
        return 1
    fi

    local connected=
    local counter=3

    while [ $counter -gt 0 ]
    do
        connected=$($connect_command)

        if [[ "$connected" != "OK" ]]; then
            sleep 1
            ((counter--))
        else
            counter=0
        fi
    done

    echo "[final] connected=$connected"

    if [[ "$connected" != "OK" ]]; then
        echo "ERROR: internet connectivity needed for $1, but continuing anyway..."
        return 1
    fi
    echo "[v] connected"
}

verify_channel()
{
    if [ "$CHANNEL" != "prod" ] && [ "$CHANNEL" != "insiders-fast" ] && [ "$CHANNEL" != "insiders-slow" ]; then
        script_exit "Invalid channel: $CHANNEL. Please provide valid channel. Available channels are prod, insiders-fast, insiders-slow" $ERR_INVALID_CHANNEL
    fi
}

verify_privileges()
{
    if [ -z "$1" ]; then
        script_exit "Internal error. verify_privileges require a parameter" $ERR_INTERNAL
    fi

    if [ $(id -u) -ne 0 ]; then
        script_exit "root privileges required to perform $1 operation" $ERR_INSUFFICIENT_PRIVILAGES
    fi
}

verify_min_requirements()
{
    # echo "[>] verifying minimal reuirements: $MIN_CORES cores, $MIN_MEM_MB MB RAM, $MIN_DISK_SPACE_MB MB disk space"
    
    local cores=$(nproc --all)
    if [ $cores -lt $MIN_CORES ]; then
        script_exit "MDE requires $MIN_CORES cores or more to run, found $cores." $ERR_INSUFFICIENT_REQUIREMENTS
    fi

    local mem_mb=$(free -m | grep Mem | awk '{print $2}')
    if [ $mem_mb -lt $MIN_MEM_MB ]; then
        script_exit "MDE requires at least $MIN_MEM_MB MB of RAM to run, found $mem_mb MB." $ERR_INSUFFICIENT_REQUIREMENTS
    fi

    local disk_space_mb=$(df -m . | tail -1 | awk '{print $4}')
    if [ $disk_space_mb -lt $MIN_DISK_SPACE_MB ]; then
        script_exit "MDE requires at least $MIN_DISK_SPACE_MB MB of free disk space for installation. found $disk_space_mb MB." $ERR_INSUFFICIENT_REQUIREMENTS
    fi

    echo "[v] min_requirements met"
}

find_service()
{
    if [ -z "$1" ]; then
        script_exit "INTERNAL ERROR. find_service requires an argument" $ERR_INTERNAL
    fi

	lines=$(systemctl status $1 2>&1 | grep "Active: active" | wc -l)
	
    if [ $lines -eq 0 ]; then
		return 1
	fi

	return 0
}

verify_conflicting_applications()
{
    # echo "[>] identifying conflicting applications (fanotify mounts)"

    # find applications that are using fanotify
    local conflicting_apps=$(find /proc/*/fdinfo/ -type f -exec sh -c 'lines=$(cat {} | grep "fanotify mnt_id" | wc -l); if [ $lines -gt 0 ]; then cat $(dirname {})/../cmdline; fi;' \; 2>/dev/null | grep -v wdavdaemon)
    #'
    if [ ! -z $conflicting_apps ]; then
        echo "[x] WARNING: found conflicting applications: [$conflicting_apps], please disable this app to make sure MDE works properly."
    fi

    # find known security services
    # | Vendor      | Service       |
    # |-------------|---------------|
    # | CrowdStrike | falcon-sensor |
    # | CarbonBlack | cbsensor      |
    # | McAfee      | MFEcma        |
    # | Trend Micro | ds_agent      |
    # | Clam AV     | clamd@scan    | 
	# | Symantec    | sisamdagent   | 

    local conflicting_services=('ds_agent' 'falcon-sensor' 'cbsensor' 'MFEcma' 'clamd@scan' 'sisamdagent')
    for t in "${conflicting_services[@]}"
    do
        set -- $t
        # echo "[>] locating service: $1"
        if find_service $1; then
            echo "[x] WARNING: found conflicting service: [$1]. You should disable, mask or remove it in order to let MDE to work properly."
        fi
    done

    echo "[v] no conflicting applications found"
}

set_package_manager()
{
    if [ "$DISTRO_FAMILY" = "debian" ]; then
        PKG_MGR=apt
        PKG_MGR_INVOKER="apt $ASSUMEYES"
    elif [ "$DISTRO_FAMILY" = "fedora" ]; then
        PKG_MGR=yum
        PKG_MGR_INVOKER="yum $ASSUMEYES"
    elif [ "$DISTRO_FAMILY" = "sles" ]; then
        DISTRO="sles"
        PKG_MGR="zypper"
        PKG_MGR_INVOKER="zypper --non-interactive"
    else
        script_exit "unsupported distro", $ERR_UNSUPPORTED_DISTRO
    fi
}

check_if_pkg_is_installed()
{
    if [ -z "$1" ]; then
        script_exit "INTERNAL ERROR. check_if_pkg_is_installed requires an argument" $ERR_INTERNAL
    fi

    if [ "$PKG_MGR" = "apt" ]; then
        dpkg -s $1 2> /dev/null | grep Status | grep "install ok installed" 1> /dev/null
    else
        rpm --quiet --query $1
    fi

    return $?
}

install_required_pkgs()
{
    local packages=
    local pkgs_to_be_installed=

    if [ -z "$1" ]; then
        script_exit "INTERNAL ERROR. install_required_pkgs requires an argument" $ERR_INTERNAL
    fi

    packages=("$@")
    for pkg in "${packages[@]}"
    do
        if  ! check_if_pkg_is_installed $pkg; then
            pkgs_to_be_installed="$pkgs_to_be_installed $pkg"
        fi
    done

    if [ ! -z "$pkgs_to_be_installed" ]; then
        echo "[>] installing $pkgs_to_be_installed"
        run_quietly "$PKG_MGR_INVOKER install $pkgs_to_be_installed" "Unable to install the required packages ($?)" $ERR_FAILED_DEPENDENCY 
    else
        echo "[v] required pkgs are installed"
    fi
}

wait_for_package_manager_to_complete()
{
    local lines=
    local counter=120

    while [ $counter -gt 0 ]
    do
        lines=$(ps axo pid,comm | grep "$PKG_MGR" | grep -v grep -c)
        if [ "$lines" -eq 0 ]; then
            echo "[>] package manager freed, resuming installation"
            return
        fi
        sleep 1
        ((counter--))
    done

    echo "[!] pkg_mgr blocked"
}

install_on_debian()
{
    local packages=
    local pkg_version=
    local success=

    if check_if_pkg_is_installed mdatp; then
        pkg_version=$($MDE_VERSION_CMD) || script_exit "unable to fetch the app version. please upgrade to latest version $?" $ERR_INTERNAL
        echo "[i] MDE already installed ($pkg_version)"
        if acn_verify_mdatp_orgid; then
          echo "Trying to upgrade..."
          $PKG_MGR_INVOKER install --only-upgrade mdatp || script_exit "Unable to upgrade MDE" $ERR_INTERNAL
          script_exit "Finished successfully." $SUCCESS
        else
          script_exit "Error: MDE installation found, but it's associated to different organization!" $ERR_INTERNAL
        fi


        return
    fi

    packages=(curl apt-transport-https gnupg sudo)

    install_required_pkgs ${packages[@]}

    ### Configure the repository ###
    echo -n "Adding MDATP repository: "
    rm -f microsoft.list > /dev/null
    run_quietly "curl -s -o microsoft.list $PMC_URL/$DISTRO/$SCALED_VERSION/$CHANNEL.list" "unable to fetch repo list" $ERR_FAILED_REPO_SETUP
    echo "OK"
    # make gpg handled more securely (see https://wiki.debian.org/DebianRepository/UseThirdParty)
    echo -n "Securing MDATP repository: "
    sed -i 's/\[arch=/\[signed-by=\/usr\/share\/keyrings\/microsoft-archive-keyring.gpg arch=/' microsoft.list || script_exit "Unable to modify apt source list." $ERR_INTERNAL
    run_quietly "mv ./microsoft.list /etc/apt/sources.list.d/microsoft-$CHANNEL.list" "unable to copy repo to location" $ERR_FAILED_REPO_SETUP
    echo "OK"

    ### Fetch the gpg key ###
    # create keyrings directory if not exists
    if [ ! -d /usr/share/keyrings ]; then
      mkdir -p /usr/share/keyrings || script_exit "Unable to create directory for GPG keyring" $ERR_INTERNAL
    fi
    echo -n "Adding MDATP repository GPG keyring: "
    curl -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /usr/share/keyrings/microsoft-archive-keyring.gpg || script_exit "Unable to fetch the gpg key" $ERR_FAILED_REPO_SETUP
    echo "OK"
    run_quietly "apt-get update" "[!] unable to refresh the repos properly"

    ### Install MDE ###
    echo "[>] installing MDE"
    if [ "$CHANNEL" = "prod" ]; then
        if [[ -z "$VERSION_NAME" ]]; then
            run_quietly "$PKG_MGR_INVOKER install mdatp" "unable to install MDE ($?)" $ERR_INSTALLATION_FAILED
        else
            run_quietly "$PKG_MGR_INVOKER -t $VERSION_NAME install mdatp" "unable to install MDE ($?)" $ERR_INSTALLATION_FAILED
        fi
    else
        run_quietly "$PKG_MGR_INVOKER -t $CHANNEL install mdatp" "unable to install MDE ($?)" $ERR_INSTALLATION_FAILED
    fi

    sleep 5
    echo "[v] installed"
}

install_on_fedora()
{
    local packages=
    local pkg_version=
    local repo=
    local effective_distro=

    if check_if_pkg_is_installed mdatp; then
        pkg_version=$($MDE_VERSION_CMD) || script_exit "Unable to fetch the app version. Please upgrade to latest version $?" $ERR_INSTALLATION_FAILED
        echo "[i] MDE already installed ($pkg_version)"
        if acn_verify_mdatp_orgid; then
          echo "Trying to upgrade..."
          $PKG_MGR_INVOKER update mdatp || script_exit "Unable to upgrade MDE" $ERR_INTERNAL
          script_exit "Finished successfully." $SUCCESS
        else
          script_exit "Error: MDE installation found, but it's associated to different organization!" $ERR_INTERNAL
        fi
        return
    fi

    repo=packages-microsoft-com
    packages=(curl yum-utils)

    if [[ $SCALED_VERSION == 7* ]] && [ "$DISTRO" == "rhel" ]; then
        packages=($packages deltarpm)
    fi

    install_required_pkgs ${packages[@]}

    ### Configure the repo name from which package should be installed
    if [[ $SCALED_VERSION == 7* ]] && [[ "$CHANNEL" != "prod" ]]; then
        repo=packages-microsoft-com-prod
    fi

    if [ "$DISTRO" == "ol" ] || [ "$DISTRO" == "fedora" ] || [ "$DISTRO" == "amzn" ]; then
        effective_distro="rhel"
    else
        effective_distro="$DISTRO"
    fi

    ### Configure the repository ###
    run_quietly "yum-config-manager --add-repo=$PMC_URL/$effective_distro/$SCALED_VERSION/$CHANNEL.repo" "Unable to fetch the repo ($?)" $ERR_FAILED_REPO_SETUP

    ### Fetch the gpg key ###
    run_quietly "curl https://packages.microsoft.com/keys/microsoft.asc > microsoft.asc" "unable to fetch gpg key $?" $ERR_FAILED_REPO_SETUP
    run_quietly "rpm --import microsoft.asc" "unable to import gpg key" $ERR_FAILED_REPO_SETUP
    #run_quietly "yum makecache" " Unable to refresh the repos properly. Command exited with status ($?)"

    ### Install MDE ###
    echo "[>] installing MDE"
    run_quietly "$PKG_MGR_INVOKER --enablerepo=$repo-$CHANNEL install mdatp" "unable to install MDE ($?)" $ERR_INSTALLATION_FAILED
    
    sleep 5
    echo "[v] installed"
}

install_on_sles()
{
    local packages=
    local pkg_version=
    local repo=

    if check_if_pkg_is_installed mdatp; then
        pkg_version=$($MDE_VERSION_CMD) || script_exit "unable to fetch the app version. please upgrade to latest version $?" $ERR_INTERNAL
        echo "[i] MDE already installed ($pkg_version)"
        if acn_verify_mdatp_orgid; then
          echo "Trying to upgrade..."
          $PKG_MGR_INVOKER update mdatp || script_exit "Unable to upgrade MDE" $ERR_INTERNAL
          script_exit "Finished successfully." $SUCCESS
        else
          script_exit "Error: MDE installation found, but it's associated to different organization!" $ERR_INTERNAL
        fi
        return
    fi

    repo=packages-microsoft-com
    packages=(curl)

    install_required_pkgs ${packages[@]}

    wait_for_package_manager_to_complete

    ### Configure the repository ###
    run_quietly "$PKG_MGR_INVOKER addrepo -c -f -n microsoft-$CHANNEL https://packages.microsoft.com/config/$DISTRO/$SCALED_VERSION/$CHANNEL.repo" "unable to load repo" $ERR_FAILED_REPO_SETUP

    ### Fetch the gpg key ###
    run_quietly "rpm --import https://packages.microsoft.com/keys/microsoft.asc > microsoft.asc" "unable to fetch gpg key $?" $ERR_FAILED_REPO_SETUP
    
    wait_for_package_manager_to_complete

    ### Install MDE ###
    echo "[>] installing MDE"

    run_quietly "$PKG_MGR_INVOKER install $ASSUMEYES $repo-$CHANNEL:mdatp" "[!] failed to install MDE (1/2)"
    
    if ! check_if_pkg_is_installed mdatp; then
        echo "[r] retrying"
        sleep 2
        run_quietly "$PKG_MGR_INVOKER install $ASSUMEYES mdatp" "unable to install MDE 2/2 ($?)" $ERR_INSTALLATION_FAILED
    fi

    sleep 5
    echo "[v] installed."
}

remove_repo()
{
    # TODO: add support for debian and fedora
    if [ $DISTRO == 'sles' ] || [ "$DISTRO" = "sle-hpc" ]; then
        run_quietly "$PKG_MGR_INVOKER removerepo packages-microsoft-com-$CHANNEL" "failed to remove repo"
    else
        script_exit "unsupported distro for remove repo $DISTRO" $ERR_UNSUPPORTED_DISTRO
    fi
}

upgrade_mdatp()
{
    if [ -z "$1" ]; then
        script_exit "INTERNAL ERROR. upgrade_mdatp requires an argument (the upgrade command)" $ERR_INTERNAL
    fi

    if ! check_if_pkg_is_installed mdatp; then
        script_exit "MDE package is not installed. Please install it first" $ERR_MDE_NOT_INSTALLED
    fi

    run_quietly "$PKG_MGR_INVOKER $1 mdatp" "Unable to upgrade MDE $?" $ERR_INSTALLATION_FAILED
    echo "[v] upgraded"
}

remove_mdatp()
{
    if ! check_if_pkg_is_installed mdatp; then
        script_exit "MDE package is not installed. Please install it first"
    fi

    run_quietly "$PKG_MGR_INVOKER remove mdatp" "unable to remove MDE $?" $ERR_UNINSTALLATION_FAILED
    script_exit "[v] removed" $SUCCESS
}

scale_version_id()
{
    ### We dont have pmc repos for rhel versions > 7.4. Generalizing all the 7* repos to 7 and 8* repos to 8
    if [ "$DISTRO_FAMILY" == "fedora" ]; then
        if [[ $VERSION == 7* ]] || [ "$DISTRO" == "amzn" ]; then
            SCALED_VERSION=7
        elif [[ $VERSION == 8* ]] || [ "$DISTRO" == "fedora" ]; then
            SCALED_VERSION=8
        else
            script_exit "unsupported version: $DISTRO $VERSION" $ERR_UNSUPPORTED_VERSION
        fi
    elif [ "$DISTRO_FAMILY" == "sles" ]; then
        if [[ $VERSION == 12* ]]; then
            SCALED_VERSION=12
        elif [[ $VERSION == 15* ]]; then
            SCALED_VERSION=15
        else
            script_exit "unsupported version: $DISTRO $VERSION" $ERR_UNSUPPORTED_VERSION
        fi
    elif [ $DISTRO == "ubuntu" ] && [[ $VERSION != "16.04" ]] && [[ $VERSION != "18.04" ]] && [[ $VERSION != "20.04" ]]; then
        SCALED_VERSION=18.04
    else
        # no problems with 
        SCALED_VERSION=$VERSION
    fi
    echo "[>] scaled: $SCALED_VERSION"
}

onboard_device()
{
    echo "[>] onboarding script: $ONBOARDING_SCRIPT"

    if ! check_if_pkg_is_installed mdatp; then
        script_exit "MDE package is not installed. Please install it first" $ERR_MDE_NOT_INSTALLED
    fi

    if [ ! -f $ONBOARDING_SCRIPT ]; then
        script_exit "error: onboarding script not found." $ERR_ONBOARDING_NOT_FOUND
    fi

    # Make sure python is installed
    PYTHON=$(which python || which python3)

    if [ -z $PYTHON ]; then
      # Try harder, 'which' sometimes does work as expected (on SLES)
      PYTHON2=`command -v python2`
      PYTHON3=`command -v python3`
      if [ -n "$PYTHON2" ]; then
        PYTHON=$PYTHON2
      elif [ -n "$PYTHON3" ]; then
        PYTHON=$PYTHON3
      else
        script_exit "error: cound not locate python." $ERR_FAILED_DEPENDENCY
      fi
    fi

    # Run onboarding script
    # echo "[>] running onboarding script..."
    sleep 1
    run_quietly "$PYTHON $ONBOARDING_SCRIPT" "error: onboarding failed" $ERR_ONBOARDING_FAILED

    # validate onboarding
    sleep 3
    if [[ $(mdatp health --field org_id | grep "No license found" -c) -gt 0 ]]; then
        script_exit "onboarding failed" $ERR_ONBOARDING_FAILED
    fi
    echo "[>] onboarded"
}

set_epp_to_passive_mode()
{
    # echo "[>] setting MDE/EPP to passive mode"

    if ! check_if_pkg_is_installed mdatp; then
        script_exit "MDE package is not installed. Please install it first" $ERR_MDE_NOT_INSTALLED
    fi

    retry_quietly 3 "mdatp config passive-mode --value enabled" "failed to set MDE to passive-mode" $ERR_PARAMETER_SET_FAILED
    echo "[v] passive mode set"
}

set_device_tags()
{
    for t in "${tags[@]}"
    do
        set -- $t
        if [ "$1" == "GROUP" ] || [ "$1" == "SecurityWorkspaceId" ] || [ "$1" == "AzureResourceId" ] || [ "$1" == "SecurityAgentId" ]; then
            # echo "[>] setting tag: ($1, $2)"
            retry_quietly 2 "mdatp edr tag set --name $1 --value \"$2\"" "failed to set tag" $ERR_PARAMETER_SET_FAILED
        else
            script_exit "invalid tag name: $1. supported tags: GROUP, SecurityWorkspaceId, AzureResourceId and SecurityAgentId" $ERR_TAG_NOT_SUPPORTED
        fi
    done
    echo "[v] tags set."  
}

usage()
{
    echo "mde_installer.sh v$ACNSCRIPT_VERSION"
    echo "usage: $1 [OPTIONS]"
    echo "Options:"
    echo " -i|--install         install the product (Implies -o -e and -t with default values)"
    echo " -r|--remove          remove the product"
    echo " -e|--examine         test product functionality and connectivity to MS endpoints (Implicit for install task but excluding the detection test)"
    echo " -u|--upgrade         upgrade the existing product to a newer version if available"
    echo " -o|--onboard         onboard/offboard the product with <onboarding_script> (Default: MicrosoftDefenderATPOnboardingLinuxServer.py)"
    echo " -t|--tag             set a tag by declaring <name> and <value> ex: -t GROUP Coders (Default: GROUP noncmo_acnstandard_202110)"
    echo " -x|--skip_conflict   skip conflicting application verification"
    echo " -g|--imagemode       installs mdatp without onboarding; to be used for an image creation"
#    echo " -w|--clean           remove repo from package manager for a specific channel"
#    echo " -s|--verbose         verbose output"
    echo " -v|--version         print out script version"
    echo " -d|--debug           set debug mode"
#    echo " --proxy <proxy URL>  set proxy"   
    echo " -h|--help            display help"
}

#"

acn_check_audit()
{
  # SLES has disabled syscalls by default, let's enable them
  if grep "^-a task,never$" /etc/audit/rules.d/audit.rules >/dev/null; then
    echo "Info: AuditD syscalls auditing disabled. Enabling..."
    cat /etc/audit/rules.d/audit.rules > /etc/audit/rules.d/audit.rules-premdatp
    sed 's/^-a task,never$/# disabled as part of MDE installation\n#-a task,never/' /etc/audit/rules.d/audit.rules-premdatp > /etc/audit/rules.d/audit.rules
    if auditctl -s | grep "enabled 2" >/dev/null; then
      echo "Warning: AuditD uses rules locking. Reboot is required to apply changes. Please make sure '-e 2' rule is the very last one!"
    else
      echo "Reloading AuditD rules..."
      augenrules --load
    fi
  fi
}

acn_check_fanotify()
{
  echo -n "Checking if Fanotify is enabled: "
  # we need to check configuration of current runing kernel
  if egrep "CONFIG_FANOTIFY=y|CONFIG_FANOTIFY=m" /boot/config-$(uname -r)>/dev/null; then
    echo "OK"
  else
    script_exit "Error: Fanotify seems to be disabled. Please install kernel with enabled CONFIG_FANOTIFY first."
  fi
}

acn_custom_config()
{
  unalias cp 2>/dev/null
  echo -n "Deploying Accenture custom config: "
  cp -f $ACNCONFIG /etc/opt/microsoft/mdatp/managed/
  if [ $? -eq 0 ]; then
    echo "OK"
  else
    echo "Failed"
    error_code=13
  fi
}

acn_check_systemd()
{
  echo -n "Checking systemd init: "
  # some distros like Ubuntu 17 masks systemd as init, thus we need to check process exe link to be absolutely sure
  if readlink /proc/1/exe | grep systemd >/dev/null; then
    echo "OK"
  else
    script_exit "Error: Server is not using systemd as init system."
  fi
}

acn_check_mdatp_status()
{
  echo -n "Checking if MDE is enabled to start at boot: "
  if systemctl is-enabled mdatp >/dev/null; then
    echo "Enabled"
  else
    echo "Disabled - Enabling..."
    systemctl enable mdatp
  fi

  echo -n "Checking if MDE is up and running: "
  if systemctl is-active mdatp >/dev/null; then
    echo "OK"
    ACNMDESTATUS=1
  else
    echo "Failed - Restarting..."
    systemctl restart mdatp
    if [ $? -ne 0 ]; then
      echo "Error: Restart failed"
      error_code=12
    fi
  fi

}

acn_schedule_scans()
{
  if [ "$1" == "i" ] || [ "$1" == "m" ]; then
    echo
    echo -n "Adding cron script for periodic scans..."
    echo -e "# Run MDE scans every Saturday\nSHELL=/bin/bash\nPATH=/sbin:/bin:/usr/sbin:/usr/bin\n$ACNCRONSCAN root /usr/bin/mdatp scan full > /var/log/mdatp_cron_job.log" > /etc/cron.d/mdatp-scan
    if [ $? -ne 0 ]; then
      echo "Failed. Please check existence and content of /etc/cron.d/mdatp-scan"
    else
      echo "OK"
    fi
  else
    if [ -f /etc/cron.d/mdatp-scan ]; then
      echo "Existing cron script found. No action needed."
#      echo "Existing cron script found. Setting to default..."
#      echo -e "# Run MDE scans every Saturday\nSHELL=/bin/bash\nPATH=/sbin:/bin:/usr/sbin:/usr/bin\n$ACNCRONSCAN root /usr/bin/mdatp scan full > /var/log/mdatp_cron_job.log" > /etc/cron.d/mdatp-scan
    else
      echo "Cron script not found. Adding cron script for periodic scans..."
      echo -e "# Run MDE scans every Saturday\nSHELL=/bin/bash\nPATH=/sbin:/bin:/usr/sbin:/usr/bin\n$ACNCRONSCAN root /usr/bin/mdatp scan full > /var/log/mdatp_cron_job.log" > /etc/cron.d/mdatp-scan
      if [ $? -ne 0 ]; then
        echo "Failed. Please check existence and content of /etc/cron.d/mdatp-scan"
      else
        echo "OK"
      fi
    fi
  fi
  OTHERJOBS=`grep -R "mdatp scan" /etc/cron.* /var/spool/cron/* | grep -v /etc/cron.d/mdatp-scan`
  if [ -n "$OTHERJOBS" ]; then
    echo "Warning: following non-default AV scan cron jobs found:"
    echo "$OTHERJOBS"
    echo "For optimal performance please make sure they do not overlap each other."
    echo
  fi
}

acn_verify_mdatp_health()
{
  echo -n "Waiting for MDE to initialize: "
  local COUNTER=0
  MDEHEALTH=1
  # let's wait 3 minutes to allow MDE to download antivirus definitions to report as healthy
  while [ $COUNTER -lt 180 ]; do
    if mdatp health --field healthy | grep -c true >/dev/null; then
      COUNTER=180
      MDEHEALTH=0
    else
      ((COUNTER++))
      echo -n "."
      sleep 1s
    fi
  done
  if [ $MDEHEALTH -eq 0 ]; then
    echo "healthy"
  else
    echo "not healthy or timed out"
  fi
}

acn_verify_mdatp_connectivity()
{
  echo "Testing connectivity:"
  if mdatp connectivity test; then
    echo "All connectivity: OK"
    MDECONN=0
  else
    echo "Warning: There are connectivity issues"
    MDECONN=1
  fi
}

acn_verify_mdatp_orgid()
{
  local MDATPORG=`mdatp health --field org_id | tail -n1 | sed 's/"//g'`
  MDEORGOK=
  if [ "$MDATPORG" == "$ACNORGID" ]; then
    echo "MDE org_id association: OK"
    MDEORGOK=0
  else
    echo "MDE org_id association: Error - Associated with unknown org_id $MDATPORG"
    MDEORGOK=1
  fi
  return $MDEORGOK
}

acn_test_mdatp_detection()
{
  if mdatp health --field healthy 2>&1 1>/dev/null; then
    echo -n "Testing AV detection: "
    # Eicar is well known AV/Malware test file. It causes no harm, but every AV should be able to detect it.
    curl -s -o /tmp/eicar.com.txt https://www.eicar.org/download/eicar.com.txt
    sleep 5s
    if mdatp threat list | grep /tmp/eicar.com.txt >/dev/null; then
      echo "OK"
    else
      echo "Failed"
    fi
  else
    echo "Skipping AV test, because MDATP is not healthy."
  fi
}

acn_verify_min_requirements()
{
    # Minimal requirements are not enforced, but just informational
    echo "Verifying minimal requirements: $MIN_CORES cores, $MIN_MEM_MB MB RAM, $MIN_DISK_SPACE_MB MB disk space"

    local CORES=$(nproc --all)
    if [ $CORES -lt $MIN_CORES ]; then
        echo "Warning: MDE requires $MIN_CORES cores or more to run, found $CORES."
    fi

    local MEM_MB=$(free -m | grep Mem | awk '{print $2}')
    if [ $MEM_MB -lt $MIN_MEM_MB ]; then
        echo "Warning: MDE requires at least $MIN_MEM_MB MB of RAM to run, found $MEM_MB MB."
    fi

    local DISK_SPACE_MB=$(df -m . | tail -1 | awk '{print $4}')
    if [ $DISK_SPACE_MB -lt $MIN_DISK_SPACE_MB ]; then
        echo "Warning: MDE requires at least $MIN_DISK_SPACE_MB MB of free disk space for installation"
    fi
}

acn_get_oldtags(){
  CACNTAGS="GROUP $(mdatp health --field edr_device_tags | sed -r 's/.*key\":\"GROUP\",\"value\":\"(package:[a-zA-Z0-9_\-]*).*/\1/')"
  if [ ${#CACNTAGS} -ge 10 ]; then
    echo "Current tag is: $CACNTAGS"
    ACNTAGS="$CACNTAGS"
  else
#    script_exit "Error: Unable to get current tags" 50
    echo "Unable to find current tag or it's in unknown format. Script will generate a new one."
  fi

}

acn_get_cloudid(){

AWSTOKEN=`curl -f -s --connect-timeout 5 -x "" -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 120"`
if [ $? -eq 0 ]; then
  AWSCLID=`curl -f -s --connect-timeout 5 -x "" -H "X-aws-ec2-metadata-token: $AWSTOKEN" http://169.254.169.254/latest/meta-data/instance-id`
fi
AZCLID=`curl -f -s --connect-timeout 5 -x "" -H Metadata:true "http://169.254.169.254/metadata/instance/compute/vmId?api-version=2018-10-01&format=text"`
GCPCLID=`curl -f -s --connect-timeout 5 -x "" -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/id"`

if [ -n "$AWSCLID" ]; then
  ACNTAGS="$ACNTAGS;clid:$AWSCLID"
elif [ -n "$AZCLID" ]; then
  ACNTAGS="$ACNTAGS;clid:$AZCLID"
elif [ -n "$GCPCLID" ]; then
  ACNTAGS="$ACNTAGS;clid:$GCPCLID"
else
  ACNTAGS="$ACNTAGS"
fi
}


if [ $# -eq 0 ]; then
    usage
    script_exit "no arguments were provided. specify --help for details" $ERR_INVALID_ARGUMENTS
fi

while [ $# -ne 0 ];
do
    case "$1" in
        -c|--channel)
            if [ -z "$2" ]; then
                script_exit "$1 option requires an argument" $ERR_INVALID_ARGUMENTS
            fi        
            CHANNEL=$2
            verify_channel
            shift 2
            ;;
        -i|--install)
            INSTALL_MODE="i"
            verify_privileges "install"
            shift 1
            ;;
        -u|--upgrade|--update)
            INSTALL_MODE="u"
            verify_privileges "upgrade"
            shift 1
            ;;
        -r|--remove)
            INSTALL_MODE="r"
            verify_privileges "remove"
            shift 1
            ;;
        -e|--examine)
            ACNEXAMINE=1
            shift 1
            ;;
        -o|--onboard)
            if [ -z "$2" ]; then
                script_exit "$1 option requires an argument" $ERR_INVALID_ARGUMENTS
            fi        
            ONBOARDING_SCRIPT=$2
            ACNREONBOARD=1
            verify_privileges "onboard"
            shift 2
            ;;
        -m|--min_req)
            MIN_REQUIREMENTS=1
            shift 1
            ;;
        -x|--skip_conflict)
            SKIP_CONFLICTING_APPS=1
            shift 1
            ;;
        -p|--passive-mode)
            verify_privileges "passive-mode"
            PASSIVE_MODE=1
            shift 1
            ;;
        -t|--tag)
            verify_privileges "set-tag"
            ACNUPDATETAG=1
            shift 1
            ;;
        -w|--clean)
            INSTALL_MODE='c'
            verify_privileges "clean"
            shift 1
            ;;
        -h|--help)
            usage "basename $0" >&2
            exit 0
            ;;
        -y|--yes)
            ASSUMEYES=-y
            shift 1
            ;;
        -g|--imagemode)
            INSTALL_MODE='m'
            shift 1
            ;;
        -s|--verbose)
            VERBOSE=1
            shift 1
            ;;
        -v|--version)
            script_exit "$ACNSCRIPT_VERSION" $SUCCESS
            ;;
        -d|--debug)
            DEBUG=1
            shift 1
            ;;
        --proxy)
            if [[ -z "$2" ]]; then
                script_exit "$1 option requires two arguments" $ERR_INVALID_ARGUMENTS
            fi
            export http_proxy=$2
            export https_proxy=$2
            shift 2
            ;;
        *)
            echo "use -h or --help for details"
            script_exit "unknown argument" $ERR_INVALID_ARGUMENTS
            ;;
    esac
done

if [[ -z "${INSTALL_MODE}" && -z "${ONBOARDING_SCRIPT}" && -z "${PASSIVE_MODE}" && -z "${ACNUPDATETAG}" && -z "${ACNEXAMINE}" ]]; then
    script_exit "No installation mode specified. Specify --help for help" $ERR_INVALID_ARGUMENTS
fi

echo "--- mde_installer.sh v$ACNSCRIPT_VERSION ---"

# initialize log file first
echo "Installer started at $(date --rfc-3339=seconds)" > $ACNLOGFILE

{
# run some preflight checks if in install mode, exit if one fails
if [ "$INSTALL_MODE" == "i" ] || [ "$INSTALL_MODE" == "m" ]; then
  acn_check_fanotify
  acn_check_systemd
fi

# Accenture customized requirements check
acn_verify_min_requirements

### Detect the distro and version number ###
detect_distro

### Scale the version number according to repos avaiable on pmc ###
scale_version_id

### Set package manager ###
set_package_manager

# Check AuditD settings
acn_check_audit

### Act according to arguments ###
if [ "$INSTALL_MODE" == "i" ]; then

    # Ensure server gets onboarded during installation
    if [ ! $ONBOARDING_SCRIPT ]; then
      ONBOARDING_SCRIPT=$ACNONBOARDING_SCRIPT
    fi

    verify_connectivity "package installation"

    if [ "$DISTRO_FAMILY" == "debian" ]; then
        install_on_debian
    elif [ "$DISTRO_FAMILY" == "fedora" ]; then
        install_on_fedora
    elif [ "$DISTRO_FAMILY" = "sles" ]; then
        install_on_sles
    else
        script_exit "unsupported distro $DISTRO $VERSION" $ERR_UNSUPPORTED_DISTRO
    fi
    if [ ! -z $ONBOARDING_SCRIPT ]; then
      acn_custom_config
      onboard_device
    fi
    acn_get_cloudid
    tags=("$ACNTAGS")

elif [ "$INSTALL_MODE" == "u" ]; then
    verify_connectivity "package update"

    if [ "$DISTRO_FAMILY" == "debian" ]; then
        upgrade_mdatp "$ASSUMEYES install --only-upgrade"
    elif [ "$DISTRO_FAMILY" == "fedora" ]; then
        upgrade_mdatp "$ASSUMEYES update"
    elif [ "$DISTRO_FAMILY" == "sles" ]; then
        upgrade_mdatp "up $ASSUMEYES"
    else
        script_exit "unsupported distro $DISTRO $VERSION" $ERR_UNSUPPORTED_DISTRO
    fi
    acn_custom_config

elif [ "$INSTALL_MODE" = "r" ]; then
    if [ ! -z $ONBOARDING_SCRIPT ]; then
      onboard_device
    fi
    remove_mdatp

elif [ "$INSTALL_MODE" == "c" ]; then
    remove_repo

elif [ "$INSTALL_MODE" == "m" ]; then
    verify_connectivity "package installation"

    if [ "$DISTRO_FAMILY" == "debian" ]; then
        install_on_debian
    elif [ "$DISTRO_FAMILY" == "fedora" ]; then
        install_on_fedora
    elif [ "$DISTRO_FAMILY" = "sles" ]; then
        install_on_sles
    else
        script_exit "unsupported distro $DISTRO $VERSION" $ERR_UNSUPPORTED_DISTRO
    fi
    acn_custom_config
    acn_schedule_scans $INSTALL_MODE
    script_exit "--- mde_installer.sh ended. (image mode) ---" $SUCCESS
elif [ $ACNREONBOARD -eq 1 ]; then
  onboard_device
fi

# finally check MDE status and ensure scans are configured
if [ "$INSTALL_MODE" == "i" ] || [ "$INSTALL_MODE" == "u" ]; then
    acn_check_mdatp_status
    acn_schedule_scans $INSTALL_MODE
    acn_verify_mdatp_health
    acn_verify_mdatp_connectivity
    acn_verify_mdatp_orgid
fi

# Test health status, connectivity and detection if --examine option was issued
if [ $ACNEXAMINE ]; then
    if check_if_pkg_is_installed mdatp; then
      if [ ! $MDEHEALTH ]; then
        acn_verify_mdatp_health
      fi
      if [ ! $MDECONN ]; then
        acn_verify_mdatp_connectivity
      fi
      if [ ! $MDEORGOK ]; then
        acn_verify_mdatp_orgid
      fi
      acn_test_mdatp_detection
    else
      script_exit "MDE is not installed."
    fi
fi

# Set tag at the end of the installation process, so MDATP is likely in healthy state already
if [ ${#tags[@]} -gt 0 ]; then
    set_device_tags
elif [ $ACNUPDATETAG -eq 1 ]; then
  acn_get_oldtags
  acn_get_cloudid
  tags=("$ACNTAGS")
  set_device_tags
fi

if [ -z $SKIP_CONFLICTING_APPS ] && [ "$INSTALL_MODE" == "i" ]; then
  verify_conflicting_applications
fi


script_exit "--- mde_installer.sh ended. ---" $SUCCESS
} 2>&1 | tee -a $ACNLOGFILE