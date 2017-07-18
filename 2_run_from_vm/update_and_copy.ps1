#!/usr/bin/powershell
cd /root/Framework-Scripts
git pull
cp copy_kernel.ps1 ../runonce.d
./runonce.ps1
