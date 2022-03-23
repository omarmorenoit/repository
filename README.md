# Introduction 
This is installation package for MDATP/MDE Linux agent.

# Available options
<table>
<tr><td>-i|--install</td><td>install the product (Implies -o -e and -t with default values)</td></tr>
<tr><td>-g|--imagemode</td><td>install the product, but without onboarding and tagging to allow to prepare packages</td></tr>
<tr><td>-r|--remove</td><td>remove the product</td></tr>
<tr><td>-e|--examine</td><td>test product functionality and connectivity to MS endpoints (Implicit for install task but excluding the detection test)</td></tr>
<tr><td>-u|--upgrade</td><td>upgrade the existing product to a newer version if available</td></tr>
<tr><td>-o|--onboard</td><td>onboard/offboard the product with <onboarding_script> (Default: MicrosoftDefenderATPOnboardingLinuxServer.py)</td></tr>
<tr><td>-t|--tag</td><td>set the MDE tag</td></tr>
<tr><td>-x|--skip_conflict</td><td>skip conflicting application verification</td></tr>
<tr><td>-v|--version</td><td>print out script version</td></tr>
<tr><td>-d|--debug</td><td>set debug mode</td></tr>
<tr><td>-h|--help</td><td>display help
</table>

# Installation
Simple installation:  
./mde_installer.sh -i

# Notes
Options -i, -r, -u and -w are action commands and can't be combined together. The last one takes precedence over others if so.
Options -e, -o and -t are configuration commands and can be used without specifying an action (install/upgrade/remove/clean).