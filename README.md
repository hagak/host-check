# Node Check

This BASH script is intended to check if k8s nodes are not ready and if not after set time delay issue a payload to taint the nodes and terminate any stuck pods on the nodes due to for example this known issue with ceph https://rook.io/docs/rook/v1.9/Troubleshooting/ceph-csi-common-issues/#rbd-commands.

This script was modeled from https://github.com/reefland
---

## Features

* Supports both GNU and BSD date
* Easily customized notification on results of passphrase (mailx, slack webhook, pushover, etc)
* Customizable steps to take upon node failure and recovery

---

### Prerequisites

* You will need a user with a kubeconfig for the k8s cluster you wish to monitor

The following packages are required to be installed:

* `expect` - this does the text parsing of SSH prompts and enters the provided passphrase.
* `nc` - is used to detect if remote SSH ports are opened.
* `curl` - used to send webhook notifications.
* `strings` - used to filter non-printable characters when `--debug` mode is enabled

---

### Configuration

Configuration is defined via an external configuration file.

* The default location is: `$HOME/.config/node-check/node-check.conf`
  * An alternate file can be specified with the `--config` parameter

#### Example Configuration File

```text
# k8s context
context=main
# Webhook Notifications used in __send_notification() subroutine
webhook="https://hooks.slack.com/<webhook_uri_here>"

# Pushover
pushover_token=<application pushover token>
pushover_userkey=<pushover user key>

# Delay in minutes to wait between notifications of node down (reduces spamming alerts)
node_state_retry_min="59"

# How many minutes must a node be down before calling __node_failed_payload()
node_state_failed_threshold="180"
```

| Variable  | Description |
|---        |---          |
|`context`    | should be populate with the cluster context name from your kubeconfig file
|`pushover_token`    | can be populated with the application token for pushover.  This allows easy notifications via Pushover. |
|`pushover_userkey`    | can be populated with the user key for pushover.  This allows easy notifications Pushover. |
|`webhook`    | can be populated with a webhook URL of your choice to send a notification to.  This allows easy notifications to Slack, Mattermost, etc. |
|`node_state_retry_min` | is an integer number of how many consecutive minutes to wait before sending next alert when a node is down.  This is to help reduce the amount of spam alerts messages generated.  |
|`node_state_failed_threshold`  | is an integer number of how many consecutive minutes a node needs to be down before sub-routine __dropbear_failed_payload() is executed. |
---

### Modifications

There are some routines within the script you may want to consider making modifications. Instead of editing the script directly, simply cut & paste the default routine from the script and place it in the config file (`node-check.conf`).  Customize the version within your config file.

* `__send_notification()` is called to send a notification.  By default it sends a webhook notification to the URL specified in variable `$webhook`.
  * If you would rather an email, then you can modify this to use `mailx` or some other email client.  The content of the notification is in variable `$message`.

* `__node_failed_payload()` is called when node reports status other then "Ready" beyond the `node_state_failed_threshold`.
  * Often there is nothing you can do about it, just needs a human to investigate.
  * The example within the script shows self-hosted kubernetes nodes having a `taint` applied which notified the rest of the cluster that this node will not be available until a human does something.
  * The example also attempts to do a force delete of any terminating pods to allow them to be rescheduled on other nodes.  Pods backed by Ceph RWO PVC will get stuck terminating preventing the pod from being able to start on another node.
  * The variable `$node` will contain the name of the node having an issue.
* `__node_recover_payload()` is called when node reports status "Ready" after being down.

---

#### Installation

Download a copy of the script and place it where you like. Once downloaded, you use `install`:

```shell
$ sudo install node-check.sh /usr/local/bin

$ ls -l /usr/local/bin/node-check.sh

-rwxr-xr-x 1 root root 9710 Aug 26 18:27 /usr/local/bin/node-check.sh
```

* Create configuration file `$HOME/.config/node-check/node-check.conf` as outlined above.
* Once configured [create systemd timer](./docs/create_systemd_timer.md) to run the node-check script as needed.

---

### Usage Statement

```text
  node-check.sh | Version: 0.20 | 11/14/2024 | Jeffrey Gordon

  Check nodes Ready status in k8s.
  ----------------------------------------------------------------------------

  This script will check all nodes in the cluster to determine if any of
  the nodes are not "Ready". If detected, the script will run a defined failure script.

  --debug           : Show expect screen scrape in progress.
  -c, --config      : Full path and name of configuration file.
  -a, --all         : Process all nodes.
  -r, --recover     : Run the recovery script for a single node
  -l, --list        : List defined nodes within the script.
  -h, --help        : This usage statement.
  -v, --version     : Return script version.

  node-check.sh [--debug] [-c <path/name.config>] [-flags] [-a | <nodename>]

  Default configuration file: /home/user/.config/node-check/node-check.conf
```

---
