# GraniteOS 3
A practical, everyday operating system written in Zig. Currently in development.

Requires Zig 0.15.2 on `PATH`, Python 3, Git Bash (or another Windows `sh`), and
VMware Workstation.

```sh
sh tools/vmware.sh run
sh tools/vmware.sh test
```

`sh tools/vmware.sh show` boots the desktop headless until interrupted; `py tools/screen.py`
then screenshots it and drives it over VMware's VNC server (port 5901), for example
`py tools/screen.py click 509 761 wait 2 shot files.png`.
