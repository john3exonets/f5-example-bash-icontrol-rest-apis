# f5-example-bash-icontrol-rest-apis
Sample Bash scripts that implement F5 BIG-IP iControl REST API calls to configure a v12.0 or v11.6 BIG-IP node or instance.

## Intro
These were a set of example scripts written to show a partner of F5 how a complete configuration could be loaded into an F5 BIG-IP using just the iControl REST APIs.

Included in these examples are scripts to load the following configurations:
- Firewall
- ADC w/DNS Caching
- Simple URL Filter
- Simple Bandwidth Controller

## Files
The Bash script files have a file extension of ‘.sh’ and the file name should tell you what configuration the script will load.  There are log files associated with each script, and I have uploaded a sample of each so you can compare with a successful run of the script.

The scripts as written do not take any command line parameters, as all the necessary parameters are included as constants at the top of each script file.  You will want to change the ‘BIGIP_Addrs’, ‘BIGIP_User’, and ‘BIGIP_Passwd’ to reflect the BIGIP to which you want to send the configuration to.

The ‘F5FirewallConfigExample_V5.sh’ script requires that the ‘AFM’ (Advanced Firewall Module) be licensed and enabled. The script assumes that AFM is not enabled, and will enable it and then reboot the BIG-IP so that the Firewall components can be properly initialized before the rest of the script is run.

The ‘F5URLFilteringExample_V5.sh’ script makes use of a very simple iRule to check HTTP (not HTTPS) traffic GET requests for URLs that match any of the defined URLs to block. It returns a very simple HTML pages when it finds a matching URL to block.  This is a very simplistic example, as there are other ways to accomplish URL Filtering. HTTPS traffic can be blocked if the traffic is first decrypted so that the URL can be checked. F5 has other solutions to do URL Filtering — this example is just the most simple way to do it.

The ‘F5Reset.sh’ script is used to back out all the changes that the other scripts add.  This is very helpful when testing as you can run your script, check the configuration for any errors, and then run this script to reset the BIG-IP and try again.

## Author
John D. Allen
Solution Architect
F5 Networks, Inc.

