
These scripts automate the packaging of the LIS daemons from source code.

Tested on: Ubuntu 14.04, Ubuntu 16.04 and CentOS 7

Tested with Linux kernel 4.12.8

## Man
~~~
-u  URL to a linux kernel source
-r  Linux kernel git repo
-b  Branch for the repo
-l  Path to a local kernel folder
-v  Target OS release version. Ex: 14, 16 ( mandatory for Ubuntu )
~~~
## Steps to generate packages
~~~
Clone this repo.
Run ./build-rpms(debs).sh as root.
~~~
## Notes
~~~
After the script is done the packages will be in the working_directory/hyperv-debs(rpms).
You can't create debs for Ubuntu 15 or higher on a Ubuntu 14.04 machine.
The rpms must be installed as : sudo rpm -i /path/to/rpms/*.rpm     ( dependency problems ).
On CentOS, a restart is needed after daemons install. 
~~~
