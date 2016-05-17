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

## Author
John D. Allen
Solution Architect
F5 Networks, Inc.

