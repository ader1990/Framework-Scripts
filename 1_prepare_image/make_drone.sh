#!/bin/bash
#
#  Script to take a VM template and make it our own
#
#  Author:  John W. Fawcett, Principal Software Development Engineer, Microsoft
#
#  Find out what kind of system we're on
#
if [ -f /usr/bin/dpkg ]
  then
    echo "This is a dpkg machine"
    export is_rpm=0
else
    echo "This is an RPM-based machine"
    export is_rpm=1
fi

#
#  Do the setup for that system
#
if [ $is_rpm == 0 ]
  then
    echo "DEB-based system"
    #
    #  Add the mstest user
    #
    useradd -d /home/mstest -s /bin/bash -G sudo -m mstest -p 'P@ssW0rd-'
    passwd mstest << PASSWD_END
P@ssW0rd-
P@ssW0rd-
PASSWD_END

cp /etc/apt/sources.list /etc/apt/sources.list.orig
cat << NEW_SOURCES > /etc/apt/sources.list.orig
deb  http://deb.debian.org/debian stretch main
deb-src  http://deb.debian.org/debian stretch main

deb  http://deb.debian.org/debian stretch-updates main
deb-src  http://deb.debian.org/debian stretch-updates main

deb http://security.debian.org/ stretch/updates main
deb-src http://security.debian.org/ stretch/updates main
NEW_SOURCES
    #
    #  Make sure things are consistent
    dpkg --configure -a
    apt --fix-broken -y install
    apt-get -y update
    apt-get install -y curl
    apt-get install -y dnsutils
    apt-get install -y apt-transport-https

    wget http://ftp.us.debian.org/debian/pool/main/o/openssl1.0/libssl1.0.2_1.0.2l-2_amd64.deb
dpkg -i ./libssl1.0.2_1.0.2l-2_amd64.deb

    #
    #  Set up the repos to look at and update
    dpkg -l linux-{image,headers}-* | awk '/^ii/{print $2}' | egrep '[0-9]+\.[0-9]+\.[0-9]+' | grep -v $(uname -r | cut -d- -f-2) | xargs sudo apt-get -y purge
    curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add -
    curl https://packages.microsoft.com/config/ubuntu/14.04/prod.list | tee /etc/apt/sources.list.d/microsoft.list
    apt-get -y update

    #
    #  Install PowerShell.  Right now, we have to manually install a downlevel version, but we install the current one
    #  first so all the dependancies are satisfied.
    # apt-get install -y powershell
    #
    #  This package is in a torn state
    wget http://launchpadlibrarian.net/201330288/libicu52_52.1-8_amd64.deb
    dpkg -i libicu52_52.1-8_amd64.deb
    wget http://ftp.us.debian.org/debian/pool/main/o/openssl/libssl1.0.0_1.0.1t-1+deb8u6_amd64.deb
    dpkg -i libssl1.0.0_1.0.1t-1+deb8u6_amd64.deb

    #
    #  Install and remove PS
    apt-get install -y powershell

    #
    #  Download and install the beta 2 version
    export download_1404="https://github.com/PowerSahell/PowerShell/releases/download/v6.0.0-beta.2/powershell_6.0.0-beta.2-1ubuntu1.14.04.1_amd64.deb"
    export download_1604="https://github.com/PowerShell/PowerShell/releases/download/v6.0.0-beta.2/powershell_6.0.0-beta.2-1ubuntu1.16.04.1_amd64.deb"
    wget $download_1604

    export pkg_name=`echo $download_1604 | sed -e s/.*powershell/powershell/`
    dpkg -r powershell
    wget http://archive.ubuntu.com/ubuntu/pool/main/i/icu/libicu55_55.1-7_amd64.deb
    dpkg -i libicu55_55.1-7_amd64.deb
    dpkg -i $pkg_name

    #
    #  Install OMI and PSRP
    apt-get install -y omi
    apt-get install -y omi-psrp-server

    #
    #  Install git and clone our repo
    cd
    apt-get install -y git
    git clone https://github.com/FawcettJohnW/Framework-Scripts.git
    
    #
    #  Need NFS
    apt-get install -y nfs-common

    #
    #  Enable the HTTPS port and restart OMI
    sed -e s/"httpsport=0"/"httpsport=0,443"/ < /etc/opt/omi/conf/omiserver.conf > /tmp/x
    /bin//cp /tmp/x /etc/opt/omi/conf/omiserver.conf
    /opt/omi/bin/omiserver -s
    /opt/omi/bin/omiserver -d

    #
    #  Allow basic auth and restart sshd
    sed -e s/"PasswordAuthentication no"/"PasswordAuthentication yes"/ < /etc/ssh/sshd_config > /tmp/x
    /bin/cp /tmp/x /etc/ssh/sshd_conf
    service ssh restart
   
    #
    #  Set up runonce and copy in the right script
    mkdir runonce.d runonce.d/ran
    cp Framework-Scripts/update_and_copy.ps1 runonce.d/
    
    #
    #  Tell cron to run the runonce at reboot
    echo "@reboot root /root/Framework-Scripts/runonce.ps1" >> /etc/crontab
    apt-get install -y ufw
    ufw allow 443
    ufw allow 5986
else
    echo "RPM-based system"

    #
    #  Make sure we have the tools we need
    yum install -y yum-utils
    yum install -y bind-utils

    #
    #  Clean up disk space
    package-cleanup --oldkernels --count=2

    #
    #  Add the mstest user
    useradd -d /home/mstest -s /bin/bash -G wheel -m mstest -p 'P@ssW0rd-'
        passwd mstest << PASSWD_END
P@ssW0rd-
P@ssW0rd-
PASSWD_END

    #
    #  Set up our repo and update
    curl https://packages.microsoft.com/config/rhel/7/prod.repo | sudo tee /etc/yum.repos.d/microsoft.repo
    yum update -y

    #
    #  See above about PowerSHell
    # yum install -y powershell
    yum install -y powershell
    yum erase -y powershell
    export download_normal="https://github.com/PowerShell/PowerShell/releases/download/v6.0.0-beta.2/powershell-6.0.0_beta.2-1.el7.x86_64.rpm"
    export doenload_suse="https://github.com/PowerShell/PowerShell/releases/download/v6.0.0-beta.2/powershell-6.0.0_beta.2-1.suse.42.1.x86_64.rpm"
    wget $download_normal
    rpm -i $download_normal

    #
    #  OMI and PSRP
    yum install -y omi
    yum install -y omi-psrp-server

    #
    #  Git and sync
    yum install -y git
    cd
    git clone https://github.com/FawcettJohnW/Framework-Scripts.git

    #
    #  Need NFS
    yum install -y nfs-utils

    #
    #  Set up HTTPS and restart OMI
    sed -e s/"httpsport=0"/"httpsport=0,443"/ < /etc/opt/omi/conf/omiserver.conf > /tmp/x
    /bin/cp /tmp/x /etc/opt/omi/conf/omiserver.conf
    /opt/omi/bin/omiserver -s
    /opt/omi/bin/omiserver -d

    #
    #  Allow basic auth and restart sshd
    sed -e s/"PasswordAuthentication no"/"PasswordAuthentication yes"/ < /etc/ssh/sshd_config > /tmp/x
    /bin/cp /tmp/x /etc/ssh/sshd_conf
    systemctl stop sshd
    systemctl start sshd
    
    #
    #  Set up runonce
    mkdir runonce.d runonce.d/ran
    cp Framework-Scripts/update_and_copy.ps1 runonce.d/

    #
    #  Tell cron to run the runonce at reboot
    echo "@reboot root /root/Framework-Scripts/runonce.ps1" >> /etc/crontab

    #
    #  Make sure 443 is allowed through the firewall
    firewall-cmd --zone=public --add-port=443/tcp --permanent
    systemctl stop firewalld
    systemctl start firewalld
fi

if [ -f /etc/motd ] 
  then
    mv /etc/motd /etc/motd_before_ms_kernel
fi

cat << "MOTD_EOF" > /etc/motd
*************************************************************************************

    WARNING   WARNING   WARNING   WARNING   WARNING   WARNING   WARNING   WARNING
    
      THIS IS AN EXPERIMENTAL COMPUTER.  IT IS NOT INTENDED FOR PRODUCTION USE


                 Microsoft Authorized Employees and Partners ONLY!

                   Please wave your badge in front of the screen

     If you are authorized to use this machine, we welcome you and invite your
   feedback through the established channels.  If you're not authorized, please
   don't tell anybody about this.  It really annoys the bosses when things like
   that happen.


   Welcome to the Twilight Zone.                                      Let's Rock.

*************************************************************************************
MOTD_EOF