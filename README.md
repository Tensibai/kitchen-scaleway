# kitchen-scaleway

[![Gem Version](https://badge.fury.io/rb/kitchen-scaleway.svg)](https://badge.fury.io/rb/kitchen-scaleway)

A [Test Kitchen](https://kitchen.ci) driver that runs your test suites on real
[Scaleway](https://www.scaleway.com) Instances.

Test Kitchen builds a throwaway machine, converges your cookbook or configuration
on it, runs your tests, and destroys the machine. This driver is the piece that
knows how to talk to Scaleway: it creates an Instance over the Scaleway v2
Instance API, waits until SSH answers, hands the address back to Test Kitchen,
and deletes the Instance when you are done. It talks to the API directly over
HTTPS — no SDK is required.

Instances cost money for as long as they exist. Always finish with
`cinc kitchen destroy`, and see [Cleaning up](#cleaning-up) if a run is interrupted.

> This documentation uses [Cinc Workstation](https://cinc.sh/) and the `cinc` commands throughout. Everything here
> works identically with Chef Workstation — see [Using with Chef](#using-with-chef).

## Before you start

You need three things:

* A Scaleway account.
* An **API key** with Instance permissions.
* An **SSH key** registered in your project.

### Get an API key

Create an API key under **IAM → Credentials → Generate API key** in the
[Scaleway console](https://console.scaleway.com/). Copy the secret part now — it
is only shown once. The key must belong to a principal with permissions to create
and delete Instances.

### Register an SSH key

Add your public key under **IAM → Credentials → SSH keys**. Scaleway injects
registered keys into every new Instance automatically (in `/root/.ssh/authorized_keys`),
so Test Kitchen can connect with the matching private key from your SSH agent —
make sure it is loaded, check with `ssh-add -l`.

## Installation

If you use [Cinc Workstation](https://cinc.sh/start/workstation/), install the gem
alongside it; otherwise:

```bash
gem install kitchen-scaleway
```

Or add it to your project's `Gemfile`:

```ruby
source "https://rubygems.org"

gem "test-kitchen"
gem "kitchen-scaleway"
```

## Quick start

Export your credentials. The driver reads them from the environment, which keeps
secrets out of the `kitchen.yml` you commit:

```bash
export SCW_SECRET_KEY="..."
export SCW_DEFAULT_PROJECT_ID="8d19a332-..."
export SCW_DEFAULT_ZONE="fr-par-1"
```

Create a `kitchen.yml` in the root of your project:

```yaml
---
driver:
  name: scaleway

provisioner:
  name: cinc_infra

platforms:
  - name: ubuntu-24
  - name: debian-13

suites:
  - name: default
    run_list:
      - recipe[my_cookbook::default]
```

Then run it:

```bash
cinc kitchen test
```

That creates an Instance per platform, converges it, verifies it, and destroys
it. While you are iterating, the individual steps are more useful:

```bash
cinc kitchen list         # what instances exist and what state they are in
cinc kitchen create       # build the Instance only
cinc kitchen converge     # apply your configuration
cinc kitchen login        # SSH into the running Instance
cinc kitchen destroy      # delete the Instance
```
## Configuration

Every setting goes under the `driver` key in `kitchen.yml`, and can be overridden
per platform or per suite.

| Setting | Default | Description |
| --- | --- | --- |
| `scw_secret_key` | `$SCW_SECRET_KEY` | **Required.** Secret part of a Scaleway API key, sent as `X-Auth-Token`. |
| `scw_access_key` | `$SCW_ACCESS_KEY` | Access key part of a Scaleway API key (informational only). |
| `project_id` | `$SCW_DEFAULT_PROJECT_ID`, then `$SCW_PROJECT_ID` | **Required.** Project the Instances are created in. |
| `zone` | `$SCW_DEFAULT_ZONE`, else `fr-par-1` | Availability zone, e.g. `fr-par-1`, `nl-ams-1`. |
| `api_endpoint` | `https://api.scaleway.com` | API base URL. Useful for testing against a proxy. |
| `username` | `root` | SSH user Test Kitchen connects as. |
| `port` | `22` | SSH port. |
| `server_name` | generated | Instance name. Generated names are unique per instance, user and workstation. |
| `image` | derived from the platform name | Marketplace image label, e.g. `ubuntu_jammy`. |
| `commercial_type` | `PLAY2-PICO` | Instance type, e.g. `PLAY2-PICO`, `DEV1-S`, `PRO2-XXS`. |
| `volume_type` | `l_ssd` | Root volume type: `l_ssd`, `sbs` or `scratch`. |
| `tags` | none | Tags to apply. String or list. |
| `security_group_id` | none | Security group attached to the public network interface. |
| `user_data` | none | Cloud-init script, uploaded after the Instance is created. |
| `server_wait_interval` | `8` | Seconds between API polls while waiting on an Instance. |
| `server_wait_timeout` | `600` | Seconds to wait before giving up on an Instance. |

`tags` accepts either a delimited string or a YAML list, so both of these mean
the same thing:

```yaml
driver:
  tags: web,staging
```

```yaml
driver:
  tags:
    - web
    - staging
```

### Platforms and images

The platform name is what picks the image. Short names are translated to the
matching Scaleway marketplace image label:

| Platform name | Image label |
| --- | --- |
| `almalinux-8` | `almalinux_8` |
| `almalinux-9` | `almalinux_9` |
| `debian-10` | `debian_buster` |
| `debian-11` | `debian_bullseye` |
| `debian-12` | `debian_bookworm` |
| `debian-13` | `debian_trixie` |
| `fedora-40` | `fedora_40` |
| `fedora-41` | `fedora_41` |
| `ubuntu-18` | `ubuntu_bionic` |
| `ubuntu-20` | `ubuntu_focal` |
| `ubuntu-22` | `ubuntu_jammy` |
| `ubuntu-24` | `ubuntu_noble` |

Anything that is not in that list is passed to the API untouched, so any valid
image label works as a platform name directly:

```yaml
platforms:
  - name: ubuntu_jammy       # a marketplace image label
```

You can also set the image explicitly and give the platform any name you like:

```yaml
platforms:
  - name: my-golden-image
    driver:
      image: my_custom_image_label
```

The list of what the API offers for your account lives in
**Marketplace — My images** in the console.

## Examples

### Different types and zones per platform

```yaml
driver:
  name: scaleway
  zone: fr-par-1

platforms:
  - name: ubuntu-24
  - name: debian-13
    driver:
      commercial_type: DEV1-S
      zone: nl-ams-2
```

### Tags and a security group

```yaml
driver:
  name: scaleway
  tags:
    - test-kitchen
    - ci
  security_group_id: 4a8a5c9e-c0d2-4a98-9d5b-3f6a1b2c4d5e
```

Tags are handy for cleanup: the console and the CLI let you list Instances by
tag, so anything a CI run left behind is easy to find.

### Cloud-init user data

```yaml
driver:
  name: scaleway
  user_data: |
    #cloud-config
    package_update: true
    packages:
      - curl
```

The script is uploaded after the Instance is created using the Instance API
`user-data/cloud-init` endpoint, so it does not delay the create call itself.

### Non-root SSH user

Some images ship with a non-root default account. Point the transport at it:

```yaml
driver:
  name: scaleway
  username: admin

transport:
  username: admin
```

## Troubleshooting

### `config[:scw_secret_key] cannot be blank` / `config[:project_id] cannot be blank`

`SCW_SECRET_KEY` or `SCW_DEFAULT_PROJECT_ID` is not set in the shell running
`kitchen`. Note that `sudo` and most CI runners do not forward environment
variables by default.

### `The Scaleway API request failed: 401 ...`

The secret key is wrong, expired, or belongs to a principal without Instance
permissions. Generate a new key under **IAM → Credentials**, or grant the
principal `InstanceFullAccess`.

### `The Scaleway API request failed: 4xx ...`

The API rejected the request; the message says why — usually a `commercial_type`
that is not offered in the chosen `zone`, or an `image` label that does not
resolve. Check available types and labels in the console or with
[`scw`](https://github.com/scaleway/scaleway-cli), e.g.
`scw instance server-type list`, and `scw marketplace image list`.

### `Timed out after 600 seconds waiting for ... to be running`

The Instance was created but never reported `started` in time. Look for it in
the console, raise `server_wait_timeout` if provisioning is slow, and
`server_wait_interval` controls how often the status is polled.

### SSH times out after the Instance is created

The Instance is up but your key is not on it. Confirm the public key is
registered under **IAM → Credentials → SSH keys** in the same project the
Instances are created in, and that the matching private key is loaded in your
agent (`ssh-add -l`).

### Seeing what the driver is doing

Run Test Kitchen with debug logging:

```bash
cinc kitchen test --log-level debug
```

The driver logs every resolved setting. The secret key is masked in that output,
so debug logs are safe to paste into a bug report.

### Cleaning up

If a run is interrupted, the Instance may outlive it. `cinc kitchen destroy` is
the first thing to try. If Test Kitchen has lost track of the instance, delete
it by name or tag from the console, or with the `scw` CLI:

```bash
scw instance server list
scw instance server delete-with-ip <server-id>
```

## Using with Chef

This driver is not tied to Cinc. The examples above use Cinc Workstation and the
`cinc_infra` provisioner, but the driver works exactly the same with
[Chef Workstation](https://www.chef.io/downloads/tools/workstation) — run
`kitchen` instead of `cinc kitchen`, and use `chef_infra` instead of
`cinc_infra`:

```yaml
provisioner:
  name: chef_infra

verifier:
  name: inspec
```

No driver configuration changes are needed.

## Contributing

Pull requests are very welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to
set up a checkout, run the tests, and get a change merged.

* Source is hosted on [GitHub](https://github.com/test-kitchen/kitchen-scaleway).
* Report issues and feature requests on [GitHub Issues](https://github.com/test-kitchen/kitchen-scaleway/issues).

## Authors

Created and maintained by [Tensibai](https://github.com/tensibai),
built for Scaleway.

It was modeled on the [kitchen-digitalocean](https://github.com/test-kitchen/kitchen-digitalocean)
driver by [Greg Fitzgerald](https://github.com/gregf/) and the
[kitchen-ec2](https://github.com/test-kitchen/kitchen-ec2) driver, which in turn
borrowed from [kitchen-rackspace](https://github.com/RoboticCheese/kitchen-rackspace).

## License

Apache 2.0. See [LICENSE](LICENSE).

