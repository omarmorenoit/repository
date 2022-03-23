#!/bin/bash
ONBOARDING_SCRIPT="MicrosoftDefenderATPOnboardingLinuxServer.py"

script_exit()
{
    if [ -z "$1" ]; then
        echo "[!] INTERNAL ERROR. script_exit requires an argument" >&2
        exit 1
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


update_guid() {
  ETIME=`date +%s`
  OLDGUID=`sed -r 's/.*machineGuid\":(\"[a-z0-9-]*\"|null).*/\1/' /var/opt/microsoft/mdatp/wdavstate | tr -d \"`
  NEWGUID=`cat /sys/class/dmi/id/product_uuid | tr '[:upper:]' '[:lower:]'`
  if [ -n $OLDGUID ]; then
    echo "Found old GUID: $OLDGUID"
  else
    script_exit "FAILED: Unable to read old GUID"
  fi

  if [ -n $NEWGUID ]; then
    echo "Found new GUID: $NEWGUID"
  else
    script_exit "FAILED: Unable to read new GUID"
  fi

  [ "$NEWGUID" == "$OLDGUID" ] && script_exit "Old and new GUID matches. No action needed" 0

  echo "Updating GUID"
  sed -r -i-$ETIME "s/machineGuid\":(\"[a-z0-9-]*\"|null)/machineGuid\":\"$NEWGUID\"/" /var/opt/microsoft/mdatp/wdavstate || script_exit "ERROR: Unable to update GUID in MDATP config"

  echo "Restarting mdatp..."
  systemctl restart mdatp

  echo "Re-onboarding machine"
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
#      script_exit "error: cound not locate python." $ERR_FAILED_DEPENDENCY
      script_exit "ERROR: cound not locate python."
    fi
  fi

  # Run onboarding script
  # echo "[>] running onboarding script..."
  sleep 1
  $PYTHON $ONBOARDING_SCRIPT
  # validate onboarding
  sleep 3
  if [[ $(mdatp health --field org_id | grep "No license found" -c) -gt 0 ]]; then
#    script_exit "onboarding failed" $ERR_ONBOARDING_FAILED
    script_exit "onboarding failed"
  fi
  echo "[>] onboarded"

}

[ -f $ONBOARDING_SCRIPT ] || script_exit "FATAL: onboarding script is missing"

update_guid