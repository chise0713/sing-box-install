# sing-box-install

Bash script for installing sing-box in operating systems such as Arch / CentOS / Debian / OpenSUSE that support systemd.

[Filesystem Hierarchy Standard (FHS)](https://en.wikipedia.org/wiki/Filesystem_Hierarchy_Standard) 

Upstream URL: 
[sing-box](https://github.com/SagerNet/sing-box/) 

```
Installed: /usr/local/bin/sing-box
```
```ini
...
# Working Directory
WorkingDirectory=/var/lib/sing-box
##
...
# /etc/systemd/system/sing-box.service
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json
##
# /etc/systemd/system/sing-box@.service
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/%i.json
##
...
```

## Usage

```
bash -c "$(curl -L sing-box.vercel.app)" @ [ACTION] [OPTION]
```

```
Thanks @chika0801.
usage: install.sh [ACTION] [OPTION]...

ACTION:
install                   Install/Update sing-box
compile                   Compile sing-box
remove                    Remove sing-box
help                      Show help
If no action is specified, then help will be selected

OPTION:
  install:
    --beta                    Install latest Pre-release version of sing-box. 
    --go                      If it's specified, the scrpit will use go to compile sing-box then install.
    --version=[Version]       sing-box version tag, if you specified it, the script will install your custom version sing-box. 
    --user=[User]             Install sing-box in specified user, e.g, --user=root

  compile: 
  [shared with install when it is using go &  If theres no `go` in the machine, script will install go to `$HOME/.cache`]
    --tags=[Tags]             sing-box compile tags, the script will use your custom tags to compile sing-box. 
                              Default https://github.com/SagerNet/sing-box/blob/dev-next/Makefile#L5
    --prefix=[Path]           The path of scrpit store sing-box repository and go binary. 
                              Default `$HOME/.cache`
    --branch=[Branch/Tag]     The scrpit will compile your custom `branch` / `release tag` of sing-box.
    --cgo                     Set `CGO_ENABLED` environment variable to 1
    --win                     The scrpit will use go to compile windows version of sing-box. 
  
  remove:
    --purge                   Remove all the sing-box files, include configs, compiletion etc.
```

## Thanks
[@chika0801](https://github.com/chika0801)
